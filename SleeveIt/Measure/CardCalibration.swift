import SwiftUI

/// Device scale calibration against an ISO/IEC 7810 ID-1 card.
///
/// Every bank, credit, and loyalty card on earth is exactly 85.60 × 53.98 mm —
/// a free, universally available reference object. Measuring one reveals the
/// device's systematic scale error (intrinsics tolerance, depth bias), and the
/// stored correction factor cancels it from every future measurement.
enum ScaleCalibration {
    /// ISO/IEC 7810 ID-1: the short edge, in mm.
    static let referenceWidthMM = 53.98
    /// ISO/IEC 7810 ID-1: the long edge, in mm.
    static let referenceHeightMM = 85.60

    /// The correction factor to store, given a reference-card measurement.
    ///
    /// The measurement already includes `appliedFactor` (whatever correction
    /// was active while scanning), so the new factor composes on top of it.
    /// A single scalar (geometric mean of both edges' corrections) is right
    /// because scale error is isotropic — it comes from distance, not from a
    /// per-axis distortion. Returns nil when the scan is too far off to be a
    /// credible reference measurement (>10% — wrong object or bad scan).
    static func factor(measured: CardMeasurement, appliedFactor: Double) -> Double? {
        let m = measured.normalized
        guard m.widthMM > 20, m.heightMM > 20 else { return nil }
        let widthCorrection = referenceWidthMM / m.widthMM
        let heightCorrection = referenceHeightMM / m.heightMM
        // Device scale error is small and isotropic. An edge off by more than
        // 5%, or the two edges disagreeing by more than 3%, means the scanned
        // object wasn't an ID-1 card (a poker card is ~15% narrower) — refuse
        // rather than store a poisoned correction.
        guard (0.95...1.05).contains(widthCorrection),
              (0.95...1.05).contains(heightCorrection),
              abs(widthCorrection / heightCorrection - 1) < 0.03
        else { return nil }
        let composed = appliedFactor * (widthCorrection * heightCorrection).squareRoot()
        guard (0.9...1.1).contains(composed) else { return nil }
        return composed
    }

    /// The correction currently in effect (1.0 = uncalibrated), matching the
    /// bounds check the measurer applies.
    static var current: Double {
        let stored = UserDefaults.standard.double(forKey: ARCardMeasurer.calibrationKey)
        return (0.9...1.1).contains(stored) ? stored : 1.0
    }

    static var isCalibrated: Bool {
        UserDefaults.standard.object(forKey: ARCardMeasurer.calibrationKey) != nil
            && current != 1.0
    }

    static func save(_ factor: Double) {
        UserDefaults.standard.set(factor, forKey: ARCardMeasurer.calibrationKey)
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: ARCardMeasurer.calibrationKey)
    }
}

/// Scans a bank card and stores the device's scale correction.
///
/// Reuses the full AR measuring pipeline — same camera, same lock behaviour —
/// so the calibration corrects exactly the path real measurements take.
struct CalibrationScreen: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var measurer = ARCardMeasurer()

    /// Error the scan revealed, as a signed percentage, shown after saving.
    @State private var savedCorrectionPercent: Double?
    @State private var scanFailed = false

    var body: some View {
        ZStack {
            GeometryReader { proxy in
                ARCameraView(session: measurer.session)
                    .onAppear { measurer.setViewport(proxy.size) }
                    .onChange(of: proxy.size) { _, size in measurer.setViewport(size) }
            }
            .ignoresSafeArea()

            quadOverlay.ignoresSafeArea()

            VStack {
                header
                Spacer()
                footer
            }
        }
        .onAppear { measurer.start() }
        .onDisappear { measurer.stop() }
        .onChange(of: measurer.phase) { _, phase in
            guard case .locked(let measurement) = phase else { return }
            if let factor = ScaleCalibration.factor(
                measured: measurement, appliedFactor: ScaleCalibration.current
            ) {
                ScaleCalibration.save(factor)
                savedCorrectionPercent = (factor - 1) * 100
                AppAnalytics.log(.calibrationCompleted)
            } else {
                scanFailed = true
            }
        }
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        VStack(spacing: 8) {
            HStack {
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(12)
                        .background(.black.opacity(0.4), in: Circle())
                }
                .padding()
            }
            Text("Calibrate")
                .font(.title2.bold())
                .foregroundStyle(.white)
            Text("Scan any credit or bank card — they are all exactly 85.6 × 54.0 mm.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }

    @ViewBuilder private var footer: some View {
        if let percent = savedCorrectionPercent {
            VStack(spacing: 12) {
                Label(
                    String(format: "Calibrated — correcting %+.1f%%", percent),
                    systemImage: "checkmark.seal.fill"
                )
                .font(.headline)
                .foregroundStyle(Theme.good)
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accentFill)
            }
            .padding(24)
            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 20))
            .padding(.bottom, 40)
        } else if scanFailed {
            VStack(spacing: 12) {
                Text("That didn't look like a bank card — lay it flat and try again.")
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                Button("Scan again") {
                    scanFailed = false
                    measurer.retry()
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accentFill)
            }
            .padding(24)
            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 20))
            .padding(.horizontal, 32)
            .padding(.bottom, 40)
        } else {
            Text(hint)
                .font(.callout.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.black.opacity(0.55), in: Capsule())
                .padding(.bottom, 40)
        }
    }

    private var hint: String {
        switch measurer.phase {
        case .findingSurface: return "Lay the card on a flat surface"
        case .searching: return "Looking for the card"
        case .detecting:
            switch measurer.guidance {
            case .tooClose: return "Move back a little"
            case .tooFar: return "Move closer to the card"
            case .tooTilted: return "Hold the phone flat over the card"
            case .ok: return "Hold steady"
            }
        case .locked: return "Locked"
        case .failed: return "Point the camera at the card"
        }
    }

    @ViewBuilder private var quadOverlay: some View {
        if let quad = measurer.cardQuad, quad.count == 4 {
            Path { path in
                path.move(to: quad[0])
                for point in quad.dropFirst() { path.addLine(to: point) }
                path.closeSubpath()
            }
            .stroke(Color.brandGreenBright, lineWidth: 3)
        }
    }
}

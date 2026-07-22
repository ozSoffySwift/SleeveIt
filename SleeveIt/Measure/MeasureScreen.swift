import ARKit
import SwiftUI
import SwiftData

/// Hosts the live ARKit camera feed behind the measuring UI.
struct ARCameraView: UIViewRepresentable {
    let session: ARSession

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView()
        view.session = session
        view.automaticallyUpdatesLighting = true
        view.rendersContinuously = true
        // Plane visualisation would compete with the scan overlay, so the AR view
        // stays a plain camera feed and all guidance is drawn in SwiftUI above it.
        view.debugOptions = []
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}

struct MeasureScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \SleeveSize.sortIndex) private var sizes: [SleeveSize]
    @Query(sort: \Game.title) private var games: [Game]
    @Query private var listEntries: [ListEntry]
    @AppStorage("units") private var units: UnitPreference = .millimeters

    @StateObject private var measurer = ARCardMeasurer()
    @ObservedObject private var quota = MeasurementQuota.shared
    @ObservedObject private var entitlements = Entitlements.shared
    @State private var isManualEntryPresented = false
    @State private var isCalibrationPresented = false
    @State private var manualResult: CardMeasurement?

    /// The measurement being presented in the result sheet, from AR or manual entry.
    private var settled: CardMeasurement? {
        if let manualResult { return manualResult }
        if case .locked(let measurement) = measurer.phase { return measurement }
        return nil
    }

    var body: some View {
        ZStack {
            cameraLayer
                .ignoresSafeArea()

            scanOverlay
                .ignoresSafeArea()

            VStack(spacing: 0) {
                navBar
                Spacer(minLength: 0)
                bottomLayer
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(false)
        .onAppear {
            quota.rolloverIfNeeded()
            if quota.canMeasure { measurer.start() }
        }
        .onDisappear { measurer.stop() }
        .onChange(of: measurer.phase) { _, phase in
            // Count only on a successful AR lock — not on opening the camera,
            // and not on manual entry.
            if case .locked = phase { quota.recordMeasurement() }
        }
        .sheet(isPresented: $isManualEntryPresented) {
            ManualEntrySheet { measurement in
                manualResult = measurement
            }
            .presentationDetents([.height(320)])
        }
        .sheet(isPresented: $isCalibrationPresented) {
            ReferenceCalibrationView { measurement in
                manualResult = measurement
            }
        }
    }

    // MARK: - Camera

    @ViewBuilder
    private var cameraLayer: some View {
        if ARCardMeasurer.isSupported {
            ARCameraView(session: measurer.session)
        } else {
            // Simulator and non-AR devices: the scan chrome still renders over a
            // dark field so the flow can be exercised via manual entry.
            LinearGradient(
                colors: [Color(white: 0.14), Color(white: 0.04)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    // MARK: - Nav

    private var navBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark").glassCircle()
            }
            Spacer()
            VStack(spacing: 1) {
                Text("Measure")
                    .font(.system(size: 17, weight: .semibold))
                if !quota.isUnlimited {
                    // Surfaced before the limit bites, so running out is never
                    // a surprise mid-task.
                    Text("\(quota.remaining) of \(quota.limit) left today")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.65))
                }
            }
            .foregroundStyle(.white)
            Spacer()
            Button { measurer.toggleTorch() } label: {
                Image(systemName: measurer.isTorchOn ? "bolt.fill" : "bolt")
                    .glassCircle(isActive: measurer.isTorchOn)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    // MARK: - Overlay

    @ViewBuilder
    private var scanOverlay: some View {
        if settled != nil {
            LockedFrame()
        } else if !quota.canMeasure {
            GuideFrame(isWarning: false)
                .opacity(0.35)
        } else {
            switch measurer.phase {
            case .findingSurface, .failed:
                GuideFrame(isWarning: isFailed)
            case .searching:
                ScanningFrame()
            case .detecting(let measurement):
                DetectingFrame(measurement: measurement, units: units)
            case .locked:
                LockedFrame()
            }
        }
    }

    /// Games the user owns or tracks — the strongest prior for identification.
    private var knownGameIDs: Set<String> {
        Set(listEntries.compactMap(\.gameID))
    }

    private var isFailed: Bool {
        if case .failed = measurer.phase { return true }
        return false
    }

    // MARK: - Bottom

    @ViewBuilder
    private var bottomLayer: some View {
        if let settled {
            ResultSheet(
                measurement: settled,
                sizes: sizes,
                games: games,
                knownGameIDs: knownGameIDs,
                units: units,
                isPro: entitlements.isPro,
                onAddSleeve: { add(settled, $0) },
                onAddGame: addGame,
                onMeasureAnother: reset
            )
            .transition(.move(edge: .bottom))
        } else if !quota.canMeasure {
            QuotaReachedCard(
                limit: quota.limit,
                resetsAt: quota.resetsAt,
                onManual: { isManualEntryPresented = true },
                onClose: { dismiss() }
            )
        } else {
            switch measurer.phase {
            case .findingSurface:
                HintCard(
                    title: "Place the card on a flat surface",
                    message: "Point your camera straight down so the whole card sits inside the frame."
                )
            case .searching:
                PillHint(text: "Looking for a card…", style: .searching)
            case .detecting:
                PillHint(text: "Hold steady — locking on…", style: .detecting)
            case .failed(let reason):
                ErrorCard(
                    reason: reason,
                    onRetry: { measurer.retry() },
                    onManual: { isManualEntryPresented = true },
                    onCalibrate: { isCalibrationPresented = true }
                )
            case .locked:
                EmptyView()
            }
        }
    }

    // MARK: - Actions

    private func reset() {
        manualResult = nil
        guard quota.canMeasure else { return }
        measurer.start()
    }

    private func add(_ measurement: CardMeasurement, _ size: SleeveSize) {
        context.insert(ListEntry(
            measuredWidthMM: measurement.widthMM,
            measuredHeightMM: measurement.heightMM,
            sizeID: size.id
        ))
        try? context.save()
        dismiss()
    }

    /// Adds the whole game — every deck, in every size — to the basket.
    /// A `ListEntry` carrying a gameID already expands to all of that game's
    /// decks in the shopping list, so one row covers the lot.
    private func addGame(_ game: Game) {
        let alreadyListed = (try? context.fetch(FetchDescriptor<ListEntry>()))?
            .contains { $0.gameID == game.id } ?? false

        if !alreadyListed, let sizeID = game.sizeIDs.first {
            context.insert(ListEntry(gameID: game.id, sizeID: sizeID))
            try? context.save()
        }
        dismiss()
    }
}

// MARK: - Frames

private let frameWidth: CGFloat = 210
private let frameHeight: CGFloat = 294

private struct GuideFrame: View {
    var isWarning = false

    var body: some View {
        VStack {
            Spacer()
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    isWarning ? Theme.warning.opacity(0.7) : .white.opacity(0.55),
                    style: StrokeStyle(lineWidth: 2.5, dash: [9, 7])
                )
                .frame(width: frameWidth, height: frameHeight)
                .overlay {
                    Image(systemName: isWarning ? "lightbulb.fill" : "viewfinder")
                        .font(.system(size: isWarning ? 32 : 30))
                        .foregroundStyle(isWarning ? Theme.warning : .white)
                        .padding(18)
                        .background(
                            (isWarning ? Theme.warning.opacity(0.16) : Color(red: 28 / 255, green: 130 / 255, blue: 62 / 255).opacity(0.92)),
                            in: RoundedRectangle(cornerRadius: isWarning ? 40 : 20, style: .continuous)
                        )
                }
            Spacer()
            Spacer().frame(height: 160)
        }
    }
}

private struct ScanningFrame: View {
    @State private var sweep = false
    @State private var pulse = false

    var body: some View {
        VStack {
            Spacer()
            ZStack {
                ForEach(Corner.allCases, id: \.self) { corner in
                    CornerBracket(corner: corner)
                        .stroke(Color.brandGreenBright, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .frame(width: frameWidth, height: frameHeight)
                        .opacity(pulse ? 1 : 0.45)
                        .animation(
                            .easeInOut(duration: 1.6)
                            .repeatForever(autoreverses: true)
                            .delay(corner.delay),
                            value: pulse
                        )
                }

                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [.clear, .brandGreenBright, .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: frameWidth - 12, height: 2)
                    .shadow(color: .brandGreenBright, radius: 8)
                    .offset(y: sweep ? frameHeight / 2 : -frameHeight / 2)
                    .animation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true), value: sweep)
            }
            .frame(width: frameWidth, height: frameHeight)
            Spacer()
            Spacer().frame(height: 160)
        }
        .onAppear { sweep = true; pulse = true }
    }
}

private enum Corner: CaseIterable {
    case topLeading, topTrailing, bottomLeading, bottomTrailing

    var delay: Double {
        switch self {
        case .topLeading: 0
        case .topTrailing: 0.2
        case .bottomLeading: 0.4
        case .bottomTrailing: 0.6
        }
    }
}

private struct CornerBracket: Shape {
    let corner: Corner

    func path(in rect: CGRect) -> Path {
        let arm: CGFloat = 34
        var path = Path()
        switch corner {
        case .topLeading:
            path.move(to: CGPoint(x: rect.minX, y: rect.minY + arm))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX + arm, y: rect.minY))
        case .topTrailing:
            path.move(to: CGPoint(x: rect.maxX - arm, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + arm))
        case .bottomLeading:
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY - arm))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX + arm, y: rect.maxY))
        case .bottomTrailing:
            path.move(to: CGPoint(x: rect.maxX - arm, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - arm))
        }
        return path
    }
}

private struct DetectingFrame: View {
    let measurement: CardMeasurement
    let units: UnitPreference
    @State private var pulse = false

    var body: some View {
        VStack {
            Spacer()
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.accent.opacity(0.10))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.brandGreenBright, lineWidth: 3)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.brandGreenBright.opacity(0.4), lineWidth: 2)
                        .opacity(pulse ? 0.9 : 0.35)
                        .animation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true), value: pulse)
                }
                .frame(width: frameWidth, height: frameHeight)
                .shadow(color: Theme.accent.opacity(0.45), radius: 22)
                .overlay(alignment: .top) {
                    readout(measurement.widthMM).offset(y: -34)
                }
                .overlay(alignment: .trailing) {
                    readout(measurement.heightMM).offset(x: 62)
                }
                .overlay { cornerNodes }
            Spacer()
            Spacer().frame(height: 160)
        }
        .onAppear { pulse = true }
    }

    private func readout(_ value: Double) -> some View {
        Text(units == .inches
             ? String(format: "%.2f in", value / 25.4)
             : String(format: "%.1f mm", value))
            .font(.system(size: 13, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.vertical, 4)
            .padding(.horizontal, 10)
            .background(Theme.accentFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .fixedSize()
    }

    private var cornerNodes: some View {
        GeometryReader { proxy in
            ForEach(0..<4, id: \.self) { index in
                Circle()
                    .fill(.white)
                    .frame(width: 10, height: 10)
                    .shadow(color: .brandGreenBright, radius: 4)
                    .position(
                        x: index % 2 == 0 ? 0 : proxy.size.width,
                        y: index < 2 ? 0 : proxy.size.height
                    )
            }
        }
    }
}

private struct LockedFrame: View {
    var body: some View {
        VStack {
            Spacer().frame(height: 120)
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.good.opacity(0.12))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Theme.good, lineWidth: 3)
                }
                .frame(width: 184, height: 258)
                .shadow(color: Theme.good.opacity(0.35), radius: 20)
                .overlay {
                    Image(systemName: "checkmark")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(Color(red: 0.04, green: 0.16, blue: 0.13))
                        .frame(width: 54, height: 54)
                        .background(Theme.good, in: Circle())
                }
            Spacer()
        }
    }
}

// MARK: - Hints

private struct HintCard: View {
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 5) {
            Text(title)
                .font(.system(size: 20, weight: .bold))
            Text(message)
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.78))
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.white)
        .padding(.vertical, 18)
        .padding(.horizontal, 22)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.horizontal, 26)
        .padding(.bottom, 44)
    }
}

private struct PillHint: View {
    enum Style { case searching, detecting }

    let text: String
    let style: Style
    @State private var animating = false

    var body: some View {
        HStack(spacing: 10) {
            if style == .searching {
                HStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { index in
                        Circle()
                            .fill(Color.brandGreenBright)
                            .frame(width: 7, height: 7)
                            .opacity(animating ? 1 : 0.2)
                            .animation(
                                .easeInOut(duration: 0.6)
                                .repeatForever(autoreverses: true)
                                .delay(Double(index) * 0.2),
                                value: animating
                            )
                    }
                }
            } else {
                Image(systemName: "scope")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.brandGreenBright)
            }

            Text(text)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 20)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    if style == .detecting {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(Theme.accent.opacity(0.24))
                            .overlay {
                                RoundedRectangle(cornerRadius: 20, style: .continuous)
                                    .strokeBorder(Color.brandGreenBright.opacity(0.5))
                            }
                    }
                }
        }
        .padding(.bottom, 46)
        .onAppear { animating = true }
    }
}

private struct ErrorCard: View {
    let reason: ARCardMeasurer.Phase.Reason
    let onRetry: () -> Void
    let onManual: () -> Void
    let onCalibrate: () -> Void

    private var title: String {
        switch reason {
        case .unsupportedDevice: "Measuring isn't available"
        case .cameraDenied: "Camera access is off"
        case .lostCard: "Can't see the card clearly"
        }
    }

    private var message: String {
        switch reason {
        case .unsupportedDevice:
            "This device doesn't support AR measuring. You can still enter dimensions by hand."
        case .cameraDenied:
            "Enable camera access in Settings to measure cards, or enter dimensions by hand."
        case .lostCard:
            "Try more light and a plain background, and keep the whole card inside the frame."
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.system(size: 20, weight: .bold))
            Text(message)
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.78))
                .multilineTextAlignment(.center)
                .padding(.top, 5)

            if reason == .lostCard {
                Button("Try again", systemImage: "arrow.clockwise", action: onRetry)
                    .buttonStyle(PrimaryButtonStyle())
                    .padding(.top, 16)
            } else if reason == .cameraDenied {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.top, 16)
            }

            // A reference-object photo is a real measurement; offer it above the
            // hand-typing give-up path, especially where AR simply can't run.
            Button("Measure with a reference photo", action: onCalibrate)
                .buttonStyle(SecondaryButtonStyle())
                .padding(.top, 12)

            Button("Enter dimensions manually", action: onManual)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.brandGreenBright)
                .padding(.top, 12)
        }
        .foregroundStyle(.white)
        .padding(20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.horizontal, 26)
        .padding(.bottom, 44)
    }
}

// MARK: - Result

private struct ResultSheet: View {
    let measurement: CardMeasurement
    let sizes: [SleeveSize]
    let games: [Game]
    let knownGameIDs: Set<String>
    let units: UnitPreference
    let isPro: Bool
    let onAddSleeve: (SleeveSize) -> Void
    let onAddGame: (Game) -> Void
    let onMeasureAnother: () -> Void

    @State private var isPickingGame = false

    private var match: SleeveSize? {
        SleeveMatcher.nearest(to: measurement, in: sizes)
    }

    private var candidates: [GameCandidate] {
        guard let match else { return [] }
        return SizeBasedGameIdentifier()
            .candidates(for: match, in: games, knownGameIDs: knownGameIDs)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Card measured")
                .font(.system(size: 13, weight: .semibold))
                .tracking(0.4)
                .textCase(.uppercase)
                .foregroundStyle(Theme.good)

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(units.compact(width: measurement.widthMM, height: measurement.heightMM)
                    .replacingOccurrences(of: "×", with: " × "))
                    .font(.monoLarge)
                Text(units.suffix)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 8)

            if let match {
                recommendation(match)
                    .padding(.top, 18)

                if isPro, !candidates.isEmpty {
                    proIdentifyButton
                } else if !isPro, !candidates.isEmpty {
                    freeTeaser
                }

                Button("Add sleeve to My List", systemImage: "plus") { onAddSleeve(match) }
                    .buttonStyle(PrimaryButtonStyle())
                    .padding(.top, 12)
            }

            Button("Measure another", systemImage: "viewfinder", action: onMeasureAnother)
                .buttonStyle(SecondaryButtonStyle())
                .padding(.top, 10)
        }
        .padding(.horizontal, 22)
        .padding(.top, 26)
        .padding(.bottom, 34)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28, style: .continuous))
        .sheet(isPresented: $isPickingGame) {
            GamePickerSheet(
                candidates: candidates,
                units: units,
                sizes: sizes,
                onPick: { game in
                    isPickingGame = false
                    onAddGame(game)
                }
            )
        }
    }

    // MARK: - Pro

    /// Prefers the user's own games in the copy — "3 of your games" is a far
    /// more useful statement than "28 games in the catalog".
    private var candidateSummary: String {
        let mine = candidates.filter(\.isKnownToUser).count
        if mine > 0 {
            return "\(mine) of your games use this size"
        }
        return "\(candidates.count) game\(candidates.count == 1 ? "" : "s") use this size"
    }

    private var proIdentifyButton: some View {
        Button {
            isPickingGame = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.system(size: 18))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Identify the game")
                        .font(.system(size: 16, weight: .semibold))
                    Text(candidateSummary)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Theme.accent.opacity(0.12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Theme.accent.opacity(0.3))
                    }
            }
        }
        .buttonStyle(.plain)
        .padding(.top, 12)
    }

    /// Free tier sees exactly what Pro would unlock, stated plainly — no fake
    /// blur, no pretending the app already knows the answer.
    private var freeTeaser: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.fill")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(candidateSummary)
                    .font(.system(size: 15, weight: .semibold))
                Text("Pro narrows this to your games and adds every deck at once.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.top, 12)
    }

    private func recommendation(_ size: SleeveSize) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recommended sleeve")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Text(size.shortName)
                        .font(.system(size: 24, weight: .bold))
                }
                Spacer(minLength: 0)
                SizeBadge(size: size, units: units, style: .filled)
            }

            if !SleeveMatcher.isConfident(measurement, size) {
                Label(
                    "This is the closest standard size, but it's not an exact match. Check the fit before buying.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.system(size: 12))
                .foregroundStyle(Theme.warning)
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Theme.accent.opacity(0.12))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Theme.accent.opacity(0.3))
                }
        }
    }
}

// MARK: - Game picker (Pro)

/// Lets the user confirm which game the measured card came from, then adds every
/// deck in that game to the basket in one action.
private struct GamePickerSheet: View {
    let candidates: [GameCandidate]
    let units: UnitPreference
    let sizes: [SleeveSize]
    let onPick: (Game) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var expanded: String?
    @State private var teachTarget: Game?

    private var mine: [GameCandidate] { candidates.filter(\.isKnownToUser) }
    private var others: [GameCandidate] { candidates.filter { !$0.isKnownToUser } }

    private func size(_ id: String) -> SleeveSize? {
        sizes.first { $0.id == id }
    }

    var body: some View {
        NavigationStack {
            List {
                if !mine.isEmpty {
                    Section {
                        ForEach(mine) { row($0) }
                    } header: {
                        Text("From your list")
                    } footer: {
                        Text("Games you already own or track, which use this card size.")
                    }
                }

                Section {
                    ForEach(others) { row($0) }
                } header: {
                    Text(mine.isEmpty ? "Games using this card size" : "Other games this size")
                } footer: {
                    Text("Card size alone can't tell these apart, so pick the game you're sleeving. SleeveIt then adds every deck it contains — including decks in other sizes.")
                }
            }
            .navigationTitle("Which game?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .sheet(item: $teachTarget) { game in
                TeachCardView(gameID: game.id, gameTitle: game.title)
            }
        }
    }

    private func row(_ candidate: GameCandidate) -> some View {
        let game = candidate.game
        let isOpen = expanded == game.id

        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.25)) {
                    expanded = isOpen ? nil : game.id
                }
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(game.title)
                            .font(.system(size: 16, weight: .semibold))
                        Text("\(candidate.totalSleeves) sleeves · \(game.orderedDecks.count) deck\(game.orderedDecks.count == 1 ? "" : "s")")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if isOpen {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(game.orderedDecks, id: \.persistentModelID) { deck in
                        HStack {
                            Text(deck.label)
                                .font(.system(size: 14))
                            Spacer()
                            if let size = size(deck.sizeID) {
                                Text("\(deck.count)× \(size.compact(units))")
                                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(Theme.accent)
                            }
                        }
                    }

                    Button("Add all \(candidate.totalSleeves) sleeves") {
                        onPick(game)
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .padding(.top, 4)

                    Button {
                        teachTarget = game
                    } label: {
                        Label("Teach SleeveIt this card's art", systemImage: "brain")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 2)
                }
                .padding(.top, 12)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Manual entry

private struct ManualEntrySheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var width = ""
    @State private var height = ""
    let onSubmit: (CardMeasurement) -> Void

    private var parsed: CardMeasurement? {
        guard let w = Double(width.replacingOccurrences(of: ",", with: ".")),
              let h = Double(height.replacingOccurrences(of: ",", with: ".")),
              (10...250).contains(w), (10...250).contains(h)
        else { return nil }
        return CardMeasurement(widthMM: w, heightMM: h, confidence: 1).normalized
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Width") {
                        TextField("63.5", text: $width)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Height") {
                        TextField("88", text: $height)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                } header: {
                    Text("Dimensions in millimetres")
                } footer: {
                    Text("Measure the card itself, not the sleeve. A ruler against the long edge is enough.")
                }
            }
            .navigationTitle("Enter dimensions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        if let parsed { onSubmit(parsed) }
                        dismiss()
                    }
                    .disabled(parsed == nil)
                }
            }
        }
    }
}

// MARK: - Helpers

private extension Image {
    func glassCircle(isActive: Bool = false) -> some View {
        self
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(isActive ? .black : .white)
            .frame(width: 38, height: 38)
            .background(isActive ? AnyShapeStyle(.white) : AnyShapeStyle(.ultraThinMaterial), in: Circle())
    }
}

// MARK: - Quota

/// Shown when the day's free measurements are used up.
private struct QuotaReachedCard: View {
    let limit: Int
    let resetsAt: Date
    let onManual: () -> Void
    let onClose: () -> Void

    private var resetText: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: resetsAt, relativeTo: .now)
    }

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "hourglass")
                .font(.system(size: 28))
                .foregroundStyle(Theme.warning)
                .frame(width: 60, height: 60)
                .background(Theme.warning.opacity(0.16), in: Circle())

            Text("That's \(limit) for today")
                .font(.system(size: 20, weight: .bold))
                .padding(.top, 14)

            Text("Free measuring resets \(resetText). You can still enter dimensions by hand, and everything already on your list stays available.")
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.78))
                .multilineTextAlignment(.center)
                .padding(.top, 5)

            Button("Enter dimensions manually", systemImage: "keyboard", action: onManual)
                .buttonStyle(PrimaryButtonStyle())
                .padding(.top, 16)

            Button("Done", action: onClose)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
                .padding(.top, 14)
        }
        .foregroundStyle(.white)
        .padding(22)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.horizontal, 26)
        .padding(.bottom, 44)
    }
}

import SwiftUI
import PhotosUI

/// The non-AR measure flow: pick a photo, drag handles over the card's corners
/// and across a reference object, and compute the card's real size.
///
/// Produces the same `CardMeasurement` the AR path does, so the caller can feed
/// it into the identical result sheet.
struct ReferenceCalibrationView: View {
    let onMeasured: (CardMeasurement) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var pickerItem: PhotosPickerItem?
    @State private var image: UIImage?
    @State private var reference: ReferenceMeasurer.Reference = .usQuarter

    /// Handle positions in the photo view's coordinate space.
    @State private var corners: [CGPoint] = []
    @State private var refEnds: [CGPoint] = []
    @State private var canvasSize: CGSize = .zero

    var body: some View {
        NavigationStack {
            Group {
                if image == nil {
                    intro
                } else {
                    editor
                }
            }
            .navigationTitle("Measure with a reference")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if image != nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Use size") { compute() }
                    }
                }
            }
            .onChange(of: pickerItem) { _, item in
                Task { await load(item) }
            }
        }
    }

    // MARK: - Intro

    private var intro: some View {
        VStack(spacing: 18) {
            Image(systemName: "ruler")
                .font(.system(size: 44))
                .foregroundStyle(Theme.accent)
            Text("No AR? Use a reference object.")
                .font(.system(size: 20, weight: .bold))
                .multilineTextAlignment(.center)
            Text("Lay the card flat next to something of a known size — a coin, or another card — and take a photo straight down. You'll mark the card's corners and the reference, and SleeveIt works out the size.")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            PhotosPicker(selection: $pickerItem, matching: .images) {
                Label("Choose a photo", systemImage: "photo")
            }
            .buttonStyle(PrimaryButtonStyle())
            .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }

    // MARK: - Editor

    private var editor: some View {
        VStack(spacing: 0) {
            GeometryReader { proxy in
                ZStack {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(width: proxy.size.width, height: proxy.size.height)
                    }

                    // Card quad.
                    QuadOverlay(points: corners, color: Theme.accent)
                    ForEach(corners.indices, id: \.self) { index in
                        Handle(color: Theme.accent, glyph: "\(index + 1)")
                            .position(corners[index])
                            .gesture(drag { corners[index] = clamp($0, in: proxy.size) })
                    }

                    // Reference segment.
                    if refEnds.count == 2 {
                        Path { p in
                            p.move(to: refEnds[0]); p.addLine(to: refEnds[1])
                        }
                        .stroke(Theme.warning, style: StrokeStyle(lineWidth: 3, dash: [6, 4]))
                    }
                    ForEach(refEnds.indices, id: \.self) { index in
                        Handle(color: Theme.warning, glyph: "R")
                            .position(refEnds[index])
                            .gesture(drag { refEnds[index] = clamp($0, in: proxy.size) })
                    }
                }
                .contentShape(.rect)
                .onAppear { seedHandles(in: proxy.size) }
            }
            .background(Color.black)

            controls
        }
        .background(Theme.background)
    }

    private var controls: some View {
        VStack(spacing: 12) {
            Picker("Reference", selection: $reference) {
                ForEach(ReferenceMeasurer.Reference.allCases) { ref in
                    Text(ref.label).tag(ref)
                }
            }
            .pickerStyle(.menu)

            Text("Drag the four numbered handles onto the card's corners, and the two R handles across the \(reference.isCoin ? "coin's width" : "reference's marked edge").")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
        }
        .padding(.vertical, 14)
    }

    // MARK: - Handles

    private func seedHandles(in size: CGSize) {
        guard corners.isEmpty else { return }
        let w = size.width, h = size.height
        corners = [
            CGPoint(x: w * 0.35, y: h * 0.32),
            CGPoint(x: w * 0.65, y: h * 0.32),
            CGPoint(x: w * 0.65, y: h * 0.68),
            CGPoint(x: w * 0.35, y: h * 0.68),
        ]
        refEnds = [
            CGPoint(x: w * 0.30, y: h * 0.82),
            CGPoint(x: w * 0.45, y: h * 0.82),
        ]
    }

    private func drag(_ update: @escaping (CGPoint) -> Void) -> some Gesture {
        DragGesture(minimumDistance: 0).onChanged { update($0.location) }
    }

    private func clamp(_ point: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(
            x: min(max(point.x, 0), size.width),
            y: min(max(point.y, 0), size.height)
        )
    }

    // MARK: - Actions

    private func load(_ item: PhotosPickerItem?) async {
        guard let item,
              let data = try? await item.loadTransferable(type: Data.self),
              let uiImage = UIImage(data: data)
        else { return }
        image = uiImage
        corners = []
    }

    private func compute() {
        guard corners.count == 4, refEnds.count == 2 else { return }
        guard let measurement = ReferenceMeasurer.measure(
            cardCorners: corners,
            referenceEndpoints: (refEnds[0], refEnds[1]),
            reference: reference
        ) else { return }
        onMeasured(measurement)
        dismiss()
    }
}

// MARK: - Overlay pieces

private struct QuadOverlay: View {
    let points: [CGPoint]
    let color: Color

    var body: some View {
        Path { path in
            guard points.count == 4 else { return }
            path.move(to: points[0])
            for point in points.dropFirst() { path.addLine(to: point) }
            path.closeSubpath()
        }
        .stroke(color, lineWidth: 2)
        .background(
            Path { path in
                guard points.count == 4 else { return }
                path.move(to: points[0])
                for point in points.dropFirst() { path.addLine(to: point) }
                path.closeSubpath()
            }
            .fill(color.opacity(0.12))
        )
    }
}

private struct Handle: View {
    let color: Color
    let glyph: String

    var body: some View {
        Text(glyph)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(color, in: Circle())
            .overlay(Circle().strokeBorder(.white, lineWidth: 2))
            .shadow(radius: 3)
    }
}

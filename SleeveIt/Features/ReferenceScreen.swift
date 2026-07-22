import SwiftUI
import SwiftData

struct ReferenceScreen: View {
    @AppStorage("units") private var units: UnitPreference = .millimeters
    @Query(sort: \SleeveSize.sortIndex) private var sizes: [SleeveSize]

    @State private var expanded: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(sizes) { size in
                        SizeCard(
                            size: size,
                            units: units,
                            isExpanded: expanded == size.id
                        ) {
                            withAnimation(.snappy(duration: 0.28)) {
                                expanded = expanded == size.id ? nil : size.id
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
            .background(Theme.background)
            .navigationTitle("Reference")
            .overlay(alignment: .top) {
                if sizes.isEmpty {
                    ProgressView().padding(.top, 40)
                }
            }
        }
        .onAppear {
            // Open the most common size by default — it answers most questions.
            if expanded == nil {
                expanded = sizes.first(where: \.isCommon)?.id
            }
        }
    }
}

private struct SizeCard: View {
    let size: SleeveSize
    let units: UnitPreference
    let isExpanded: Bool
    let onTap: () -> Void

    /// Swatches are drawn to real relative proportion, so a Tarot card visibly
    /// dwarfs a Mini American at a glance.
    private var swatchScale: CGFloat { 0.52 }

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onTap) {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .strokeBorder(
                                isExpanded ? Theme.accent : Color.secondary.opacity(0.5),
                                lineWidth: isExpanded ? 2 : 1.5
                            )
                            .background {
                                if isExpanded {
                                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                                        .fill(Theme.accent.opacity(0.1))
                                }
                            }
                            .frame(
                                width: size.widthMM * swatchScale,
                                height: size.heightMM * swatchScale
                            )
                    }
                    .frame(width: 44, height: 64, alignment: .center)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(size.name)
                            .font(.system(size: 16, weight: isExpanded ? .bold : .semibold))
                            .multilineTextAlignment(.leading)
                        Text(size.tagline)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                    }

                    Spacer(minLength: 0)

                    if isExpanded {
                        Text(size.compact(units))
                            .font(.system(size: 16, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 11)
                            .background(Theme.accentFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    } else {
                        Text(size.compact(units))
                            .font(.system(size: 15, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Theme.accent)
                    }
                }
                .padding(.vertical, 13)
                .padding(.horizontal, 15)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    Text(size.blurb)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    FlowLayout(spacing: 6) {
                        ForEach(size.examples, id: \.self) { example in
                            Text(example)
                                .font(.system(size: 12, weight: .medium))
                                .padding(.vertical, 4)
                                .padding(.horizontal, 9)
                                .background(Theme.fill, in: Capsule())
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 58)
                .padding(.trailing, 15)
                .padding(.bottom, 15)
            }
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isExpanded ? Theme.accent.opacity(0.3) : .clear, lineWidth: 1.5)
        }
        .shadow(color: isExpanded ? Theme.accent.opacity(0.18) : .black.opacity(0.05), radius: isExpanded ? 10 : 2, y: 2)
    }
}

/// Wraps example chips onto as many lines as they need.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rows: CGFloat = 1
        var x: CGFloat = 0
        var rowHeight: CGFloat = 0
        var total: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                total += rowHeight + spacing
                rows += 1
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth, height: total + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

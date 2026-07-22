import SwiftUI

// MARK: - Size badge

/// The sleeve size shown as the hero of a row — dimensions over a short label.
struct SizeBadge: View {
    let size: SleeveSize
    var units: UnitPreference = .millimeters
    var style: Style = .tinted

    enum Style { case tinted, filled }

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(size.compact(units))
                .font(.system(size: 18, weight: .semibold, design: .monospaced))
            Text(size.shortName.uppercased())
                .font(.system(size: 9, weight: .bold))
                .tracking(0.6)
                .opacity(0.8)
        }
        .foregroundStyle(style == .filled ? Color.white : Theme.accent)
        .padding(.vertical, 8)
        .padding(.horizontal, 13)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(style == .filled ? AnyShapeStyle(Theme.accentFill) : AnyShapeStyle(Theme.accent.opacity(0.12)))
                .overlay {
                    if style == .tinted {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Theme.accent.opacity(0.24))
                    }
                }
        }
    }
}

// MARK: - Card artwork placeholder

/// Diagonal-hatch stand-in for box art, matching the design's placeholder.
struct CoverPlaceholder: View {
    var width: CGFloat
    var height: CGFloat
    var cornerRadius: CGFloat = 6

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Theme.fill)
            .overlay {
                Canvas { context, size in
                    let step: CGFloat = 10
                    var path = Path()
                    var x = -size.height
                    while x < size.width {
                        path.move(to: CGPoint(x: x, y: size.height))
                        path.addLine(to: CGPoint(x: x + size.height, y: 0))
                        x += step
                    }
                    context.stroke(path, with: .color(.primary.opacity(0.07)), lineWidth: 5)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .frame(width: width, height: height)
    }
}

// MARK: - Buttons

struct PrimaryButtonStyle: ButtonStyle {
    var isEnabled = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 18, weight: .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .foregroundStyle(isEnabled ? Color.white : Color.secondary)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(isEnabled ? AnyShapeStyle(Theme.accentFill) : AnyShapeStyle(Theme.fill))
            }
            .shadow(color: isEnabled ? Theme.accent.opacity(0.4) : .clear, radius: 12, y: 8)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(Theme.fill)
            }
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

// MARK: - Empty state

struct EmptyStateView<Actions: View>: View {
    let icon: String
    let title: String
    let message: String
    var tagline: String?
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Theme.accent.opacity(0.12))
                .frame(width: 72, height: 72)
                .overlay {
                    Image(systemName: icon)
                        .font(.system(size: 32))
                        .foregroundStyle(Theme.accent)
                }

            Text(title)
                .font(.system(size: 20, weight: .semibold))
                .padding(.top, 18)

            Text(message)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 6)

            if let tagline {
                Text(tagline)
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.accent)
                    .padding(.top, 22)
            }

            actions.padding(.top, 22)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 28)
    }
}

extension EmptyStateView where Actions == EmptyView {
    init(icon: String, title: String, message: String, tagline: String? = nil) {
        self.init(icon: icon, title: title, message: message, tagline: tagline) { EmptyView() }
    }
}

// MARK: - Info note

struct InfoNote<Content: View>: View {
    var icon: String = "info.circle.fill"
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(Theme.accent)
            content
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }
}

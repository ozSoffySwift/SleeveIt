import SwiftUI

/// The Cobalt direction: iOS blue, cool neutrals, crisp system glass.
enum Theme {
    /// Tint colour — for text, icons and thin strokes drawn *on* a background.
    /// Adaptive, so it stays legible in both appearances.
    static let accent = Color.brandGreen

    /// Fill colour — for solid surfaces that carry white text (buttons, filled
    /// badges). Deliberately stays dark in both appearances: the adaptive tint
    /// is far too light in dark mode to hold white text.
    static let accentFill = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 34 / 255, green: 128 / 255, blue: 63 / 255, alpha: 1)   // #22803F
            : UIColor(red: 28 / 255, green: 100 / 255, blue: 50 / 255, alpha: 1)   // #1C6432
    })

    /// Deep brand green for gradient ends and pressed states.
    static let accentDeep = Color(red: 16 / 255, green: 74 / 255, blue: 35 / 255)

    /// Success uses a distinctly brighter mint so a locked measurement still
    /// reads as "done" rather than blending into the brand green.
    static let good = Color(red: 0.20, green: 0.83, blue: 0.60)
    static let warning = Color(red: 1.0, green: 0.62, blue: 0.04)

    /// Grouped-background greys, matching the design's #F2F2F7 / #000.
    static let background = Color(uiColor: .systemGroupedBackground)
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
    static let fill = Color(uiColor: .tertiarySystemFill)

    enum Radius {
        static let card: CGFloat = 16
        static let control: CGFloat = 15
        static let hero: CGFloat = 22
    }
}

extension Color {
    /// The brand green, taken from the app icon (#1C6432).
    ///
    /// Adaptive: the icon's deep forest green has enough contrast on white, but
    /// on a black background it reads as near-black, so dark mode gets a
    /// brighter, more saturated green. One token, correct in both appearances.
    static let brandGreen = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 61 / 255, green: 199 / 255, blue: 106 / 255, alpha: 1)   // #3DC76A
            : UIColor(red: 28 / 255, green: 100 / 255, blue: 50 / 255, alpha: 1)    // #1C6432
    })

    /// Fixed bright green for the camera overlay, which is always on a dark
    /// live-view regardless of the app's appearance setting.
    static let brandGreenBright = Color(red: 74 / 255, green: 222 / 255, blue: 128 / 255)
}

extension Font {
    static let monoBadge = Font.system(size: 18, weight: .semibold, design: .monospaced)
    static let monoLarge = Font.system(size: 40, weight: .bold, design: .monospaced)
}

// MARK: - Units

enum UnitPreference: String, CaseIterable, Identifiable {
    case millimeters
    case inches

    var id: String { rawValue }

    var label: String {
        switch self {
        case .millimeters: "Millimeters"
        case .inches: "Inches"
        }
    }

    var suffix: String {
        switch self {
        case .millimeters: "mm"
        case .inches: "in"
        }
    }

    /// Compact form for badges: "63.5×88".
    func compact(width: Double, height: Double) -> String {
        switch self {
        case .millimeters:
            "\(Self.trim(width))×\(Self.trim(height))"
        case .inches:
            String(format: "%.2f×%.2f", width / 25.4, height / 25.4)
        }
    }

    /// Long form for body copy: "63.5 × 88 mm".
    func long(width: Double, height: Double) -> String {
        switch self {
        case .millimeters:
            "\(Self.trim(width)) × \(Self.trim(height)) mm"
        case .inches:
            String(format: "%.2f × %.2f in", width / 25.4, height / 25.4)
        }
    }

    /// Drops a trailing ".0" so 88.0 reads as 88 but 63.5 stays 63.5.
    private static func trim(_ value: Double) -> String {
        value.rounded() == value
            ? String(Int(value))
            : String(format: "%.1f", value)
    }
}

extension SleeveSize {
    func compact(_ units: UnitPreference) -> String {
        units.compact(width: widthMM, height: heightMM)
    }

    func long(_ units: UnitPreference) -> String {
        units.long(width: widthMM, height: heightMM)
    }
}

// MARK: - Appearance

enum AppearancePreference: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

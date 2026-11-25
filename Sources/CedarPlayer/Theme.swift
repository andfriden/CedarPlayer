import SwiftUI
import AppKit

/// Cyber-HiFi palette with optional Catppuccin flavors.
enum Theme {
    struct Palette {
        let base, mantle, crust, surface0, surface1: UInt32
        let overlay0, subtext0, text, mauve, lavender, red, yellow: UInt32
    }

    private static let latte = Palette(
        base: 0xEFF1F5, mantle: 0xE6E9EF, crust: 0xDCE0E8,
        surface0: 0xCCD0DA, surface1: 0xBCC0CC, overlay0: 0x9CA0B0,
        subtext0: 0x6C6F85, text: 0x4C4F69, mauve: 0x8839EF,
        lavender: 0x7287FD, red: 0xD20F39, yellow: 0xDF8E1D)
    private static let frappe = Palette(
        base: 0x303446, mantle: 0x292C3C, crust: 0x232634,
        surface0: 0x414559, surface1: 0x51576D, overlay0: 0x737994,
        subtext0: 0xA5ADCE, text: 0xC6D0F5, mauve: 0xCA9EE6,
        lavender: 0xBABBF1, red: 0xE78284, yellow: 0xE5C890)
    private static let macchiato = Palette(
        base: 0x24273A, mantle: 0x1E2030, crust: 0x181926,
        surface0: 0x363A4F, surface1: 0x494D64, overlay0: 0x6E738D,
        subtext0: 0xA5ADCB, text: 0xCAD3F5, mauve: 0xC6A0F6,
        lavender: 0xB7BDF8, red: 0xED8796, yellow: 0xEED49F)
    private static let mocha = Palette(
        base: 0x1E1E2E, mantle: 0x181825, crust: 0x11111B,
        surface0: 0x313244, surface1: 0x45475A, overlay0: 0x6C7086,
        subtext0: 0xA6ADC8, text: 0xCDD6F4, mauve: 0xCBA6F7,
        lavender: 0xB4BEFE, red: 0xF38BA8, yellow: 0xF9E2AF)

    static var activePalette: Palette? {
        switch AppearanceMode.current {
        case .catppuccinLatte: return latte
        case .catppuccinFrappe: return frappe
        case .catppuccinMacchiato: return macchiato
        case .catppuccinMocha: return mocha
        default: return nil
        }
    }

    private static var customAccent: (normal: Color, bright: Color)? {
        let choice = AccentChoice.current
        guard let color = choice.color, let bright = choice.bright else { return nil }
        return (color, bright)
    }

    static var background: Color { themed(\.base, light: 0xF0F0F2, dark: 0x1E1E22) }
    static var panel: Color { themed(\.surface0, light: 0xFAFAFB, dark: 0x2A2A30) }
    static var titleBar: Color { themed(\.mantle, light: 0xE4E4E8, dark: 0x232327) }
    static var text: Color { themed(\.text, light: 0x1B1B20, dark: 0xEAEAEA) }
    static var secondaryText: Color { themed(\.subtext0, light: 0x6E6E73, dark: 0x8E8E93) }
    static var accent: Color { customAccent?.normal ?? themed(\.mauve, light: 0x008FBF, dark: 0x35D6FF) }
    static var accentBright: Color { customAccent?.bright ?? themed(\.lavender, light: 0x00A6D6, dark: 0x7BE7FF) }
    static var separator: Color { themed(\.surface0, light: 0xD6D6DC, dark: 0x3A3A42) }
    static var subtle: Color { themed(\.surface1, light: 0xE9E9EE, dark: 0x35353C) }
    static var danger: Color { themed(\.red, light: 0xC4453F, dark: 0xE06C75) }
    static var warning: Color {
        activePalette.map { Color(hex: $0.yellow) } ?? Color(hex: 0xE5B44A)
    }
    /// Test-only override for the main player window's fixed Cyber palette.
    static var forcedDark: Bool?

    static let hover = Color(nsColor: NSColor(name: nil) { appearance in
        isDark(appearance) ? NSColor.white.withAlphaComponent(0.07)
                           : NSColor.black.withAlphaComponent(0.05)
    })
    static let inset = Color(nsColor: NSColor(name: nil) { appearance in
        isDark(appearance) ? NSColor.black.withAlphaComponent(0.28)
                           : NSColor.black.withAlphaComponent(0.07)
    })

    /// Fixed palette for the main player window, independent of the system theme.
    enum Cyber {
        static var background: Color { Theme.themedForced(\.base, light: 0xF4F4F7, dark: 0x1E1E22) }
        static var playerBackground: Color { Theme.themedForced(\.mantle, light: 0xF9F9FB, dark: 0x18181B) }
        static var statusBackground: Color { Theme.themedForced(\.crust, light: 0xE9E9EE, dark: 0x141416) }
        static var border: Color { Theme.themedForced(\.surface0, light: 0xD5D5DD, dark: 0x2E2E36) }
        static var outerBorder: Color { Theme.themedForced(\.surface1, light: 0xD0D0D8, dark: 0x3A3A42) }
        static var separator: Color { Theme.themedForced(\.surface0, light: 0xD8D8E0, dark: 0x27272A) }
        static var titleText: Color { Theme.themedForced(\.text, light: 0x17171B, dark: 0xFFFFFF) }
        static var artistText: Color { Theme.themedForced(\.subtext0, light: 0x5F5F6A, dark: 0xA0A0AB) }
        static var tertiaryText: Color { Theme.themedForced(\.overlay0, light: 0x8A8A95, dark: 0x71717A) }
        static var panel: Color { Theme.themedForced(\.surface0, light: 0xFFFFFF, dark: 0x2A2A30) }
        static var titleBar: Color { Theme.themedForced(\.mantle, light: 0xECECF1, dark: 0x232327) }
        static var text: Color { Theme.themedForced(\.text, light: 0x1B1B20, dark: 0xEAEAEA) }
        static var secondaryText: Color { Theme.themedForced(\.subtext0, light: 0x6E6E79, dark: 0x8E8E93) }
        static var accent: Color { Theme.customAccent?.normal ?? Theme.themedForced(\.mauve, light: 0x007EA8, dark: 0x35D6FF) }
        static var accentBright: Color { Theme.customAccent?.bright ?? Theme.themedForced(\.lavender, light: 0x00A6D6, dark: 0x7BE7FF) }
        static var subtle: Color { Theme.themedForced(\.surface1, light: 0xE8E8EF, dark: 0x35353C) }
        static var danger: Color { Theme.danger }
        static var warning: Color { Theme.warning }
        static var hover: Color {
            if let forced = Theme.forcedDark { return forced ? Color.white.opacity(0.07) : Color.black.opacity(0.05) }
            return Theme.hover
        }
        static var inset: Color {
            if let forced = Theme.forcedDark { return forced ? Color.black.opacity(0.28) : Color.black.opacity(0.07) }
            return Theme.inset
        }
        static var track: Color { Theme.themedForced(\.crust, light: 0xD8D8DE, dark: 0x111114) }
    }

    enum Layout {
        static let width: CGFloat = 520
        static let minWidth: CGFloat = 460
        static let titleBarHeight: CGFloat = 32
        static let playerHeight: CGFloat = 240
        static let playlistHeight: CGFloat = 460
        static let defaultHeight: CGFloat = 760
        static let minHeight: CGFloat = 600
        static let contentPadding: CGFloat = 12
    }

    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
    }

    enum Radius {
        static let small: CGFloat = 6
        static let medium: CGFloat = 10
        static let large: CGFloat = 16
    }

    enum Fonts {
        static let nowPlaying = Font.system(size: 22, weight: .semibold)
        static let nowPlayingSmall = Font.system(size: 17, weight: .semibold)
        static let listTitle = Font.system(size: 13, weight: .medium)
        static let artist = Font.system(size: 12)
        static let caption = Font.system(size: 11)
        static let captionMono = Font.system(size: 10, weight: .medium, design: .monospaced)
        static let timeMono = Font.system(size: 11, design: .monospaced)
    }

    private static func themed(_ keyPath: KeyPath<Palette, UInt32>,
                               light: UInt32, dark: UInt32) -> Color {
        if let palette = activePalette {
            return Color(hex: palette[keyPath: keyPath])
        }
        return adaptive(light: light, dark: dark)
    }

    private static func themedForced(_ keyPath: KeyPath<Palette, UInt32>,
                                     light: UInt32, dark: UInt32) -> Color {
        if let palette = activePalette {
            return Color(hex: palette[keyPath: keyPath])
        }
        return adaptiveForced(light: light, dark: dark)
    }

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            nsColor(hex: isDark(appearance) ? dark : light)
        })
    }

    private static func adaptiveForced(light: UInt32, dark: UInt32) -> Color {
        if let forcedDark { return Color(hex: forcedDark ? dark : light) }
        return Color(nsColor: NSColor(name: nil) { appearance in
            nsColor(hex: isDark(appearance) ? dark : light)
        })
    }

    private static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    static func nsColor(hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1)
    }
}

/// Appearance choice: system, dark, light or a Catppuccin flavor.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case dark
    case light
    case catppuccinLatte
    case catppuccinFrappe
    case catppuccinMacchiato
    case catppuccinMocha

    var id: String { rawValue }

    static var current: AppearanceMode {
        AppearanceMode(rawValue: UserDefaults.standard.string(forKey: "appearanceMode") ?? "") ?? .system
    }

    var title: String {
        switch self {
        case .system: return L10n.string("Системное")
        case .dark: return L10n.string("Тёмное")
        case .light: return L10n.string("Светлое")
        case .catppuccinLatte: return "Catppuccin Latte"
        case .catppuccinFrappe: return "Catppuccin Frappé"
        case .catppuccinMacchiato: return "Catppuccin Macchiato"
        case .catppuccinMocha: return "Catppuccin Mocha"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .dark, .catppuccinFrappe, .catppuccinMacchiato, .catppuccinMocha: return .dark
        case .light, .catppuccinLatte: return .light
        }
    }
}

/// Accent selection: follow the theme, macOS accent, or a system color.
enum AccentChoice: String, CaseIterable, Identifiable {
    case theme
    case system
    case blue
    case purple
    case pink
    case red
    case orange
    case yellow
    case green
    case graphite

    var id: String { rawValue }

    static var current: AccentChoice {
        AccentChoice(rawValue: UserDefaults.standard.string(forKey: "accentChoice") ?? "") ?? .theme
    }

    var title: String {
        switch self {
        case .theme: return L10n.string("Как в теме")
        case .system: return L10n.string("Системный")
        case .blue: return L10n.string("Синий")
        case .purple: return L10n.string("Фиолетовый")
        case .pink: return L10n.string("Розовый")
        case .red: return L10n.string("Красный")
        case .orange: return L10n.string("Оранжевый")
        case .yellow: return L10n.string("Жёлтый")
        case .green: return L10n.string("Зелёный")
        case .graphite: return L10n.string("Графит")
        }
    }

    var color: Color? {
        base.map { Color(nsColor: $0) }
    }

    var bright: Color? {
        guard let base else { return nil }
        return Color(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let fraction: CGFloat = dark ? 0.35 : 0.12
            guard let resolved = base.usingColorSpace(.sRGB) else { return base }
            return resolved.blended(withFraction: fraction, of: .white) ?? resolved
        })
    }

    private var base: NSColor? {
        switch self {
        case .theme: return nil
        case .system: return .controlAccentColor
        case .blue: return .systemBlue
        case .purple: return .systemPurple
        case .pink: return .systemPink
        case .red: return .systemRed
        case .orange: return .systemOrange
        case .yellow: return .systemYellow
        case .green: return .systemGreen
        case .graphite: return .systemGray
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(nsColor: Theme.nsColor(hex: hex))
    }
}

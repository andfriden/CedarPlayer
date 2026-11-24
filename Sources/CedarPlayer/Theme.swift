import SwiftUI
import AppKit

/// Dark Cyber-HiFi palette: textured graphite panels with amber indicators.
enum Theme {
    static let background = adaptive(light: 0xF0F0F2, dark: 0x1E1E22)
    static let panel = adaptive(light: 0xFAFAFB, dark: 0x2A2A30)
    static let titleBar = adaptive(light: 0xE4E4E8, dark: 0x232327)
    static let text = adaptive(light: 0x1B1B20, dark: 0xEAEAEA)
    static let secondaryText = adaptive(light: 0x6E6E73, dark: 0x8E8E93)
    static let accent = adaptive(light: 0xD97700, dark: 0xFF8C00)
    static let accentBright = adaptive(light: 0xE98600, dark: 0xFFA500)
    static let separator = adaptive(light: 0xD6D6DC, dark: 0x3A3A42)
    static let subtle = adaptive(light: 0xE9E9EE, dark: 0x35353C)
    static let danger = adaptive(light: 0xC4453F, dark: 0xE06C75)
    static let warning = Color(hex: 0xE5B44A)
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
        static let background = Color(hex: 0x1E1E22)
        static let playerBackground = Color(hex: 0x18181B)
        static let statusBackground = Color(hex: 0x141416)
        static let border = Color(hex: 0x2E2E36)
        static let outerBorder = Color(hex: 0x3A3A42)
        static let separator = Color(hex: 0x27272A)
        static let titleText = Color(hex: 0xFFFFFF)
        static let artistText = Color(hex: 0xA0A0AB)
        static let tertiaryText = Color(hex: 0x71717A)
        static let panel = Color(hex: 0x2A2A30)
        static let titleBar = Color(hex: 0x232327)
        static let text = Color(hex: 0xEAEAEA)
        static let secondaryText = Color(hex: 0x8E8E93)
        static let accent = Color(hex: 0xFF8C00)
        static let accentBright = Color(hex: 0xFFA500)

        static let subtle = Color(hex: 0x35353C)
        static let danger = Color(hex: 0xE06C75)
        static let warning = Color(hex: 0xE5B44A)
        static let hover = Color.white.opacity(0.07)
        static let inset = Color.black.opacity(0.28)
        static let track = Color(hex: 0x111114)
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

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
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

/// Appearance choice: system, dark or light.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case dark
    case light

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return L10n.string("Системное")
        case .dark: return L10n.string("Тёмное")
        case .light: return L10n.string("Светлое")
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .dark: return .dark
        case .light: return .light
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(nsColor: Theme.nsColor(hex: hex))
    }
}

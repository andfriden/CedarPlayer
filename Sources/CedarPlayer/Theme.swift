import SwiftUI
import AppKit

/// UI palette and scales adapted to light and dark themes.
enum Theme {
    static let background = adaptive(light: 0xF2F3F5, dark: 0x181A1E)
    static let panel = adaptive(light: 0xFFFFFF, dark: 0x22252B)
    static let text = adaptive(light: 0x1B1F27, dark: 0xF2F4F7)
    static let secondaryText = adaptive(light: 0x5C6472, dark: 0xA2A9B4)
    static let accent = adaptive(light: 0x3567C8, dark: 0x7BA7FF)
    static let separator = adaptive(light: 0xD7DBE2, dark: 0x323740)
    static let subtle = adaptive(light: 0xE9ECF1, dark: 0x2B2F36)
    static let danger = adaptive(light: 0xC4453F, dark: 0xE06C75)
    static let warning = Color(hex: 0xE5B44A)
    static let hover = Color(nsColor: NSColor(name: nil) { appearance in
        isDark(appearance) ? NSColor.white.withAlphaComponent(0.05)
                           : NSColor.black.withAlphaComponent(0.05)
    })

    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
    }

    enum Radius {
        static let small: CGFloat = 6
        static let medium: CGFloat = 8
        static let large: CGFloat = 12
    }

    enum Fonts {
        static let nowPlaying = Font.system(size: 18, weight: .semibold)
        static let listTitle = Font.system(size: 13, weight: .medium)
        static let artist = Font.system(size: 12)
        static let caption = Font.system(size: 11)
        static let captionMono = Font.system(size: 11, design: .monospaced)
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

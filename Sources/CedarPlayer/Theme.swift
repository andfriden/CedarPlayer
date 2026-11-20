import SwiftUI

/// Палитра и шкалы интерфейса: единый фон, текст, акцент, отступы и скругления.
enum Theme {
    static let background = Color(hex: 0x181A1E)
    static let panel = Color(hex: 0x22252B)
    static let text = Color(hex: 0xF2F4F7)
    static let secondaryText = Color(hex: 0xA2A9B4)
    static let accent = Color(hex: 0x7BA7FF)
    static let separator = Color(hex: 0x323740)
    static let hover = Color.white.opacity(0.05)

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
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}

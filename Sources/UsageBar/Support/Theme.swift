import SwiftUI

enum Theme {
    static let bg = Color(hex: 0x2A2321)
    static let bgElevated = Color(hex: 0x342B28)
    static let cardFill = Color.white.opacity(0.045)
    static let cardStroke = Color.white.opacity(0.07)
    static let chipFill = Color.white.opacity(0.06)
    static let chipSelected = Color(hex: 0x4A3128)
    static let chipSelectedStroke = Color(hex: 0xB0684A).opacity(0.7)
    static let divider = Color.white.opacity(0.08)
    static let textPrimary = Color(hex: 0xF3ECE5)
    static let textSecondary = Color(hex: 0xA79D96)
    static let textMuted = Color(hex: 0x7E746E)
    static let accent = Color(hex: 0xE3956A)
    static let track = Color(hex: 0x463C38)

    static let ok = Color(hex: 0x6FBF8A)
    static let caution = Color(hex: 0xD9A05B)
    static let warning = Color(hex: 0xE0895A)
    static let critical = Color(hex: 0xD9605A)

    static let numberFont = Font.system(size: 13, weight: .semibold, design: .monospaced)
    static let smallNumberFont = Font.system(size: 12, weight: .medium, design: .monospaced)
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

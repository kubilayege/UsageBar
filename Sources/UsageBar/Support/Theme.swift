import SwiftUI

/// "Meter room": a warm instrument-panel dark. Hue is reserved for status;
/// apricot marks the brand and interactive controls, never data.
enum Theme {
    // Surfaces, from deepest to most raised.
    static let well = Color(hex: 0x121110)
    static let sidebar = Color(hex: 0x161413)
    static let bg = Color(hex: 0x1B1918)
    static let panel = Color(hex: 0x242120)
    static let raised = Color(hex: 0x2E2A28)
    static let bgElevated = panel

    static let line = Color.white.opacity(0.07)
    static let divider = line
    static let cardFill = panel
    static let cardStroke = Color.white.opacity(0.05)
    static let chipFill = Color.white.opacity(0.055)
    static let chipSelected = Color(hex: 0x3A3532)
    static let chipSelectedStroke = Color.clear
    static let track = well

    // Text.
    static let textPrimary = Color(hex: 0xEFE8E1)
    static let textSecondary = Color(hex: 0xA69D96)
    static let textMuted = Color(hex: 0x756D67)
    /// Text on a bone (primary) button.
    static let onBone = Color(hex: 0x1B1918)

    /// Brand and control accent.
    static let accent = Color(hex: 0xEBA27A)

    // Status. Kept apart in hue so the four steps never read as one another.
    static let ok = Color(hex: 0x7CC49A)
    static let caution = Color(hex: 0xE3BE5C)
    static let warning = Color(hex: 0xEE8A52)
    static let critical = Color(hex: 0xEF5F5A)

    // Type. Condensed readouts, expanded legends, mono for data.
    static func readout(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        Font.system(size: size, weight: weight).width(.condensed).monospacedDigit()
    }
    static let legend = Font.system(size: 9.5, weight: .semibold).width(.expanded)
    static let numberFont = readout(14)
    static let smallNumberFont = Font.system(size: 11.5, weight: .medium, design: .monospaced)
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
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

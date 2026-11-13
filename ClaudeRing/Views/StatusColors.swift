import AppKit
import SwiftUI

// The limit levels use system colors: they adapt to light and dark mode and to
// "Increase contrast" on their own. The status dot's coral and amber are
// defined below for the same four appearances.

extension UsageLevel {
    var nsColor: NSColor {
        switch self {
        case .normal: .systemGreen
        case .warning: .systemOrange
        case .critical: .systemRed
        }
    }

    var color: Color { Color(nsColor: nsColor) }
}

extension ClaudeActivity {
    /// Red stays reserved for a nearly used-up limit.
    var nsColor: NSColor {
        switch self {
        case .working: .statusCoral
        case .waiting: .statusAmber
        case .idle: .systemGreen
        }
    }

    var color: Color { Color(nsColor: nsColor) }

    /// Each state also has its own shape, so it reads without color too:
    /// filled while working, half filled while waiting, hollow when idle.
    var distinctSymbolName: String {
        switch self {
        case .working: "circle.fill"
        case .waiting: "circle.lefthalf.filled"
        case .idle: "circle"
        }
    }
}

private extension NSColor {
    /// Claude's coral, while a session works.
    static var statusCoral: NSColor {
        adaptive(name: "StatusCoral", light: 0xD97757, dark: 0xE5896B,
                 highContrastLight: 0xB5583A, highContrastDark: 0xF0A285)
    }

    /// A yellow dark enough to stand out on a light menu bar; on a dark one
    /// it is the system yellow.
    static var statusAmber: NSColor {
        adaptive(name: "StatusAmber", light: 0xE0A100, dark: 0xFFD60A,
                 highContrastLight: 0xB07E00, highContrastDark: 0xFFE066)
    }

    static func adaptive(
        name: String, light: UInt32, dark: UInt32, highContrastLight: UInt32, highContrastDark: UInt32
    ) -> NSColor {
        NSColor(name: name) { appearance in
            let match = appearance.bestMatch(from: [
                .aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
            ]) ?? .aqua
            let hex = switch match {
            case .darkAqua: dark
            case .accessibilityHighContrastAqua: highContrastLight
            case .accessibilityHighContrastDarkAqua: highContrastDark
            default: light
            }
            return NSColor(
                srgbRed: CGFloat(hex >> 16 & 0xFF) / 255,
                green: CGFloat(hex >> 8 & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        }
    }
}

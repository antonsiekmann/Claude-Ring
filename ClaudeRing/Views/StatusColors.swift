import AppKit
import SwiftUI

// System colors only: they adapt to light and dark mode and to "Increase
// contrast" on their own.

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
        case .working: .systemPurple
        case .waiting: .systemCyan
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

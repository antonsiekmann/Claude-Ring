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
    var nsColor: NSColor {
        switch self {
        case .working: .systemRed
        case .waiting: .systemCyan
        case .idle: .systemGreen
        }
    }

    var color: Color { Color(nsColor: nsColor) }

    /// Shapes that tell the states apart without color.
    var distinctSymbolName: String {
        switch self {
        case .working: "circle.fill"
        case .waiting: "circle.lefthalf.filled"
        case .idle: "circle"
        }
    }
}

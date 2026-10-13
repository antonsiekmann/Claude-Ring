import Foundation

/// What a Claude Code session is doing right now. The raw values define the
/// priority when several sessions run at once: a session that waits for an
/// answer wins over one that works, which wins over an idle one.
enum ClaudeActivity: Int, Comparable, CaseIterable, Sendable {
    case idle = 0
    case working = 1
    case waiting = 2

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// The state shown by the menu bar dot, or nil when no session runs.
    static func aggregate(_ activities: some Sequence<ClaudeActivity>) -> ClaudeActivity? {
        activities.max()
    }

    var label: LocalizedStringResource {
        switch self {
        case .idle: "Frei"
        case .working: "Arbeitet"
        case .waiting: "Wartet auf Antwort"
        }
    }

    var accessibilityDescription: String {
        switch self {
        case .idle: String(localized: "Claude Code ist frei")
        case .working: String(localized: "Claude Code arbeitet")
        case .waiting: String(localized: "Claude Code wartet auf deine Antwort")
        }
    }
}

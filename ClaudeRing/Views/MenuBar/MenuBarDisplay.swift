import Foundation

/// Everything the menu bar item shows, derived from the current state.
/// Equatable, so the status item redraws only when something visible changes.
struct MenuBarDisplay: Equatable, Sendable {
    struct Gauge: Equatable, Sendable {
        /// Filled share, 0...1.
        var fraction: Double
        /// Nil while no data is available; then only the track is drawn.
        var level: UsageLevel?
    }

    enum Graphic: Equatable, Sendable {
        case ring(Gauge)
        case bars(top: Gauge, bottom: Gauge)
        case none

        var isRing: Bool {
            if case .ring = self { true } else { false }
        }
    }

    var graphic: Graphic
    var text: String
    /// Whether the ring or bars use the level colors. The text never does.
    var colorsGauge: Bool
    /// The Claude Code status dot, or nil to hide it.
    var activity: ClaudeActivity?
    var accessibilityLabel: String

    /// The image can be a template (tinted by the system, as the HIG prefers)
    /// only when nothing in it carries color.
    var isTemplate: Bool { !colorsGauge && activity == nil }

    struct Preferences: Equatable, Sendable {
        var style: MenuBarStyle
        var limit: MenuBarLimit
        var value: MenuBarValue
        var colorsRing: Bool
        var showsStatusDot: Bool
    }

    static func make(
        snapshot: UsageSnapshot?,
        hasError: Bool,
        preferences: Preferences,
        activity: ClaudeActivity?,
        locale: Locale = .current
    ) -> MenuBarDisplay {
        let session = snapshot?.session
        let weekly = snapshot?.weekly
        let primary = switch preferences.limit {
        case .session: session ?? weekly
        case .weekly: weekly ?? session
        }
        let showsUsed = preferences.value == .used
        let dot = preferences.showsStatusDot ? activity : nil

        func gauge(_ info: UsageWindowInfo?) -> Gauge {
            guard let info else { return Gauge(fraction: 0, level: nil) }
            let shown = showsUsed ? info.usedPercent : info.remainingPercent
            return Gauge(fraction: shown / 100, level: info.level)
        }

        func number(_ info: UsageWindowInfo) -> Int {
            Int((showsUsed ? info.usedPercent : info.remainingPercent).rounded())
        }

        let graphic: Graphic = switch preferences.style {
        case .ring: .ring(gauge(primary))
        case .bars: .bars(top: gauge(session), bottom: gauge(weekly))
        case .numbers: .none
        }

        var text: String
        if let primary {
            text = switch preferences.style {
            case .ring, .bars:
                (Double(number(primary)) / 100).formatted(.percent.precision(.fractionLength(0)).locale(locale))
            case .numbers:
                [session, weekly].compactMap { $0 }.map { String(number($0)) }.joined(separator: " · ")
            }
            // Mark stale data when the last refresh failed.
            if hasError { text += " !" }
        } else {
            text = hasError ? "–" : "…"
        }

        return MenuBarDisplay(
            graphic: graphic,
            text: text,
            colorsGauge: preferences.colorsRing && preferences.style != .numbers,
            activity: dot,
            accessibilityLabel: accessibilityLabel(
                session: session, weekly: weekly, showsUsed: showsUsed, hasError: hasError, activity: dot
            )
        )
    }

    private static func accessibilityLabel(
        session: UsageWindowInfo?,
        weekly: UsageWindowInfo?,
        showsUsed: Bool,
        hasError: Bool,
        activity: ClaudeActivity?
    ) -> String {
        var parts: [String] = []
        if let session {
            let percent = Int((showsUsed ? session.usedPercent : session.remainingPercent).rounded())
            parts.append(showsUsed
                ? String(localized: "Sitzung \(percent) Prozent genutzt")
                : String(localized: "Sitzung \(percent) Prozent übrig"))
        }
        if let weekly {
            let percent = Int((showsUsed ? weekly.usedPercent : weekly.remainingPercent).rounded())
            parts.append(showsUsed
                ? String(localized: "Woche \(percent) Prozent genutzt")
                : String(localized: "Woche \(percent) Prozent übrig"))
        }
        if parts.isEmpty {
            parts.append(hasError ? String(localized: "Keine Nutzungsdaten") : String(localized: "Lade Nutzungsdaten"))
        } else if hasError {
            parts.append(String(localized: "Daten veraltet"))
        }
        if let activity {
            parts.append(activity.accessibilityDescription)
        }
        return String(localized: "Claude-Nutzung: \(parts.joined(separator: ", "))")
    }
}

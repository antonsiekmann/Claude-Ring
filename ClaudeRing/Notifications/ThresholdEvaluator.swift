import Foundation

/// Decides which usage notifications are due. Pure, so it is easy to test.
///
/// Each usage window gets at most one warning and one critical notification
/// per period. A period is identified by the window's reset time; when it
/// changes, the window starts over.
enum ThresholdEvaluator {
    struct State: Codable, Equatable, Sendable {
        /// Reset time of the period the state belongs to, rounded to the minute.
        var period: Date?
        /// 0 = nothing sent, 1 = warning sent, 2 = critical sent.
        var notifiedLevel: Int
    }

    enum Event: Equatable, Sendable {
        case warning(usedPercent: Int)
        case critical(usedPercent: Int)
        /// The previous period had reached the warning threshold and is over.
        case reset
    }

    struct Thresholds: Equatable, Sendable {
        var warning: Int
        var critical: Int
    }

    static func evaluate(
        window: UsageWindowInfo,
        state: State?,
        thresholds: Thresholds,
        notifiesOnReset: Bool
    ) -> (events: [Event], state: State) {
        let period = window.resetsAt.map(roundedToMinute)
        var state = state ?? State(period: period, notifiedLevel: 0)
        var events: [Event] = []

        if state.period != period {
            if notifiesOnReset && state.notifiedLevel > 0 {
                events.append(.reset)
            }
            state = State(period: period, notifiedLevel: 0)
        }

        let used = Int(window.usedPercent.rounded())
        let level = used >= thresholds.critical ? 2 : used >= thresholds.warning ? 1 : 0
        if level > state.notifiedLevel {
            events.append(level == 2 ? .critical(usedPercent: used) : .warning(usedPercent: used))
            state.notifiedLevel = level
        }
        return (events, state)
    }

    private static func roundedToMinute(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded() * 60)
    }
}

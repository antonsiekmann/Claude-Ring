import Foundation
import Testing
@testable import ClaudeRing

struct ThresholdEvaluatorTests {
    private let thresholds = ThresholdEvaluator.Thresholds(warning: 80, critical: 95)
    private let reset = Date(timeIntervalSince1970: 1_760_000_000)

    private func window(used: Double, resetsAt: Date?) -> UsageWindowInfo {
        UsageWindowInfo(id: "session", title: "Sitzung", usedPercent: used, resetsAt: resetsAt)
    }

    private func run(_ steps: [(used: Double, resetsAt: Date?)], notifiesOnReset: Bool = false) -> [[ThresholdEvaluator.Event]] {
        var state: ThresholdEvaluator.State?
        return steps.map { step in
            let result = ThresholdEvaluator.evaluate(
                window: window(used: step.used, resetsAt: step.resetsAt),
                state: state, thresholds: thresholds, notifiesOnReset: notifiesOnReset
            )
            state = result.state
            return result.events
        }
    }

    @Test func `Warns once when crossing the warning threshold`() {
        let events = run([(50, reset), (81, reset), (85, reset), (90, reset)])
        #expect(events == [[], [.warning(usedPercent: 81)], [], []])
    }

    @Test func `Sends only the critical notification when jumping past both thresholds`() {
        let events = run([(10, reset), (96, reset)])
        #expect(events == [[], [.critical(usedPercent: 96)]])
    }

    @Test func `Warns again in the next period`() {
        let next = reset.addingTimeInterval(5 * 3600)
        let events = run([(85, reset), (5, next), (82, next)])
        #expect(events == [[.warning(usedPercent: 85)], [], [.warning(usedPercent: 82)]])
    }

    @Test func `Ignores jitter in the reset time`() {
        let events = run([(85, reset), (86, reset.addingTimeInterval(1.2))])
        #expect(events == [[.warning(usedPercent: 85)], []])
    }

    @Test func `Reports a reset only after the warning threshold was reached`() {
        let next = reset.addingTimeInterval(5 * 3600)
        let afterWarning = run([(85, reset), (2, next)], notifiesOnReset: true)
        let withoutWarning = run([(40, reset), (2, next)], notifiesOnReset: true)

        #expect(afterWarning == [[.warning(usedPercent: 85)], [.reset]])
        #expect(withoutWarning == [[], []])
    }

    @Test func `Reports the reset when the window expires without new usage`() {
        let events = run([(97, reset), (0, nil)], notifiesOnReset: true)
        #expect(events == [[.critical(usedPercent: 97)], [.reset]])
    }
}

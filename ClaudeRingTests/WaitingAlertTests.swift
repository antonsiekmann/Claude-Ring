import Foundation
import Testing
@testable import ClaudeRing

private let start = Date(timeIntervalSince1970: 1_000_000)

private func session(
    _ id: String, _ activity: ClaudeActivity, since: Date = start.addingTimeInterval(5)
) -> ClaudeSession {
    ClaudeSession(id: id, pid: 100, projectName: id, isBackground: false, activity: activity, since: since)
}

struct WaitingAlertTrackerTests {
    @Test func `Reports a session that starts waiting once`() {
        var tracker = WaitingAlertTracker(watchingSince: start)
        #expect(tracker.update([session("a", .working)]) == .init())

        let waiting = session("a", .waiting)
        #expect(tracker.update([waiting]).started == [waiting])
        #expect(tracker.isWaiting(waiting))
        // The same wait in the next update is not new.
        #expect(tracker.update([waiting, session("b", .working)]) == .init())
    }

    @Test func `Ends the wait when the session continues or quits`() {
        var tracker = WaitingAlertTracker(watchingSince: start)
        let waiting = session("a", .waiting)
        _ = tracker.update([waiting])

        #expect(tracker.update([session("a", .working)]) == .init(ended: ["a"]))
        #expect(!tracker.isWaiting(waiting))

        _ = tracker.update([session("a", .waiting, since: start.addingTimeInterval(20))])
        #expect(tracker.update([]) == .init(ended: ["a"]))
    }

    @Test func `Counts a new wait after an answer as new`() {
        var tracker = WaitingAlertTracker(watchingSince: start)
        _ = tracker.update([session("a", .waiting)])

        // Answered and asked again between two updates: only the start differs.
        let again = session("a", .waiting, since: start.addingTimeInterval(30))
        #expect(tracker.update([again]) == .init(started: [again], ended: ["a"]))
    }

    @Test func `Skips waits that began before the app was watching`() {
        var tracker = WaitingAlertTracker(watchingSince: start)
        let old = session("a", .waiting, since: start.addingTimeInterval(-60))

        #expect(tracker.update([old]).started.isEmpty)
        // Its end still counts, so a delivered notification would go away.
        #expect(tracker.update([]) == .init(ended: ["a"]))
    }

    @Test func `Reports several waiting sessions in the order they started`() {
        var tracker = WaitingAlertTracker(watchingSince: start)
        let later = session("a", .waiting, since: start.addingTimeInterval(9))
        let earlier = session("b", .waiting, since: start.addingTimeInterval(3))

        #expect(tracker.update([later, earlier, session("c", .idle)]).started == [earlier, later])
    }
}

struct HostAppTests {
    @Test func `Finds the parent of a process`() {
        // The test host may have been started by launchd, which counts as none.
        let parent = getppid()
        #expect(HostApp.parentPID(of: getpid()) == (parent > 1 ? parent : nil))
    }

    @Test func `Stops at launchd and missing processes`() {
        #expect(HostApp.parentPID(of: 1) == nil)
        #expect(HostApp.parentPID(of: 0) == nil)
        #expect(HostApp.parentPID(of: 99_999) == nil)
    }
}

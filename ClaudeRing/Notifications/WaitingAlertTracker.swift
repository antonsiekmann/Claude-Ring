import Foundation

/// Decides which waits of Claude Code sessions get a notification: every time
/// a session starts waiting for an answer or an approval, once.
///
/// Waits that began before the app was watching are left out, so a restart,
/// such as after an update, does not repeat notifications already sent.
struct WaitingAlertTracker {
    struct Changes: Equatable {
        /// Sessions that have started waiting since the last update.
        var started: [ClaudeSession] = []
        /// Sessions whose wait is over: answered, interrupted or ended.
        var ended: [String] = []
    }

    private let watchingSince: Date
    /// The start of the current wait, per session.
    private var waits: [String: Date] = [:]

    init(watchingSince: Date = .now) {
        self.watchingSince = watchingSince
    }

    /// Call with every new list of sessions.
    mutating func update(_ sessions: [ClaudeSession]) -> Changes {
        var current: [String: ClaudeSession] = [:]
        for session in sessions where session.activity == .waiting {
            current[session.id] = session
        }
        var changes = Changes()
        // A new start time means the session answered and waits again.
        changes.ended = waits.keys.filter { current[$0]?.since != waits[$0] }.sorted()
        changes.started = current.values
            .filter { waits[$0.id] != $0.since && $0.since >= watchingSince }
            .sorted { $0.since < $1.since }
        waits = current.mapValues(\.since)
        return changes
    }

    /// True while `session` still waits since the same moment.
    func isWaiting(_ session: ClaudeSession) -> Bool {
        waits[session.id] == session.since
    }
}

import Foundation

/// One line written by the hook script: the latest event of a session.
struct HookEventRecord: Decodable, Equatable, Sendable {
    var pid: Int32
    var event: String
    var session: String?
    var cwd: String?
    var tool: String?
    /// `notification_type` of Notification events.
    var ntype: String?
    /// `source` of SessionStart events (startup, resume, clear, compact).
    var source: String?
    /// `reason` of SessionEnd events.
    var reason: String?
    /// `error` of StopFailure events.
    var error: String?
    /// `CLAUDE_CODE_SESSION_KIND` of the session's process; "bg" for
    /// sessions that Claude Code runs in the background.
    var kind: String?
}

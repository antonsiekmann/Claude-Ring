import Foundation

/// Maps the latest hook event of a session to what the session is doing.
enum SessionReducer {
    /// Tools that wait for the person at the keyboard.
    static let questionTools: Set<String> = ["AskUserQuestion", "ExitPlanMode"]

    /// - Returns: The session's activity after `record`, or nil when the
    ///   session has ended.
    static func activity(after record: HookEventRecord, previous: ClaudeActivity?) -> ClaudeActivity? {
        switch record.event {
        case "SessionStart":
            // Auto-compaction can start a "new" session in the middle of a turn.
            return record.source == "compact" ? previous ?? .working : .idle
        case "UserPromptSubmit", "PostToolUse", "PostToolUseFailure", "ElicitationResult":
            return .working
        case "PreToolUse":
            return questionTools.contains(record.tool ?? "") ? .waiting : .working
        case "PermissionRequest", "Elicitation":
            return .waiting
        case "Notification":
            switch record.ntype {
            case "permission_prompt", "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input":
                return .waiting
            case "idle_prompt":
                // Sent about a minute after Claude finished without new input.
                // Also clears states left behind by an interrupted turn.
                return .idle
            default:
                return previous ?? .idle
            }
        case "Stop", "StopFailure":
            return .idle
        case "SessionEnd":
            return nil
        default:
            return previous ?? .idle
        }
    }
}

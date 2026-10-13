import Foundation

/// The shell script Claude Code runs for every registered hook event.
///
/// It records only a whitelist of fields (no prompt text, no tool input) in
/// one small file per session, prints nothing (stdout of some hooks ends up in
/// Claude's context) and always exits 0, so it can never block Claude Code.
enum HookScript {
    static let version = 3

    static let contents = #"""
    #!/bin/sh
    # claude-ring-hook v\#(version), installed and managed by Claude Ring
    # (ClaudeRing.app). Records the state of the calling Claude Code
    # session for the menu bar. Prints nothing and always exits 0.
    exec >/dev/null 2>&1
    DIR="$HOME/Library/Application Support/ClaudeRing/Sessions"
    [ -d "$DIR" ] || exit 0

    # Claude Code runs hooks through "sh -c", so the session's process is the
    # parent of that shell.
    pid=$PPID
    comm=$(/bin/ps -o comm= -p "$pid")
    comm=${comm##*/}
    comm=${comm#-}
    case "$comm" in
      sh|bash|zsh|dash|ksh) pid=$(/bin/ps -o ppid= -p "$pid" | /usr/bin/tr -d ' ') ;;
    esac
    # PID 1 means Claude Code died and launchd adopted the shell.
    case "$pid" in ''|*[!0-9]*|0|1) exit 0 ;; esac

    tmp="$DIR/.tmp.$$"
    /usr/bin/jq -c --argjson pid "$pid" '{
      v: 1, pid: $pid, event: .hook_event_name, session: .session_id, cwd: .cwd,
      tool: .tool_name, ntype: .notification_type, source: .source, reason: .reason, error: .error,
      kind: $ENV.CLAUDE_CODE_SESSION_KIND
    }' > "$tmp" || { rm -f "$tmp"; exit 0; }
    sid=$(/usr/bin/jq -r '.session // ""' "$tmp" | /usr/bin/tr -cd 'A-Za-z0-9-')
    /bin/mv -f "$tmp" "$DIR/$pid-${sid:-unknown}.json"
    exit 0

    """#
}

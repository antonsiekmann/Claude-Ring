import Foundation

/// Adds and removes this app's hook entries in Claude Code's settings,
/// leaving every other setting and hook exactly as it was.
enum HookSettingsMerger {
    /// Identifies our hook commands, including those installed under the
    /// app's former name Claude Status, so an update replaces them.
    static let markers = ["ClaudeRing/claude-ring-hook.sh", "ClaudeStatusChecker/claude-status-hook.sh"]

    /// Runs the script only if it exists, so a deleted app never makes
    /// Claude Code report failing hooks.
    static let command = #"H="$HOME/Library/Application Support/ClaudeRing/claude-ring-hook.sh"; [ -x "$H" ] && "$H"; exit 0"#

    struct Registration: Equatable {
        var event: String
        var matcher: String?
        /// SessionEnd hooks share a short time budget, so they get no own timeout.
        var timeout: Int? = 5
    }

    static let registrations: [Registration] = [
        Registration(event: "SessionStart"),
        Registration(event: "UserPromptSubmit"),
        Registration(event: "PreToolUse", matcher: "AskUserQuestion|ExitPlanMode"),
        Registration(event: "PermissionRequest"),
        Registration(event: "PostToolUse"),
        Registration(event: "PostToolUseFailure"),
        Registration(event: "Notification"),
        Registration(event: "Elicitation"),
        Registration(event: "ElicitationResult"),
        Registration(event: "Stop"),
        Registration(event: "StopFailure"),
        Registration(event: "SessionEnd", timeout: nil),
    ]

    /// Our entries replace older ones of ours; everything else stays.
    static func installing(into settings: OrderedJSON) -> OrderedJSON {
        var settings = removing(from: settings)
        if case .null = settings { settings = .object([]) }
        var hooks = settings["hooks"] ?? .object([])
        for registration in registrations {
            var groups = hooks[registration.event]?.arrayValue ?? []
            groups.append(group(for: registration))
            hooks.set(registration.event, .array(groups))
        }
        settings.set("hooks", hooks)
        return settings
    }

    static func removing(from settings: OrderedJSON) -> OrderedJSON {
        guard case .object(let events) = settings["hooks"] ?? .null else { return settings }

        var cleaned: [(key: String, value: OrderedJSON)] = []
        var removedOverall = false
        for (event, value) in events {
            guard let groups = value.arrayValue else {
                cleaned.append((event, value))
                continue
            }
            var keptGroups: [OrderedJSON] = []
            var removedAny = false
            for group in groups {
                guard let commands = group["hooks"]?.arrayValue else {
                    keptGroups.append(group)
                    continue
                }
                let kept = commands.filter { !isOurs($0) }
                if kept.count == commands.count {
                    keptGroups.append(group)
                    continue
                }
                removedAny = true
                if !kept.isEmpty {
                    var trimmed = group
                    trimmed.set("hooks", .array(kept))
                    keptGroups.append(trimmed)
                }
            }
            removedOverall = removedOverall || removedAny
            // Drop an event only when it became empty through our removal.
            if !(removedAny && keptGroups.isEmpty) {
                cleaned.append((event, .array(keptGroups)))
            }
        }

        guard removedOverall else { return settings }
        var result = settings
        result.set("hooks", cleaned.isEmpty ? nil : .object(cleaned))
        return result
    }

    /// True when every registration is present with the current command.
    static func isInstalled(in settings: OrderedJSON) -> Bool {
        registrations.allSatisfy { registration in
            let groups = settings["hooks"]?[registration.event]?.arrayValue ?? []
            return groups.contains(group(for: registration))
        }
    }

    /// True when any of our entries is present, current or not.
    static func containsOurs(in settings: OrderedJSON) -> Bool {
        guard case .object(let events) = settings["hooks"] ?? .null else { return false }
        return events.contains { _, value in
            (value.arrayValue ?? []).contains { group in
                (group["hooks"]?.arrayValue ?? []).contains(where: isOurs)
            }
        }
    }

    private static func isOurs(_ hook: OrderedJSON) -> Bool {
        guard let command = hook["command"]?.stringValue else { return false }
        return markers.contains { command.contains($0) }
    }

    private static func group(for registration: Registration) -> OrderedJSON {
        var hook: [(key: String, value: OrderedJSON)] = [
            ("type", .string("command")),
            ("command", .string(command)),
        ]
        if let timeout = registration.timeout {
            hook.append(("timeout", .number(String(timeout))))
        }
        var group: [(key: String, value: OrderedJSON)] = []
        if let matcher = registration.matcher {
            group.append(("matcher", .string(matcher)))
        }
        group.append(("hooks", .array([.object(hook)])))
        return .object(group)
    }
}

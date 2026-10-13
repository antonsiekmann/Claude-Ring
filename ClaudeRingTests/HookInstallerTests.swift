import Foundation
import Testing
@testable import ClaudeRing

/// Shaped like a real `~/.claude/settings.json`: unsorted keys, foreign hooks
/// with and without matchers, written like `JSON.stringify(value, null, 2)`.
private let realisticSettings = #"""
{
  "cleanupPeriodDays": 30,
  "permissions": {
    "allow": [
      "Bash(git status)",
      "WebFetch(domain:docs.example.com)"
    ],
    "defaultMode": "auto"
  },
  "hooks": {
    "Notification": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/Users/me/.config/iterm2/cc-status"
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Edit|Write|MultiEdit",
        "hooks": [
          {
            "type": "command",
            "command": "/Users/me/.claude/hooks/lint-edited-file.sh"
          }
        ]
      },
      {
        "hooks": [
          {
            "type": "command",
            "command": "/Users/me/.config/iterm2/cc-status"
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/Users/me/.config/iterm2/cc-status"
          }
        ]
      }
    ]
  },
  "statusLine": {
    "type": "command",
    "command": "printf \"%s\" \"ä\\n\""
  },
  "language": "Deutsch",
  "effortLevel": 1.50,
  "tui": {},
  "skipWorkflowUsageWarning": true,
  "extraKnownMarketplaces": []
}

"""#

struct OrderedJSONTests {
    @Test func `Round-trips a settings file byte for byte`() throws {
        let json = try OrderedJSON(parsing: Data(realisticSettings.utf8))
        #expect(json.serialized() + "\n" == realisticSettings.replacingOccurrences(of: "\\u00e4", with: "ä"))
    }

    @Test func `Keeps key order and number spelling`() throws {
        let json = try OrderedJSON(parsing: Data(#"{"b": 1.50, "a": 1e3, "c": [true, null]}"#.utf8))
        guard case .object(let members) = json else { Issue.record("not an object"); return }

        #expect(members.map(\.key) == ["b", "a", "c"])
        #expect(json["b"] == .number("1.50"))
        #expect(json["a"] == .number("1e3"))
    }

    @Test func `Decodes escapes and surrogate pairs`() throws {
        let json = try OrderedJSON(parsing: Data(#"{"s": "a\"b\\c\/d\nü😀"}"#.utf8))
        #expect(json["s"] == .string("a\"b\\c/d\nü😀"))
    }

    @Test func `Escapes like JSON.stringify`() {
        let json = OrderedJSON.object([("k", .string("\"\\\n\t\u{01}ü/"))])
        #expect(json.serialized() == "{\n  \"k\": \"\\\"\\\\\\n\\t\\u0001ü/\"\n}")
    }

    @Test(arguments: ["", "{", #"{"a" 1}"#, "[1,]", #"{"a": tru}"#, "{} x", #"{"s": "\ud800\u0041"}"#])
    func `Rejects invalid JSON`(text: String) {
        #expect(throws: OrderedJSON.ParseError.self) {
            try OrderedJSON(parsing: Data(text.utf8))
        }
    }
}

struct HookSettingsMergerTests {
    private func original() throws -> OrderedJSON {
        try OrderedJSON(parsing: Data(realisticSettings.utf8))
    }

    @Test func `Adds a group for every registration after the existing ones`() throws {
        let installed = HookSettingsMerger.installing(into: try original())

        #expect(HookSettingsMerger.isInstalled(in: installed))
        let postToolUse = try #require(installed["hooks"]?["PostToolUse"]?.arrayValue)
        #expect(postToolUse.count == 3)
        #expect(postToolUse[0] == (try original())["hooks"]?["PostToolUse"]?.arrayValue?[0])
        let preToolUse = try #require(installed["hooks"]?["PreToolUse"]?.arrayValue)
        #expect(preToolUse.first?["matcher"] == .string("AskUserQuestion|ExitPlanMode"))
    }

    @Test func `Leaves every other setting in place and in order`() throws {
        let installed = HookSettingsMerger.installing(into: try original())
        guard case .object(let before) = try original(), case .object(let after) = installed else {
            Issue.record("not an object"); return
        }

        #expect(after.map(\.key) == before.map(\.key))
        for (key, value) in before where key != "hooks" {
            #expect(installed[key] == value)
        }
    }

    @Test func `Installing twice changes nothing`() throws {
        let once = HookSettingsMerger.installing(into: try original())
        #expect(HookSettingsMerger.installing(into: once) == once)
    }

    @Test func `Removing restores the original exactly`() throws {
        let installed = HookSettingsMerger.installing(into: try original())
        let removed = HookSettingsMerger.removing(from: installed)

        #expect(removed == (try original()))
        #expect(!HookSettingsMerger.containsOurs(in: removed))
    }

    @Test func `Removing without our entries changes nothing`() throws {
        #expect(HookSettingsMerger.removing(from: try original()) == (try original()))
    }

    @Test func `Creates the hooks object in empty settings`() {
        let installed = HookSettingsMerger.installing(into: .object([]))

        #expect(HookSettingsMerger.isInstalled(in: installed))
        #expect(HookSettingsMerger.removing(from: installed) == .object([]))
    }

    /// The second path is from Claude Status, the app's former name.
    @Test(arguments: ["/old/path/ClaudeRing/claude-ring-hook.sh", "/old/path/ClaudeStatusChecker/claude-status-hook.sh"])
    func `Recognizes outdated entries`(command: String) throws {
        let outdatedGroup = OrderedJSON.object([("hooks", .array([.object([
            ("type", .string("command")),
            ("command", .string(command)),
        ])]))])
        var settings = try original()
        settings.set("hooks", .object([("Stop", .array([outdatedGroup]))]))

        #expect(HookSettingsMerger.containsOurs(in: settings))
        #expect(!HookSettingsMerger.isInstalled(in: settings))
        #expect(!HookSettingsMerger.containsOurs(in: HookSettingsMerger.installing(into: settings).removingOurs()))
    }
}

private extension OrderedJSON {
    func removingOurs() -> OrderedJSON { HookSettingsMerger.removing(from: self) }
}

@MainActor
struct HookInstallerTests {
    private let home: URL
    private let paths: HookInstaller.Paths
    private let fileManager = FileManager.default

    init() throws {
        home = fileManager.temporaryDirectory.appending(path: "hook-installer-\(UUID())", directoryHint: .isDirectory)
        paths = HookInstaller.Paths(home: home)
        try fileManager.createDirectory(at: paths.claudeSettings.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    private func writeSettings(_ text: String = realisticSettings) throws {
        try Data(text.utf8).write(to: paths.claudeSettings)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.claudeSettings.path)
    }

    private func permissions(_ url: URL) throws -> Int {
        (try fileManager.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    @Test func `Installs the script and registers the hooks`() throws {
        try writeSettings()
        let installer = HookInstaller(paths: paths)
        #expect(installer.status == .notInstalled)

        installer.install()

        #expect(installer.lastError == nil)
        #expect(installer.status == .installed)
        #expect(try permissions(paths.script) == 0o755)
        #expect(try permissions(paths.sessions) == 0o700)
        #expect(try permissions(paths.claudeSettings) == 0o600)
        let backup = try #require(installer.lastBackup)
        #expect(try Data(contentsOf: backup) == Data(realisticSettings.utf8))
        #expect(try permissions(backup) == 0o600)
    }

    @Test func `Uninstalling restores the file byte for byte`() throws {
        let original = realisticSettings.replacingOccurrences(of: "\\u00e4", with: "ä")
        try writeSettings(original)
        let installer = HookInstaller(paths: paths)

        installer.install()
        installer.uninstall()

        #expect(installer.status == .notInstalled)
        #expect(try String(contentsOf: paths.claudeSettings, encoding: .utf8) == original)
        #expect(!fileManager.fileExists(atPath: paths.script.path))
    }

    @Test func `Leaves invalid settings untouched`() throws {
        try writeSettings("{ not json")
        let installer = HookInstaller(paths: paths)

        installer.install()

        #expect(installer.lastError != nil)
        #expect(try String(contentsOf: paths.claudeSettings, encoding: .utf8) == "{ not json")
    }

    @Test func `Creates the settings file when it does not exist yet`() throws {
        let installer = HookInstaller(paths: paths)

        installer.install()

        #expect(installer.status == .installed)
        #expect(try permissions(paths.claudeSettings) == 0o600)
    }

    @Test func `Edits the target of a symlinked settings file`() throws {
        let target = home.appending(path: "dotfiles-settings.json")
        try Data(realisticSettings.utf8).write(to: target)
        try fileManager.createSymbolicLink(at: paths.claudeSettings, withDestinationURL: target)
        let installer = HookInstaller(paths: paths)

        installer.install()

        #expect(installer.status == .installed)
        #expect(try fileManager.destinationOfSymbolicLink(atPath: paths.claudeSettings.path) == target.path)
        #expect(HookSettingsMerger.isInstalled(in: try OrderedJSON(parsing: Data(contentsOf: target))))
    }

    @Test func `Keeps only the newest five backups`() throws {
        try writeSettings()
        let installer = HookInstaller(paths: paths)
        for _ in 0..<4 {
            installer.install()
            installer.uninstall()
        }

        let backups = try fileManager.contentsOfDirectory(atPath: paths.backups.path)
        #expect(backups.count == 5)
        #expect(installer.lastError == nil)
    }

    @Test func `Rewrites an outdated script without touching the settings`() throws {
        try writeSettings()
        let installer = HookInstaller(paths: paths)
        installer.install()
        try Data("#!/bin/sh\n".utf8).write(to: paths.script)
        let settingsBefore = try Data(contentsOf: paths.claudeSettings)
        installer.refresh()
        #expect(installer.status == .needsUpdate)

        installer.repairScriptIfNeeded()

        #expect(installer.status == .installed)
        #expect(try Data(contentsOf: paths.claudeSettings) == settingsBefore)
    }
}

/// Runs the real hook script the way Claude Code does: through `sh -c` with
/// the hook payload on stdin.
struct HookScriptTests {
    private struct Result {
        var status: Int32
        var output: Data
        var files: [URL]
    }

    private func runHook(stdin: String, createSessionsDirectory: Bool = true, environment: [String: String] = [:]) throws -> Result {
        let home = FileManager.default.temporaryDirectory.appending(path: "hook-script-\(UUID())", directoryHint: .isDirectory)
        let paths = HookInstaller.Paths(home: home)
        try FileManager.default.createDirectory(at: paths.appSupport, withIntermediateDirectories: true)
        if createSessionsDirectory {
            try FileManager.default.createDirectory(at: paths.sessions, withIntermediateDirectories: true)
        }
        try Data(HookScript.contents.utf8).write(to: paths.script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.script.path)

        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", HookSettingsMerger.command]
        process.environment = environment.merging(["HOME": home.path, "PATH": "/usr/bin:/bin"]) { $1 }
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        try process.run()
        input.fileHandleForWriting.write(Data(stdin.utf8))
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let files = (try? FileManager.default.contentsOfDirectory(at: paths.sessions, includingPropertiesForKeys: nil)) ?? []
        return Result(status: process.terminationStatus, output: data, files: files)
    }

    @Test func `Records a whitelisted record for the calling process`() throws {
        let result = try runHook(stdin: #"""
        {"hook_event_name": "PreToolUse", "session_id": "abc-123", "cwd": "/Users/me/project",
         "tool_name": "AskUserQuestion", "tool_input": {"questions": "secret"}, "prompt": "secret"}
        """#)

        #expect(result.status == 0)
        #expect(result.output.isEmpty)
        let file = try #require(result.files.first)
        #expect(file.lastPathComponent == "\(getpid())-abc-123.json")
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(!text.contains("secret"))
        let record = try JSONDecoder().decode(HookEventRecord.self, from: Data(text.utf8))
        #expect(record.event == "PreToolUse")
        #expect(record.tool == "AskUserQuestion")
        #expect(record.cwd == "/Users/me/project")
        #expect(record.pid == getpid())
        #expect(record.kind == nil)
    }

    @Test func `Records that Claude Code runs the session in the background`() throws {
        let result = try runHook(
            stdin: #"{"hook_event_name": "SessionStart", "session_id": "abc", "source": "resume"}"#,
            environment: ["CLAUDE_CODE_SESSION_KIND": "bg"]
        )

        let file = try #require(result.files.first)
        let record = try JSONDecoder().decode(HookEventRecord.self, from: Data(contentsOf: file))
        #expect(record.kind == "bg")
    }

    @Test func `Stays silent and successful on garbage input`() throws {
        let result = try runHook(stdin: "not json")

        #expect(result.status == 0)
        #expect(result.output.isEmpty)
        #expect(result.files.isEmpty)
    }

    @Test func `Does nothing while the app has not set up its folder`() throws {
        let result = try runHook(stdin: #"{"hook_event_name": "Stop", "session_id": "x"}"#, createSessionsDirectory: false)

        #expect(result.status == 0)
        #expect(result.output.isEmpty)
    }
}

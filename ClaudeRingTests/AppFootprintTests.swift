import Foundation
import Testing
@testable import ClaudeRing

struct AppFootprintTests {
    private let home: URL
    private let footprint: AppFootprint
    private let fileManager = FileManager.default

    init() throws {
        home = fileManager.temporaryDirectory.appending(path: "footprint-\(UUID())", directoryHint: .isDirectory)
        footprint = AppFootprint(home: home, bundleIdentifier: "eu.siekmann.ClaudeRing", executableName: "ClaudeRing")
    }

    private func create(_ relativePath: String, directory: Bool = false) throws -> URL {
        let url = home.appending(path: relativePath)
        if directory {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url.appending(path: "content"))
        } else {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        return url
    }

    private func exists(_ url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
    }

    @Test func `Removes everything the app created`() throws {
        let ours = [
            try create("Library/Application Support/ClaudeRing/Sessions", directory: true),
            try create("Library/Application Support/ClaudeRing/Backups/settings-1.json"),
            try create("Library/Application Support/ClaudeRing/claude-ring-hook.sh"),
            try create("Library/Caches/eu.siekmann.ClaudeRing", directory: true),
            try create("Library/Caches/ClaudeRing", directory: true),
            try create("Library/HTTPStorages/eu.siekmann.ClaudeRing", directory: true),
            try create("Library/HTTPStorages/ClaudeRing", directory: true),
            try create("Library/HTTPStorages/eu.siekmann.ClaudeRing.binarycookies"),
            try create("Library/Saved Application State/eu.siekmann.ClaudeRing.savedState", directory: true),
            try create("Library/Preferences/eu.siekmann.ClaudeRing.plist"),
            try create(".claude/.settings.json.\(UUID().uuidString)"),
        ]

        let failures = footprint.removeItems(
            includingPreferencesFile: true, settingsDirectories: [home.appending(path: ".claude")]
        )

        #expect(failures.isEmpty)
        for url in ours {
            #expect(!exists(url), "\(url.path) is still there")
        }
    }

    @Test func `Leaves everything else alone`() throws {
        let foreign = [
            try create(".claude/settings.json"),
            try create(".claude/.settings.json.backup"),
            try create(".claude/.settings.json.not-a-uuid"),
            try create(".claude/.credentials.json"),
            try create("Library/Caches/com.example.Other", directory: true),
            try create("Library/Application Support/Claude", directory: true),
            try create("Library/Preferences/com.example.Other.plist"),
        ]

        footprint.removeItems(includingPreferencesFile: true, settingsDirectories: [home.appending(path: ".claude")])

        for url in foreign {
            #expect(exists(url), "\(url.path) was removed")
        }
    }

    @Test func `Removes work folders of interrupted updates and the folders around them`() throws {
        let dmg = try create("Library/Caches/eu.siekmann.ClaudeRing/Updates/\(UUID().uuidString)/ClaudeRing.dmg")

        let failures = footprint.removeUpdateWorkspaces()

        #expect(failures.isEmpty)
        #expect(!exists(footprint.updatesDirectory))
        #expect(!exists(home.appending(path: "Library/Caches/eu.siekmann.ClaudeRing")))
        #expect(!exists(dmg))
    }

    @Test func `Keeps other caches when removing update folders`() throws {
        _ = try create("Library/Caches/eu.siekmann.ClaudeRing/Updates/\(UUID().uuidString)/ClaudeRing.dmg")
        let other = try create("Library/Caches/eu.siekmann.ClaudeRing/other")

        footprint.removeUpdateWorkspaces()

        #expect(!exists(footprint.updatesDirectory))
        #expect(exists(other))
    }

    @Test func `Ejects a disk image left attached, without touching what it links to`() throws {
        let outside = try create("outside/keep-me")
        let source = home.appending(path: "image-source", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: source.appending(path: "file"))
        try fileManager.createSymbolicLink(at: source.appending(path: "link"), withDestinationURL: outside.deletingLastPathComponent())
        let image = home.appending(path: "test.dmg")
        #expect(run("/usr/bin/hdiutil", "create", "-quiet", "-srcfolder", source.path, "-fs", "HFS+", "-format", "UDZO", image.path))

        let workspace = footprint.updatesDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let mountPoint = workspace.appending(path: UpdateInstaller.mountFolderName, directoryHint: .isDirectory)
        try fileManager.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        #expect(run("/usr/bin/hdiutil", "attach", image.path, "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", mountPoint.path))
        // Only for a failing test: never leave the image attached.
        defer { if exists(mountPoint) { _ = run("/usr/bin/hdiutil", "detach", mountPoint.path, "-quiet", "-force") } }
        #expect(exists(mountPoint.appending(path: "file")))

        let failures = footprint.removeUpdateWorkspaces()

        #expect(failures.isEmpty)
        #expect(!exists(workspace))
        #expect(exists(outside))
    }

    private func run(_ tool: String, _ arguments: String...) -> Bool {
        guard let process = try? Process.run(URL(filePath: tool), arguments: arguments) else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    @Test func `Keeps the preferences file until the app quits`() throws {
        let preferences = try create("Library/Preferences/eu.siekmann.ClaudeRing.plist")

        footprint.removeItems(includingPreferencesFile: false, settingsDirectories: [])

        #expect(exists(preferences))
    }

    @Test func `Copes with nothing to remove`() {
        #expect(footprint.removeItems(includingPreferencesFile: true, settingsDirectories: [home]).isEmpty)
    }
}

@MainActor
struct HookRemovalTests {
    @Test func `Refuses to touch invalid settings`() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "removal-\(UUID())", directoryHint: .isDirectory)
        let paths = HookInstaller.Paths(home: home)
        try FileManager.default.createDirectory(at: paths.claudeSettings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ broken".utf8).write(to: paths.claudeSettings)

        #expect(throws: HookInstallerError.self) {
            try HookInstaller(paths: paths).removeHooksFromSettings()
        }
        #expect(try String(contentsOf: paths.claudeSettings, encoding: .utf8) == "{ broken")
    }

    @Test func `Takes only our hooks out`() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "removal-\(UUID())", directoryHint: .isDirectory)
        let paths = HookInstaller.Paths(home: home)
        try FileManager.default.createDirectory(at: paths.claudeSettings.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = "{\n  \"model\": \"opus\"\n}\n"
        try Data(original.utf8).write(to: paths.claudeSettings)
        let installer = HookInstaller(paths: paths)
        installer.install()

        try installer.removeHooksFromSettings()

        #expect(try String(contentsOf: paths.claudeSettings, encoding: .utf8) == original)
        #expect(installer.status == .notInstalled)
    }
}

@MainActor
struct AppUninstallerTests {
    @Test func `Removes hooks, files and preferences, then quits`() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "uninstall-\(UUID())", directoryHint: .isDirectory)
        let paths = HookInstaller.Paths(home: home)
        let footprint = AppFootprint(home: home, bundleIdentifier: "test.uninstall.\(UUID())", executableName: "Nothing")
        try FileManager.default.createDirectory(at: paths.claudeSettings.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = "{\n  \"model\": \"opus\"\n}\n"
        try Data(original.utf8).write(to: paths.claudeSettings)
        let hookInstaller = HookInstaller(paths: paths)
        hookInstaller.install()
        let caches = home.appending(path: "Library/Caches/\(footprint.bundleIdentifier)")
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        let preferences = footprint.preferencesFile
        try FileManager.default.createDirectory(at: preferences.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: preferences)

        var stopped = false
        var terminated = false
        let defaults = UserDefaults(suiteName: "uninstall-\(UUID())")!
        let uninstaller = AppUninstaller(
            footprint: footprint,
            hookInstaller: hookInstaller,
            launchAtLogin: LaunchAtLogin(),
            notifier: UsageNotifier(settings: AppSettings(defaults: defaults), defaults: defaults),
            terminate: { terminated = true }
        )
        uninstaller.stopApp = { stopped = true }

        uninstaller.uninstall()
        #expect(uninstaller.lastError == nil)
        #expect(stopped)
        #expect(terminated)
        #expect(try String(contentsOf: paths.claudeSettings, encoding: .utf8) == original)
        #expect(!FileManager.default.fileExists(atPath: paths.appSupport.path))
        #expect(!FileManager.default.fileExists(atPath: caches.path))
        #expect(FileManager.default.fileExists(atPath: preferences.path)) // removed only while quitting

        uninstaller.finishTermination()
        #expect(!FileManager.default.fileExists(atPath: preferences.path))
    }

    @Test func `Removes nothing when the hooks cannot be taken out`() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "uninstall-\(UUID())", directoryHint: .isDirectory)
        let paths = HookInstaller.Paths(home: home)
        let footprint = AppFootprint(home: home, bundleIdentifier: "test.uninstall.\(UUID())", executableName: "Nothing")
        try FileManager.default.createDirectory(at: paths.sessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.claudeSettings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ broken".utf8).write(to: paths.claudeSettings)

        var terminated = false
        let defaults = UserDefaults(suiteName: "uninstall-\(UUID())")!
        let uninstaller = AppUninstaller(
            footprint: footprint,
            hookInstaller: HookInstaller(paths: paths),
            launchAtLogin: LaunchAtLogin(),
            notifier: UsageNotifier(settings: AppSettings(defaults: defaults), defaults: defaults),
            terminate: { terminated = true }
        )

        uninstaller.uninstall()

        #expect(uninstaller.lastError != nil)
        #expect(!terminated)
        #expect(FileManager.default.fileExists(atPath: paths.sessions.path))
    }
}

struct PreferencesCleanupTests {
    private func plist(_ dictionary: [String: Any]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "prefs-\(UUID()).plist")
        try PropertyListSerialization.data(fromPropertyList: dictionary, format: .binary, options: 0).write(to: url)
        return url
    }

    @Test func `Removes an empty preferences file that appears later`() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "prefs-\(UUID()).plist")
        AppUninstaller.launchPreferencesCleanup(for: url, seconds: 4)
        try await Task.sleep(for: .milliseconds(500))
        try PropertyListSerialization.data(fromPropertyList: [String: Any](), format: .binary, options: 0).write(to: url)

        for _ in 0..<50 where FileManager.default.fileExists(atPath: url.path) {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func `Keeps a preferences file with content`() async throws {
        let url = try plist(["menuBarStyle": "ring"])
        AppUninstaller.launchPreferencesCleanup(for: url, seconds: 2)
        try await Task.sleep(for: .seconds(3))

        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}

struct UsageSnapshotCacheTests {
    @Test func `Restores the last usage data`() throws {
        let defaults = UserDefaults(suiteName: "cache-\(UUID())")!
        let cache = UsageSnapshotCache(defaults: defaults)
        let response = try UsageAPIClient.makeDecoder().decode(UsageResponse.self, from: Data(#"""
        { "limits": [ { "kind": "session", "percent": 13, "resets_at": "2026-10-08T18:00:00Z" } ],
          "seven_day_breakdown": { "rows": [ { "key": "claude_code", "display_name": "Claude Code", "percent": 40 } ] } }
        """#.utf8))
        let snapshot = UsageSnapshot(response: response, credentials: .init(
            accessToken: "secret-token", expiresAt: nil, subscriptionType: "max", rateLimitTier: nil
        ))
        let fetchedAt = Date(timeIntervalSince1970: 1_760_000_000)

        #expect(cache.load() == nil)
        cache.save(snapshot, fetchedAt: fetchedAt)

        #expect(cache.load() == .init(snapshot: snapshot, fetchedAt: fetchedAt))
        let stored = try #require(defaults.data(forKey: "lastUsage"))
        #expect(!String(decoding: stored, as: UTF8.self).contains("secret-token"))
    }
}

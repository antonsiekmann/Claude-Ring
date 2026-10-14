import AppKit
import SwiftUI
import Testing
@testable import ClaudeRing

/// Renders SwiftUI screens offscreen to PNG files for a visual check. Runs
/// only when `SNAPSHOT_DIR` is set (`TEST_RUNNER_SNAPSHOT_DIR=… xcodebuild test`).
@MainActor
struct ViewSnapshotTests {
    nonisolated static let directory = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"]

    @Test(.enabled(if: directory != nil))
    func `Render settings tabs`() throws {
        let defaults = UserDefaults(suiteName: "snapshots-\(UUID())")!
        let settings = AppSettings(defaults: defaults)
        let monitor = UsageMonitor(settings: settings)
        let sessions = ClaudeSessionStore()
        let notifier = UsageNotifier(settings: settings, defaults: defaults)
        let tabs: [(String, AnyView)] = [
            ("settings-general", AnyView(GeneralSettingsView(
                settings: settings,
                launchAtLogin: LaunchAtLogin(),
                uninstaller: AppUninstaller(
                    footprint: AppFootprint(home: FileManager.default.temporaryDirectory, bundleIdentifier: "test", executableName: "test"),
                    hookInstaller: HookInstaller(paths: .init(home: FileManager.default.temporaryDirectory.appending(path: "home-\(UUID())"))),
                    launchAtLogin: LaunchAtLogin(),
                    notifier: notifier
                ),
                updater: AppUpdater(settings: settings, defaults: defaults)
            ))),
            ("settings-menubar", AnyView(MenuBarSettingsView(settings: settings, monitor: monitor, sessions: sessions))),
            ("settings-popover", AnyView(PopoverSettingsView(settings: settings))),
            ("settings-notifications", AnyView(NotificationSettingsView(settings: settings, notifier: notifier))),
            ("settings-claudecode", AnyView(ClaudeCodeSettingsView(
                monitor: monitor,
                installer: HookInstaller(paths: .init(home: FileManager.default.temporaryDirectory.appending(path: "home-\(UUID())"))),
                sessions: sessions
            ))),
        ]
        for (name, view) in tabs {
            try Self.write(view.frame(width: 520), name: name)
        }
    }

    @Test(.enabled(if: directory != nil))
    func `Render popover states`() throws {
        let defaults = UserDefaults(suiteName: "snapshots-\(UUID())")!
        let settings = AppSettings(defaults: defaults)
        let response = try UsageAPIClient.makeDecoder().decode(UsageResponse.self, from: Data(#"""
        { "limits": [
            { "kind": "session", "percent": 13, "resets_at": "\#(Date.now.addingTimeInterval(8040).formatted(.iso8601))" },
            { "kind": "weekly_all", "percent": 64, "resets_at": "\#(Date.now.addingTimeInterval(300_000).formatted(.iso8601))" },
            { "kind": "weekly_scoped", "percent": 91, "resets_at": "\#(Date.now.addingTimeInterval(300_000).formatted(.iso8601))",
              "scope": { "model": { "id": "fable", "display_name": "Fable" } } } ],
          "seven_day_breakdown": { "rows": [
            { "key": "claude_code", "display_name": "Claude Code", "percent": 52 },
            { "key": "chat", "display_name": "Chats", "percent": 12 } ] } }
        """#.utf8))
        let snapshot = UsageSnapshot(response: response, credentials: .init(
            accessToken: "t", expiresAt: nil, subscriptionType: "max", rateLimitTier: "default_claude_max_5x"
        ))

        let sessionsDirectory = FileManager.default.temporaryDirectory.appending(path: "popover-\(UUID())")
        try FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
        for (pid, event, project, kind) in [
            (11, "UserPromptSubmit", "claude-ring", "null"), (12, "PermissionRequest", "Ticketverkauf", "null"),
            (13, "Stop", "claude-ring", #""bg""#),
        ] {
            let json = #"{"pid":\#(pid),"event":"\#(event)","session":"s","cwd":"/Users/me/\#(project)","kind":\#(kind)}"#
            let url = sessionsDirectory.appending(path: "\(pid)-s.json")
            try Data(json.utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-190)], ofItemAtPath: url.path)
        }
        let sessions = ClaudeSessionStore(directory: sessionsDirectory, processProbe: AlwaysAlive())
        sessions.reloadNow()

        let updater = AppUpdater(settings: settings, defaults: defaults)
        let monitor = UsageMonitor(settings: settings)
        monitor.showPreview(snapshot: snapshot)
        try Self.write(UsagePopoverView(monitor: monitor, settings: settings, sessions: sessions, updater: updater, openSettings: {}), name: "popover-full")

        let loading = UsageMonitor(settings: settings)
        try Self.write(UsagePopoverView(monitor: loading, settings: settings, sessions: ClaudeSessionStore(directory: sessionsDirectory.appending(path: "none")), updater: updater, openSettings: {}), name: "popover-loading")

        let failing = UsageMonitor(settings: settings)
        failing.showPreview(snapshot: snapshot, errorMessage: UsageAPIError.unauthorized.localizedDescription)
        settings.showsBreakdown = false
        settings.showsModelLimits = false
        try Self.write(UsagePopoverView(monitor: failing, settings: settings, sessions: sessions, updater: updater, openSettings: {}), name: "popover-error")

        let updating = AppUpdater(settings: settings, defaults: defaults, currentVersion: AppVersion("1.0.0"))
        updating.showPreview(release: Self.previewRelease)
        try Self.write(UsagePopoverView(monitor: monitor, settings: settings, sessions: sessions, updater: updating, openSettings: {}), name: "popover-update")
    }

    @Test(.enabled(if: directory != nil))
    func `Render update states in the general settings`() throws {
        let defaults = UserDefaults(suiteName: "snapshots-\(UUID())")!
        let settings = AppSettings(defaults: defaults)
        let notifier = UsageNotifier(settings: settings, defaults: defaults)
        let uninstaller = AppUninstaller(
            footprint: AppFootprint(home: FileManager.default.temporaryDirectory, bundleIdentifier: "test", executableName: "test"),
            hookInstaller: HookInstaller(paths: .init(home: FileManager.default.temporaryDirectory.appending(path: "home-\(UUID())"))),
            launchAtLogin: LaunchAtLogin(),
            notifier: notifier
        )

        let current = AppUpdater(settings: settings, defaults: defaults, currentVersion: AppVersion("1.0.0"))
        current.showPreview(release: nil, lastChecked: .now.addingTimeInterval(-7200))
        try Self.write(GeneralSettingsView(settings: settings, launchAtLogin: LaunchAtLogin(), uninstaller: uninstaller, updater: current)
            .frame(width: 520), name: "settings-general-current")

        let available = AppUpdater(settings: settings, defaults: defaults, currentVersion: AppVersion("1.0.0"))
        available.showPreview(release: Self.previewRelease)
        try Self.write(GeneralSettingsView(settings: settings, launchAtLogin: LaunchAtLogin(), uninstaller: uninstaller, updater: available)
            .frame(width: 520), name: "settings-general-update")
    }

    private static let previewRelease = AppRelease(
        version: AppVersion("1.1.0")!,
        pageURL: URL(string: "https://github.com/antonsiekmann/Claude-Ring/releases/tag/v1.1.0")!,
        download: .init(url: URL(string: "https://github.com/antonsiekmann/Claude-Ring/releases/download/v1.1.0/ClaudeRing.dmg")!,
                        sha256: String(repeating: "0", count: 64), size: 3_000_000)
    )

    private struct AlwaysAlive: ProcessProbing {
        func isAlive(pid: Int32, recordedAt date: Date) -> Bool { true }
    }

    /// Hosts the view in an offscreen window and writes light and dark
    /// renderings side by side.
    static func write(_ view: some View, name: String) throws {
        let directory = try #require(Self.directory)
        var images: [NSBitmapImageRep] = []
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            // Stands in for the popover's glass, which offscreen rendering lacks.
            let background = appearance == .darkAqua ? Color(white: 0.17) : Color(white: 0.97)
            let host = NSHostingController(rootView: view.background(background))
            host.sizingOptions = .preferredContentSize
            let window = NSWindow(contentViewController: host)
            window.appearance = NSAppearance(named: appearance)
            window.styleMask = [.titled]
            window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
            window.orderFrontRegardless()
            host.view.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))

            let bounds = host.view.bounds
            let rep = try #require(host.view.bitmapImageRepForCachingDisplay(in: bounds))
            host.view.cacheDisplay(in: bounds, to: rep)
            images.append(rep)
            window.orderOut(nil)
        }

        let width = images.map(\.pixelsWide).reduce(0, +)
        let height = images.map(\.pixelsHigh).max() ?? 0
        let sheet = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: sheet)
        var x = 0
        for image in images {
            image.draw(in: NSRect(x: x, y: height - image.pixelsHigh, width: image.pixelsWide, height: image.pixelsHigh))
            x += image.pixelsWide
        }
        NSGraphicsContext.restoreGraphicsState()
        try sheet.representation(using: .png, properties: [:])!
            .write(to: URL(filePath: directory).appending(path: "\(name).png"))
    }
}

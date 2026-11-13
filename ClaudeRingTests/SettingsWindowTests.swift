import AppKit
import SwiftUI
import Testing
@testable import ClaudeRing

/// The settings window follows the selected tab right away and to the exact
/// height, in a single animation. Before, it lagged behind by a switch or
/// kept the size of an earlier tab.
@MainActor
struct SettingsWindowTests {
    private let store = TestDefaults()
    private let folder = TemporaryFolder("settings-window")

    private func makeController() -> SettingsWindowController {
        let defaults = store.defaults
        let settings = AppSettings(defaults: defaults)
        let notifier = UsageNotifier(settings: settings, defaults: defaults)
        let hookInstaller = HookInstaller(paths: .init(home: folder.url))
        let launchAtLogin = LaunchAtLogin()
        return SettingsWindowController(
            settings: settings,
            monitor: UsageMonitor(settings: settings),
            launchAtLogin: launchAtLogin,
            notifier: notifier,
            sessions: ClaudeSessionStore(directory: folder.url.appending(path: "Sessions")),
            hookInstaller: hookInstaller,
            uninstaller: AppUninstaller(
                footprint: AppFootprint(home: folder.url, bundleIdentifier: "test", executableName: "test"),
                hookInstaller: hookInstaller, launchAtLogin: launchAtLogin, notifier: notifier
            ),
            updater: AppUpdater(settings: settings, defaults: defaults)
        )
    }

    @Test func `Fits the window to every tab right after switching`() throws {
        let controller = makeController()
        let window = try #require(controller.window)
        let tabs = try #require(window.contentViewController as? NSTabViewController)
        window.alphaValue = 0
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        spin(0.3)

        for index in [1, 2, 3, 4, 0, 4, 1, 2, 3, 0] {
            tabs.selectedTabViewItemIndex = index
            spin(0.35) // the animation takes 0.2 s
            let expected = try #require(tabs.tabViewItems[index].viewController).preferredContentSize.height
            let actual = window.contentRect(forFrameRect: window.frame).height
            #expect(abs(actual - expected) < 1, "Tab \(index): window \(actual), tab \(expected)")
        }
    }

    @Test func `Ends at the last tab when clicking through quickly`() throws {
        let controller = makeController()
        let window = try #require(controller.window)
        let tabs = try #require(window.contentViewController as? NSTabViewController)
        window.alphaValue = 0
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        spin(0.3)

        for index in [1, 3, 0, 2, 4, 1, 2] {
            tabs.selectedTabViewItemIndex = index
            spin(0.04) // faster than the animation
        }
        spin(0.4)

        let expected = try #require(tabs.tabViewItems[2].viewController).preferredContentSize.height
        #expect(abs(window.contentRect(forFrameRect: window.frame).height - expected) < 1)
    }

    @Test func `Shows every tab in the toolbar and marks the selected one`() throws {
        let controller = makeController()
        let window = try #require(controller.window)
        let tabs = try #require(window.contentViewController as? NSTabViewController)

        tabs.selectedTabViewItemIndex = 3

        let toolbar = try #require(window.toolbar)
        #expect(toolbar.items.map(\.label) == ["Allgemein", "Menüleiste", "Popover", "Mitteilungen", "Claude Code"])
        #expect(toolbar.selectedItemIdentifier == toolbar.items[3].itemIdentifier)
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: .now.addingTimeInterval(seconds))
    }
}

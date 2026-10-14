import AppKit
import SwiftUI

/// The settings window: toolbar tabs like the standard macOS settings, each
/// tab a SwiftUI form. While it is open the app shows up in the Dock and the
/// app switcher, like any other window people work with.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    enum Tab: Int {
        case general, menuBar, popover, notifications, claudeCode
    }

    private let tabController = NSTabViewController()

    init(
        settings: AppSettings,
        monitor: UsageMonitor,
        launchAtLogin: LaunchAtLogin,
        notifier: UsageNotifier,
        sessions: ClaudeSessionStore,
        hookInstaller: HookInstaller,
        uninstaller: AppUninstaller,
        updater: AppUpdater
    ) {
        tabController.tabStyle = .toolbar
        tabController.transitionOptions = [.crossfade, .allowUserInteraction]

        let window = NSWindow(contentViewController: tabController)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        // Nothing to restore; this also keeps macOS from saving window state.
        window.isRestorable = false
        super.init(window: window)
        window.delegate = self

        addTab(GeneralSettingsView(settings: settings, launchAtLogin: launchAtLogin, uninstaller: uninstaller, updater: updater),
               title: String(localized: "Allgemein"), symbol: "gearshape")
        addTab(MenuBarSettingsView(settings: settings, monitor: monitor, sessions: sessions),
               title: String(localized: "Menüleiste"), symbol: "menubar.rectangle")
        addTab(PopoverSettingsView(settings: settings),
               title: String(localized: "Popover"), symbol: "rectangle.stack")
        addTab(NotificationSettingsView(settings: settings, notifier: notifier),
               title: String(localized: "Mitteilungen"), symbol: "bell.badge")
        addTab(ClaudeCodeSettingsView(monitor: monitor, installer: hookInstaller, sessions: sessions),
               title: String(localized: "Claude Code"), symbol: "terminal")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show(tab: Tab? = nil) {
        if let tab {
            tabController.selectedTabViewItemIndex = tab.rawValue
        }
        NSApp.setActivationPolicy(.regular)
        if window?.isVisible == false {
            window?.center()
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    private func addTab(_ view: some View, title: String, symbol: String) {
        let host = NSHostingController(rootView: view.frame(width: 520))
        host.sizingOptions = .preferredContentSize
        host.title = title
        let item = NSTabViewItem(viewController: host)
        item.label = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        tabController.addTabViewItem(item)
    }
}

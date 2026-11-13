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

    private let tabController: SettingsTabViewController

    init(
        settings: AppSettings,
        monitor: UsageMonitor,
        launchAtLogin: LaunchAtLogin,
        notifier: UsageNotifier,
        sessions: ClaudeSessionStore,
        hookInstaller: HookInstaller,
        uninstaller: AppUninstaller,
        updater: AppUpdater,
        openWelcome: @escaping () -> Void = {}
    ) {
        // The tabs exist before the window: a window created around an empty
        // tab view controller keeps layout constraints of tabs shown earlier,
        // which pulled the window back to their height after each switch.
        let tabController = SettingsTabViewController()
        func addTab(_ view: some View, title: String, symbol: String) {
            let host = NSHostingController(rootView: view.frame(width: 520))
            host.sizingOptions = .preferredContentSize
            host.title = title
            let item = NSTabViewItem(viewController: host)
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            tabController.addTabViewItem(item)
        }
        addTab(GeneralSettingsView(settings: settings, launchAtLogin: launchAtLogin, uninstaller: uninstaller, updater: updater,
                                   openWelcome: openWelcome),
               title: String(localized: "Allgemein"), symbol: "gearshape")
        addTab(MenuBarSettingsView(settings: settings, monitor: monitor, sessions: sessions, installer: hookInstaller),
               title: String(localized: "Menüleiste"), symbol: "menubar.rectangle")
        addTab(PopoverSettingsView(settings: settings),
               title: String(localized: "Popover"), symbol: "rectangle.stack")
        addTab(NotificationSettingsView(settings: settings, notifier: notifier),
               title: String(localized: "Mitteilungen"), symbol: "bell.badge")
        addTab(ClaudeCodeSettingsView(monitor: monitor, installer: hookInstaller, sessions: sessions),
               title: String(localized: "Claude Code"), symbol: "terminal")

        let window = NSWindow(contentViewController: tabController)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.toolbarStyle = .preference
        window.toolbar = tabController.makeToolbar()
        window.isReleasedWhenClosed = false
        // Nothing to restore; this also keeps macOS from saving window state.
        window.isRestorable = false
        self.tabController = tabController
        super.init(window: window)
        window.delegate = self
        tabController.fitWindow(animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show(tab: Tab? = nil) {
        if let tab {
            tabController.selectedTabViewItemIndex = tab.rawValue
        }
        AppActivation.windowWillShow()
        if window?.isVisible == false {
            window?.center()
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) {
        AppActivation.windowWillClose(window)
    }
}

/// Switches the tabs and sizes the window itself.
///
/// `NSTabViewController` resized the window on its own and late: SwiftUI
/// reports a tab's height only once the tab is in the window, so the window
/// followed with a delay, sometimes only on the next switch. Its crossfade
/// also kept layout constraints of the previous tab alive, which pulled the
/// window back to the old height after every resize. Here the tab view
/// controller only swaps the content, without its own transition and toolbar;
/// the window animates once per switch to the height the new tab reports in
/// place, and the new tab fades in during that animation.
@MainActor
final class SettingsTabViewController: NSTabViewController {
    private static let animationDuration: TimeInterval = 0.2

    override init(nibName: NSNib.Name?, bundle: Bundle?) {
        super.init(nibName: nibName, bundle: bundle)
        tabStyle = .unspecified
        transitionOptions = [.allowUserInteraction]
    }

    convenience init() {
        self.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func makeToolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: "SettingsTabs")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        toolbar.selectedItemIdentifier = itemIdentifier(for: selectedTabViewItemIndex)
        return toolbar
    }

    private var animates: Bool {
        view.window?.isVisible == true && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        view.window?.toolbar?.selectedItemIdentifier = itemIdentifier(for: selectedTabViewItemIndex)
        if animates, let content = tabViewItem?.viewController?.view {
            content.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.animationDuration
                content.animator().alphaValue = 1
            }
        }
        fitWindow(animated: animates)
    }

    /// A tab changed its height, for example when an update row appears.
    override func preferredContentSizeDidChange(for viewController: NSViewController) {
        guard tabViewItems.indices.contains(selectedTabViewItemIndex),
              viewController === tabViewItems[selectedTabViewItemIndex].viewController
        else { return }
        fitWindow(animated: animates)
    }

    /// Resizes the window to the selected tab, keeping its top edge in place.
    func fitWindow(animated: Bool) {
        guard let window = view.window, tabViewItems.indices.contains(selectedTabViewItemIndex),
              let content = tabViewItems[selectedTabViewItemIndex].viewController
        else { return }
        content.view.layoutSubtreeIfNeeded()
        let size = content.preferredContentSize
        guard size.width > 0, size.height > 0 else { return }

        let current = window.contentRect(forFrameRect: window.frame)
        guard abs(current.height - size.height) > 0.5 || abs(current.width - size.width) > 0.5 else { return }
        let target = window.frameRect(forContentRect: NSRect(
            x: current.minX, y: current.maxY - size.height, width: size.width, height: size.height
        ))
        guard animated else {
            window.setFrame(target, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.animationDuration
            window.animator().setFrame(target, display: true)
        }
    }

    // MARK: - Toolbar

    private func itemIdentifier(for index: Int) -> NSToolbarItem.Identifier {
        NSToolbarItem.Identifier("tab-\(index)")
    }

    private var itemIdentifiers: [NSToolbarItem.Identifier] {
        tabViewItems.indices.map(itemIdentifier(for:))
    }

    override func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { itemIdentifiers }
    override func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { itemIdentifiers }
    override func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { itemIdentifiers }

    override func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard let index = itemIdentifiers.firstIndex(of: itemIdentifier) else { return nil }
        let tab = tabViewItems[index]
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = tab.label
        item.image = tab.image
        item.target = self
        item.action = #selector(selectTab(_:))
        return item
    }

    @objc private func selectTab(_ sender: NSToolbarItem) {
        guard let index = itemIdentifiers.firstIndex(of: sender.itemIdentifier) else { return }
        selectedTabViewItemIndex = index
    }
}

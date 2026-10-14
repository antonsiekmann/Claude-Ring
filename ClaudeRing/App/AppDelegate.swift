import AppKit
import Observation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = AppSettings()
    private let sessions = ClaudeSessionStore()
    private lazy var monitor = UsageMonitor(settings: settings)
    private lazy var notifier = UsageNotifier(settings: settings)
    private lazy var launchAtLogin = LaunchAtLogin()
    private lazy var hookInstaller = HookInstaller()
    private lazy var updater = AppUpdater(settings: settings)
    private lazy var uninstaller = AppUninstaller(
        footprint: .current, hookInstaller: hookInstaller, launchAtLogin: launchAtLogin, notifier: notifier
    )
    private var statusItemController: StatusItemController?
    private var settingsWindowController: SettingsWindowController?
    private var notificationTask: Task<Void, Never>?
    private var hookStatusTask: Task<Void, Never>?
    private var updateNotificationTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !AppEnvironment.isRunningTests else { return }

        NSApp.mainMenu = MainMenu.make(settingsAction: #selector(showSettings), target: self)
        hookInstaller.repairScriptIfNeeded()
        notifier.activate()
        statusItemController = StatusItemController(
            monitor: monitor,
            settings: settings,
            sessions: sessions,
            updater: updater,
            openSettings: { [weak self] in self?.showSettings() },
            checkForUpdates: { [weak self] in self?.checkForUpdates() }
        )
        monitor.start()
        updater.start()
        observeSnapshotsForNotifications()
        observeUpdatesForNotifications()
        notifier.openUpdate = { [weak self] in self?.openSettings(tab: .general) }

        let monitor = monitor
        sessions.onRateLimited = { monitor.refreshUnlessBackingOff() }
        observeHookStatus()
        uninstaller.stopApp = { [weak self] in self?.stopEverything() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        uninstaller.finishTermination()
    }

    /// Before the complete removal: nothing may write files or settings anymore.
    private func stopEverything() {
        notificationTask?.cancel()
        hookStatusTask?.cancel()
        updateNotificationTask?.cancel()
        monitor.stop()
        updater.stop()
        sessions.stop()
        statusItemController?.remove()
        statusItemController = nil
    }

    @objc func showSettings() {
        openSettings(tab: nil)
    }

    private func openSettings(tab: SettingsWindowController.Tab?) {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(
                settings: settings,
                monitor: monitor,
                launchAtLogin: launchAtLogin,
                notifier: notifier,
                sessions: sessions,
                hookInstaller: hookInstaller,
                uninstaller: uninstaller,
                updater: updater
            )
        }
        settingsWindowController?.show(tab: tab)
    }

    /// The result shows in the general settings, next to the install button.
    private func checkForUpdates() {
        if updater.availableRelease == nil {
            updater.checkNow()
        }
        openSettings(tab: .general)
    }

    /// The sessions folder only exists while the hooks are set up, so watch it
    /// whenever that changes.
    private func observeHookStatus() {
        let installer = hookInstaller
        let sessions = sessions
        hookStatusTask = Task {
            for await status in Observations({ installer.status }) {
                if status == .notInstalled {
                    sessions.stop()
                } else {
                    sessions.start()
                }
            }
        }
    }

    private func observeUpdatesForNotifications() {
        let updater = updater
        let notifier = notifier
        updateNotificationTask = Task {
            for await version in Observations({ updater.availableRelease?.version }) {
                if let version {
                    notifier.announceUpdate(version)
                }
            }
        }
    }

    private func observeSnapshotsForNotifications() {
        let monitor = monitor
        let notifier = notifier
        notificationTask = Task {
            for await snapshot in Observations({ monitor.snapshot }) {
                if let snapshot {
                    notifier.evaluate(snapshot)
                }
            }
        }
    }
}

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
    private lazy var uninstaller = AppUninstaller(
        footprint: .current, hookInstaller: hookInstaller, launchAtLogin: launchAtLogin, notifier: notifier
    )
    private var statusItemController: StatusItemController?
    private var settingsWindowController: SettingsWindowController?
    private var notificationTask: Task<Void, Never>?
    private var hookStatusTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !AppEnvironment.isRunningTests else { return }

        NSApp.mainMenu = MainMenu.make(settingsAction: #selector(showSettings), target: self)
        hookInstaller.repairScriptIfNeeded()
        notifier.activate()
        statusItemController = StatusItemController(
            monitor: monitor,
            settings: settings,
            sessions: sessions,
            openSettings: { [weak self] in self?.showSettings() }
        )
        monitor.start()
        observeSnapshotsForNotifications()

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
        monitor.stop()
        sessions.stop()
        statusItemController?.remove()
        statusItemController = nil
    }

    @objc func showSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(
                settings: settings,
                monitor: monitor,
                launchAtLogin: launchAtLogin,
                notifier: notifier,
                sessions: sessions,
                hookInstaller: hookInstaller,
                uninstaller: uninstaller
            )
        }
        settingsWindowController?.show()
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

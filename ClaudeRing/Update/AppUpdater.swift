import AppKit
import Observation
import OSLog

/// Looks for new versions on GitHub and installs them on request.
///
/// While automatic checks are on, it asks shortly after launch and then once a
/// day. Nothing is downloaded until the user clicks "Installieren"; then
/// `UpdateInstaller` replaces the app and the app starts again.
@MainActor
@Observable
final class AppUpdater {
    /// The newest release, if it is newer than the running app.
    private(set) var availableRelease: AppRelease?
    private(set) var isChecking = false
    private(set) var isInstalling = false
    /// The last successful check.
    private(set) var lastChecked: Date?
    /// The last failure of a manual check or an installation. Automatic
    /// checks fail silently and try again later.
    private(set) var lastError: String?
    /// The release the user put off with "Später"; the popover hides it.
    private(set) var dismissedVersion: AppVersion? {
        didSet { defaults.set(dismissedVersion?.description, forKey: Self.dismissedVersionKey) }
    }

    let currentVersion: AppVersion?
    /// Whether the app can replace itself; otherwise the release page opens.
    let canInstall: Bool

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let client: ReleaseClient
    @ObservationIgnored private let installer: UpdateInstaller
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let relaunch: () -> Void
    @ObservationIgnored private var settingsTask: Task<Void, Never>?
    @ObservationIgnored private var scheduleTask: Task<Void, Never>?
    @ObservationIgnored private let logger = Logger(subsystem: "eu.siekmann.ClaudeRing", category: "update")
    private static let dismissedVersionKey = "dismissedUpdateVersion"

    init(
        settings: AppSettings,
        client: ReleaseClient = ReleaseClient(),
        installer: UpdateInstaller = UpdateInstaller(),
        defaults: UserDefaults = .standard,
        currentVersion: AppVersion? = .current,
        relaunch: (() -> Void)? = nil
    ) {
        self.settings = settings
        self.client = client
        self.installer = installer
        self.defaults = defaults
        self.currentVersion = currentVersion
        self.relaunch = relaunch ?? {
            UpdateInstaller.launchRelaunch(of: installer.appURL)
            NSApp.terminate(nil)
        }
        canInstall = installer.canReplaceApp
        dismissedVersion = defaults.string(forKey: Self.dismissedVersionKey).flatMap(AppVersion.init)
    }

    /// The popover shows a release until the user puts it off; while it
    /// installs or after a failure it stays visible.
    var showsBanner: Bool {
        guard let availableRelease else { return false }
        return availableRelease.version != dismissedVersion || isInstalling || lastError != nil
    }

    /// Starts the automatic checks, if they are switched on. Safe to call
    /// more than once.
    func start() {
        guard settingsTask == nil, !AppEnvironment.isRunningTests else { return }
        let settings = settings
        settingsTask = Task { [weak self] in
            for await enabled in Observations({ settings.checksForUpdates }) {
                self?.scheduleChecks(enabled)
            }
        }
    }

    func stop() {
        settingsTask?.cancel()
        settingsTask = nil
        scheduleTask?.cancel()
        scheduleTask = nil
    }

    #if DEBUG
    /// Shows a fixed release without network access, for snapshot tests.
    func showPreview(release: AppRelease?, lastChecked: Date? = nil) {
        availableRelease = release
        self.lastChecked = lastChecked
    }
    #endif

    func checkNow() {
        Task { await check(isManual: true) }
    }

    /// Installs the available release and restarts, or opens its page when
    /// the app cannot replace itself.
    func install() {
        guard let release = availableRelease, !isInstalling else { return }
        guard canInstall, let download = release.download else {
            NSWorkspace.shared.open(release.pageURL)
            return
        }

        isInstalling = true
        lastError = nil
        Task {
            do {
                try await installer.install(download, version: release.version)
                logger.info("Installed version \(release.version.description, privacy: .public), restarting")
                relaunch()
            } catch {
                isInstalling = false
                lastError = String(localized: "Das Update konnte nicht installiert werden. \(error.localizedDescription)")
                logger.error("Update failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func dismiss() {
        dismissedVersion = availableRelease?.version
    }

    private func scheduleChecks(_ enabled: Bool) {
        scheduleTask?.cancel()
        scheduleTask = nil
        guard enabled else { return }
        scheduleTask = Task { [weak self] in
            var delay = UpdateSchedule.firstCheckDelay
            while true {
                do {
                    try await Task.sleep(for: delay, tolerance: RefreshSchedule.tolerance(for: delay))
                } catch {
                    return // cancelled
                }
                guard let succeeded = await self?.check(isManual: false) else { return }
                delay = succeeded ? UpdateSchedule.interval : UpdateSchedule.retryDelay
            }
        }
    }

    /// - Returns: Whether GitHub answered.
    @discardableResult
    private func check(isManual: Bool) async -> Bool {
        guard !isChecking, !isInstalling else { return true }
        isChecking = true
        defer { isChecking = false }

        do {
            let release = try await client.latestRelease()
            lastChecked = .now
            lastError = nil
            if let currentVersion, release.version > currentVersion {
                availableRelease = release
                logger.info("Version \(release.version.description, privacy: .public) is available")
            } else {
                availableRelease = nil
            }
            return true
        } catch {
            if isManual {
                lastError = error.localizedDescription
            }
            logger.error("Update check failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}

enum UpdateSchedule {
    /// Leaves the first seconds after launch to the usage data.
    static let firstCheckDelay: Duration = .seconds(10)
    static let interval: Duration = .seconds(24 * 60 * 60)
    /// After a failed automatic check, for example while offline.
    static let retryDelay: Duration = .seconds(60 * 60)
}

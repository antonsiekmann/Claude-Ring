import Foundation
import Observation

/// Decides whether the welcome window opens at launch.
@MainActor
enum WelcomePolicy {
    /// Raise to show a reworked welcome window to everyone once more.
    static let currentVersion = 1

    /// People who used the app before the welcome window existed don't get it
    /// after an update: for them the version is recorded without showing
    /// anything. Installed hooks are no sign of that, since settings shared
    /// through dotfiles bring them to a new Mac. "Vollständig entfernen"
    /// clears the record, so a reinstall starts with the window again.
    static func shouldShow(settings: AppSettings, loginItemEnabled: Bool, hasUsageData: Bool) -> Bool {
        if let completed = settings.completedWelcomeVersion {
            return completed < currentVersion
        }
        if loginItemEnabled || hasUsageData {
            settings.completedWelcomeVersion = currentVersion
            return false
        }
        return true
    }
}

/// State and actions of the welcome window.
@MainActor
@Observable
final class WelcomeModel {
    enum Login: Equatable {
        case checking
        case signedIn
        case signedOut
        case claudeCodeMissing
    }

    private(set) var login: Login = .checking
    var setsUpStatusDot = true
    var opensAtLogin = true
    private(set) var isMoving = false
    private(set) var moveError: String?
    /// Set when "Fertig" found the menu bar icon hidden, for example behind the notch.
    private(set) var iconIsHidden = false

    let installer: HookInstaller
    let launchAtLogin: LaunchAtLogin
    /// Runs from the disk image or Downloads instead of „Programme“.
    let needsMove: Bool

    @ObservationIgnored private let loginChecker: any LoginChecking
    @ObservationIgnored private let claudeCodeInstalled: () -> Bool
    @ObservationIgnored private let onSignedIn: () -> Void
    @ObservationIgnored private let move: @Sendable () throws -> URL
    @ObservationIgnored private let relaunch: (URL) -> Void
    @ObservationIgnored private var watchTask: Task<Void, Never>?

    init(
        installer: HookInstaller,
        launchAtLogin: LaunchAtLogin,
        loginChecker: any LoginChecking = SecurityToolLoginChecker(),
        claudeCodeInstalled: @escaping () -> Bool = { ClaudeCodeInstallation.isInstalled() },
        needsMove: Bool = !AppEnvironment.isInstalled() && !AppEnvironment.isDevelopmentBuild(),
        onSignedIn: @escaping () -> Void = {},
        move: @escaping @Sendable () throws -> URL = { try AppMover.install() },
        relaunch: @escaping (URL) -> Void = { AppMover.relaunch(into: $0) }
    ) {
        self.installer = installer
        self.launchAtLogin = launchAtLogin
        self.loginChecker = loginChecker
        self.claudeCodeInstalled = claudeCodeInstalled
        self.needsMove = needsMove
        self.onSignedIn = onSignedIn
        self.move = move
        self.relaunch = relaunch
    }

    var statusDotDone: Bool { installer.status == .installed }
    var loginItemDone: Bool { launchAtLogin.isEnabled }

    /// Something is checked that is not set up yet, so the main button sets up.
    var hasPendingSetup: Bool {
        (setsUpStatusDot && !statusDotDone) || (opensAtLogin && canEnableLoginItem)
    }

    private var canEnableLoginItem: Bool {
        launchAtLogin.isAvailable && !launchAtLogin.isEnabled && !launchAtLogin.requiresApproval
    }

    // MARK: Login

    func checkLogin() async {
        let previous = login
        if await loginChecker.hasLogin() {
            login = .signedIn
        } else {
            login = claudeCodeInstalled() ? .signedOut : .claudeCodeMissing
        }
        // Show the usage right away instead of at the next regular refresh.
        if login == .signedIn, previous == .signedOut || previous == .claudeCodeMissing {
            onSignedIn()
        }
    }

    /// While the window is open, notices a login made in the Terminal within
    /// a few seconds. Only asks whether the keychain item exists, which never
    /// shows a password dialog.
    func startWatchingLogin(every interval: Duration = .seconds(3)) {
        guard watchTask == nil else { return }
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.checkLogin()
                if self.login == .signedIn { return }
                try? await Task.sleep(for: interval)
            }
        }
    }

    func stopWatchingLogin() {
        watchTask?.cancel()
        watchTask = nil
    }

    // MARK: Actions

    /// Everything checked, with one click. What fails shows its own error.
    func setUp() {
        if setsUpStatusDot, !statusDotDone {
            installer.install()
        }
        if opensAtLogin, canEnableLoginItem {
            launchAtLogin.setEnabled(true)
        }
    }

    func moveToApplications() async {
        isMoving = true
        moveError = nil
        let move = move
        do {
            let installed = try await Task.detached(priority: .userInitiated) { try move() }.value
            relaunch(installed)
        } catch {
            isMoving = false
            moveError = String(localized: "Claude Ring konnte nicht verschoben werden (\(error.localizedDescription)). Ziehe die App im Finder in „Programme“ und öffne sie dort.")
        }
    }

    func markIconHidden() {
        iconIsHidden = true
    }

    #if DEBUG
    /// Fixed states for previews and snapshot tests.
    func showPreview(login: Login, iconIsHidden: Bool = false) {
        self.login = login
        self.iconIsHidden = iconIsHidden
    }
    #endif
}

import AppKit
import Observation
@preconcurrency import UserNotifications

/// Sends a notification when a usage window crosses the warning or critical
/// threshold, optionally when a nearly used up session has been reset, when a
/// Claude Code session waits for an answer, and once per new version of the app.
@MainActor
@Observable
final class UsageNotifier: NSObject, UNUserNotificationCenterDelegate {
    private(set) var authorization: UNAuthorizationStatus = .notDetermined
    /// Called when the user clicks the update notification.
    @ObservationIgnored var openUpdate: () -> Void = {}
    /// Called when the user clicks the notification of a waiting session that
    /// runs in no app, such as a background session.
    @ObservationIgnored var showSessions: () -> Void = {}

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let authorizationStatus: @Sendable () async -> UNAuthorizationStatus
    @ObservationIgnored private var isRecheckingAuthorization = false
    @ObservationIgnored private var activationObserver: NSObjectProtocol?
    @ObservationIgnored private var center: UNUserNotificationCenter { .current() }
    @ObservationIgnored private let waitingDelay: Duration
    @ObservationIgnored private var waitingTracker = WaitingAlertTracker()
    @ObservationIgnored private var pendingWaitingAlerts: [String: Task<Void, Never>] = [:]
    private static let stateKey = "thresholdStates"
    private static let announcedVersionKey = "announcedUpdateVersion"
    nonisolated private static let updateNotificationID = "update"
    nonisolated private static let waitingPrefix = "waiting-"
    nonisolated private static let pidKey = "pid"

    /// - Parameter waitingDelay: How long a session waits before its
    ///   notification goes out; an answer given right away at the terminal
    ///   needs none. The footer in the settings names this time.
    init(
        settings: AppSettings,
        defaults: UserDefaults = .standard,
        waitingDelay: Duration = .seconds(10),
        authorizationStatus: @escaping @Sendable () async -> UNAuthorizationStatus = {
            await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        }
    ) {
        self.settings = settings
        self.defaults = defaults
        self.waitingDelay = waitingDelay
        self.authorizationStatus = authorizationStatus
        super.init()
    }

    /// Must run early, so notifications also show while the app is frontmost.
    func activate() {
        center.delegate = self
        Task { await refreshAuthorization() }
        // Permission given in System Settings counts as soon as people come back.
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.refreshAuthorization() }
            }
        }
    }

    func refreshAuthorization() async {
        authorization = await authorizationStatus()
    }

    private var isAuthorized: Bool {
        authorization == .authorized || authorization == .provisional
    }

    /// The stored answer may be outdated, because permission can be given in
    /// System Settings at any time; asks again and continues if it is there now.
    private func recheckAuthorization(then action: @escaping () -> Void) {
        guard !isRecheckingAuthorization else { return }
        isRecheckingAuthorization = true
        Task {
            await refreshAuthorization()
            isRecheckingAuthorization = false
            if isAuthorized { action() }
        }
    }

    /// Asks for permission the first time; afterwards macOS remembers the answer.
    @discardableResult
    func requestAuthorization() async -> Bool {
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        await refreshAuthorization()
        return granted
    }

    func openSystemSettings() {
        let id = Bundle.main.bundleIdentifier ?? ""
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }

    func removeAllNotifications() {
        center.removeAllDeliveredNotifications()
        center.removeAllPendingNotificationRequests()
    }

    func sendTest() {
        post(id: "test", title: String(localized: "Mitteilungen sind aktiv"),
             body: String(localized: "So sieht eine Warnung von Claude Ring aus."))
    }

    /// Call with every new snapshot.
    func evaluate(_ snapshot: UsageSnapshot) {
        guard settings.notificationsEnabled else { return }
        guard isAuthorized else {
            recheckAuthorization { [weak self] in self?.evaluate(snapshot) }
            return
        }

        var states = loadStates()
        let thresholds = settings.thresholds
        var windows: [(UsageWindowInfo, isSession: Bool)] = []
        if let session = snapshot.session { windows.append((session, true)) }
        if settings.notifiesForWeekly, let weekly = snapshot.weekly { windows.append((weekly, false)) }

        for (window, isSession) in windows {
            let result = ThresholdEvaluator.evaluate(
                window: window,
                state: states[window.id],
                thresholds: thresholds,
                notifiesOnReset: isSession && settings.notifiesOnSessionReset
            )
            states[window.id] = result.state
            for event in result.events {
                send(event, for: window, isSession: isSession)
            }
        }
        saveStates(states)
    }

    /// Call with every change of the Claude Code sessions. A session that
    /// still waits after `waitingDelay` gets a notification; it disappears
    /// from the Notification Center as soon as the wait is over.
    func sessionsChanged(_ sessions: [ClaudeSession]) {
        let changes = waitingTracker.update(sessions)
        for id in changes.ended {
            pendingWaitingAlerts.removeValue(forKey: id)?.cancel()
            center.removeDeliveredNotifications(withIdentifiers: [Self.waitingPrefix + id])
        }
        guard settings.notificationsEnabled, settings.notifiesWhenWaiting else { return }
        for session in changes.started {
            let delay = waitingDelay - .seconds(Date.now.timeIntervalSince(session.since))
            pendingWaitingAlerts[session.id] = Task { [weak self] in
                if delay > .zero { try? await Task.sleep(for: delay) }
                guard !Task.isCancelled else { return }
                self?.pendingWaitingAlerts[session.id] = nil
                self?.announceWaiting(session)
            }
        }
    }

    private func announceWaiting(_ session: ClaudeSession) {
        guard settings.notificationsEnabled, settings.notifiesWhenWaiting,
              waitingTracker.isWaiting(session)
        else { return }
        guard isAuthorized else {
            recheckAuthorization { [weak self] in self?.announceWaiting(session) }
            return
        }
        post(id: Self.waitingPrefix + session.id,
             title: String(localized: "Claude Code wartet auf dich"),
             body: String(localized: "„\(session.projectName)“ braucht deine Antwort oder Freigabe."),
             userInfo: [Self.pidKey: Int(session.pid)],
             threadIdentifier: "waiting")
    }

    /// Once that version or a newer one runs, its announcement goes from the
    /// Notification Center.
    func removeAnnouncement(ifInstalled currentVersion: AppVersion?) {
        guard let currentVersion,
              let announced = defaults.string(forKey: Self.announcedVersionKey).flatMap(AppVersion.init),
              announced <= currentVersion
        else { return }
        center.removeDeliveredNotifications(withIdentifiers: [Self.updateNotificationID])
    }

    /// Announces a new version once. A version that arrives while
    /// notifications are off is announced when they get switched on.
    func announceUpdate(_ version: AppVersion) {
        guard settings.notificationsEnabled, settings.notifiesAboutUpdates else { return }
        guard isAuthorized else {
            recheckAuthorization { [weak self] in self?.announceUpdate(version) }
            return
        }
        if let announced = defaults.string(forKey: Self.announcedVersionKey).flatMap(AppVersion.init), announced >= version {
            return
        }
        defaults.set(version.description, forKey: Self.announcedVersionKey)
        post(id: Self.updateNotificationID,
             title: String(localized: "Claude Ring \(version.description) ist verfügbar"),
             body: String(localized: "Klicke hier, um das Update anzusehen und zu installieren."))
    }

    private func send(_ event: ThresholdEvaluator.Event, for window: UsageWindowInfo, isSession: Bool) {
        let remaining = Int(window.remainingPercent.rounded())
        let resetText = window.resetsAt.map {
            String(localized: "Reset \($0.formatted(.relative(presentation: .named)))")
        } ?? ""
        switch event {
        case .warning(let used):
            post(id: "\(window.id)-warning",
                 title: isSession
                    ? String(localized: "Claude-Sitzung zu \(used) % genutzt")
                    : String(localized: "Claude-Wochenlimit zu \(used) % genutzt"),
                 body: String(localized: "Noch \(remaining) % übrig. \(resetText)"))
        case .critical(let used):
            post(id: "\(window.id)-critical",
                 title: isSession
                    ? String(localized: "Claude-Sitzung fast aufgebraucht")
                    : String(localized: "Claude-Wochenlimit fast aufgebraucht"),
                 body: String(localized: "\(used) % genutzt. \(resetText)"))
        case .reset:
            post(id: "\(window.id)-reset",
                 title: String(localized: "Claude-Sitzung zurückgesetzt"),
                 body: String(localized: "Das 5-Stunden-Limit steht wieder voll zur Verfügung."))
        }
    }

    private func post(
        id: String, title: String, body: String,
        userInfo: [String: Any] = [:], threadIdentifier: String = ""
    ) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = userInfo
        content.threadIdentifier = threadIdentifier
        content.sound = .default
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    private func loadStates() -> [String: ThresholdEvaluator.State] {
        guard let data = defaults.data(forKey: Self.stateKey) else { return [:] }
        return (try? JSONDecoder().decode([String: ThresholdEvaluator.State].self, from: data)) ?? [:]
    }

    private func saveStates(_ states: [String: ThresholdEvaluator.State]) {
        defaults.set(try? JSONEncoder().encode(states), forKey: Self.stateKey)
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        let request = response.notification.request
        if request.identifier == Self.updateNotificationID {
            await showUpdate()
        } else if request.identifier.hasPrefix(Self.waitingPrefix) {
            let pid = request.content.userInfo[Self.pidKey] as? Int
            await showWaitingSession(pid: pid.map(pid_t.init))
        }
    }

    private func showUpdate() {
        openUpdate()
    }

    /// Brings the terminal or editor of the session to the front.
    private func showWaitingSession(pid: pid_t?) {
        guard let pid, let app = HostApp.of(pid: pid) else {
            showSessions()
            return
        }
        NSApp.yieldActivation(to: app)
        app.activate()
    }
}

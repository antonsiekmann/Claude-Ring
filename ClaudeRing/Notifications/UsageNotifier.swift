import AppKit
import Observation
@preconcurrency import UserNotifications

/// Sends a notification when a usage window crosses the warning or critical
/// threshold, and optionally when a nearly used up session has been reset.
@MainActor
@Observable
final class UsageNotifier: NSObject, UNUserNotificationCenterDelegate {
    private(set) var authorization: UNAuthorizationStatus = .notDetermined

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var center: UNUserNotificationCenter { .current() }
    private static let stateKey = "thresholdStates"

    init(settings: AppSettings, defaults: UserDefaults = .standard) {
        self.settings = settings
        self.defaults = defaults
        super.init()
    }

    /// Must run early, so notifications also show while the app is frontmost.
    func activate() {
        center.delegate = self
        Task { await refreshAuthorization() }
    }

    func refreshAuthorization() async {
        authorization = await center.notificationSettings().authorizationStatus
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
        guard settings.notificationsEnabled, authorization == .authorized || authorization == .provisional else { return }

        var states = loadStates()
        let thresholds = ThresholdEvaluator.Thresholds(warning: settings.warningThreshold, critical: settings.criticalThreshold)
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

    private func post(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
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
}

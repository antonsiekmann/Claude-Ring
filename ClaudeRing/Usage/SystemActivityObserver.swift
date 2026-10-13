import AppKit

/// Reports when nobody can look at the menu bar: the Mac sleeps, the displays
/// are off, the screen is locked or another user is active. Polling pauses
/// for as long as at least one of these reasons applies.
@MainActor
final class SystemActivityObserver {
    enum PauseReason: Hashable {
        case systemSleep
        case displaySleep
        case screenLocked
        case sessionInactive
    }

    private(set) var pauseReasons: Set<PauseReason> = []
    var isPaused: Bool { !pauseReasons.isEmpty }

    /// Called whenever `isPaused` flips.
    var onChange: ((_ isPaused: Bool) -> Void)?

    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []

    func start() {
        guard tokens.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.willSleepNotification) { $0.insert(.systemSleep) }
        observe(workspace, NSWorkspace.didWakeNotification) { $0.remove(.systemSleep) }
        observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.insert(.displaySleep) }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.remove(.displaySleep) }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { $0.insert(.sessionInactive) }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { $0.remove(.sessionInactive) }

        let distributed = DistributedNotificationCenter.default()
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { $0.insert(.screenLocked) }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { $0.remove(.screenLocked) }
    }

    func stop() {
        for (center, token) in tokens {
            center.removeObserver(token)
        }
        tokens.removeAll()
    }

    private func observe(
        _ center: NotificationCenter,
        _ name: Notification.Name,
        update: @escaping @Sendable (inout Set<PauseReason>) -> Void
    ) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.apply(update)
            }
        }
        tokens.append((center, token))
    }

    private func apply(_ update: (inout Set<PauseReason>) -> Void) {
        let wasPaused = isPaused
        update(&pauseReasons)
        if wasPaused != isPaused {
            onChange?(isPaused)
        }
    }
}

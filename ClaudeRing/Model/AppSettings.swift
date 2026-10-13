import Foundation
import Observation

/// The usage endpoint limits requests strictly, so there is no option below
/// one minute.
enum RefreshInterval: Int, CaseIterable, Identifiable, Sendable {
    case minute1 = 60
    case minutes2 = 120
    case minutes5 = 300
    case minutes10 = 600

    var id: Int { rawValue }
    var duration: Duration { .seconds(rawValue) }

    var label: LocalizedStringResource {
        switch self {
        case .minute1: "Jede Minute"
        case .minutes2: "Alle 2 Minuten"
        case .minutes5: "Alle 5 Minuten"
        case .minutes10: "Alle 10 Minuten"
        }
    }
}

enum MenuBarStyle: String, CaseIterable, Identifiable, Sendable {
    case ring
    case bars
    case numbers

    var id: String { rawValue }

    var label: LocalizedStringResource {
        switch self {
        case .ring: "Ring und Zahl"
        case .bars: "Zwei Balken"
        case .numbers: "Nur Zahlen"
        }
    }
}

/// Which limit the ring (or the first number) in the menu bar shows.
enum MenuBarLimit: String, CaseIterable, Identifiable, Sendable {
    case session
    case weekly

    var id: String { rawValue }

    var label: LocalizedStringResource {
        switch self {
        case .session: "Aktuelle Sitzung"
        case .weekly: "Woche"
        }
    }
}

enum MenuBarValue: String, CaseIterable, Identifiable, Sendable {
    case remaining
    case used

    var id: String { rawValue }

    var label: LocalizedStringResource {
        switch self {
        case .remaining: "Übrig"
        case .used: "Genutzt"
        }
    }
}

/// All user preferences. Every property writes through to `UserDefaults`.
@MainActor
@Observable
final class AppSettings {
    var refreshInterval: RefreshInterval {
        didSet { defaults.set(refreshInterval.rawValue, forKey: Key.refreshInterval) }
    }

    // MARK: Menu bar
    var menuBarStyle: MenuBarStyle {
        didSet { defaults.set(menuBarStyle.rawValue, forKey: Key.menuBarStyle) }
    }
    var menuBarLimit: MenuBarLimit {
        didSet { defaults.set(menuBarLimit.rawValue, forKey: Key.menuBarLimit) }
    }
    var menuBarValue: MenuBarValue {
        didSet { defaults.set(menuBarValue.rawValue, forKey: Key.menuBarValue) }
    }
    var colorsRing: Bool {
        didSet { defaults.set(colorsRing, forKey: Key.colorsRing) }
    }
    var showsStatusDot: Bool {
        didSet { defaults.set(showsStatusDot, forKey: Key.showsStatusDot) }
    }

    // MARK: Popover
    var showsModelLimits: Bool {
        didSet { defaults.set(showsModelLimits, forKey: Key.showsModelLimits) }
    }
    var showsBreakdown: Bool {
        didSet { defaults.set(showsBreakdown, forKey: Key.showsBreakdown) }
    }
    var showsClaudeSessions: Bool {
        didSet { defaults.set(showsClaudeSessions, forKey: Key.showsClaudeSessions) }
    }

    // MARK: Notifications
    var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: Key.notificationsEnabled) }
    }
    /// Percent used at which a warning is sent.
    var warningThreshold: Int {
        didSet { defaults.set(warningThreshold, forKey: Key.warningThreshold) }
    }
    /// Percent used at which a second, critical notification is sent.
    var criticalThreshold: Int {
        didSet { defaults.set(criticalThreshold, forKey: Key.criticalThreshold) }
    }
    var notifiesForWeekly: Bool {
        didSet { defaults.set(notifiesForWeekly, forKey: Key.notifiesForWeekly) }
    }
    var notifiesOnSessionReset: Bool {
        didSet { defaults.set(notifiesOnSessionReset, forKey: Key.notifiesOnSessionReset) }
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        refreshInterval = RefreshInterval(rawValue: defaults.integer(forKey: Key.refreshInterval)) ?? .minutes5
        menuBarStyle = defaults.string(forKey: Key.menuBarStyle).flatMap(MenuBarStyle.init) ?? .ring
        menuBarLimit = defaults.string(forKey: Key.menuBarLimit).flatMap(MenuBarLimit.init) ?? .session
        menuBarValue = defaults.string(forKey: Key.menuBarValue).flatMap(MenuBarValue.init) ?? .remaining
        colorsRing = defaults.bool(forKey: Key.colorsRing, default: true)
        showsStatusDot = defaults.bool(forKey: Key.showsStatusDot, default: true)
        showsModelLimits = defaults.bool(forKey: Key.showsModelLimits, default: true)
        showsBreakdown = defaults.bool(forKey: Key.showsBreakdown, default: true)
        showsClaudeSessions = defaults.bool(forKey: Key.showsClaudeSessions, default: true)
        notificationsEnabled = defaults.bool(forKey: Key.notificationsEnabled, default: false)
        warningThreshold = defaults.object(forKey: Key.warningThreshold) as? Int ?? 80
        criticalThreshold = defaults.object(forKey: Key.criticalThreshold) as? Int ?? 95
        notifiesForWeekly = defaults.bool(forKey: Key.notifiesForWeekly, default: true)
        notifiesOnSessionReset = defaults.bool(forKey: Key.notifiesOnSessionReset, default: false)
    }

    private enum Key {
        static let refreshInterval = "refreshInterval"
        static let menuBarStyle = "menuBarStyle"
        static let menuBarLimit = "menuBarLimit"
        static let menuBarValue = "menuBarValue"
        static let colorsRing = "colorsRing"
        static let showsStatusDot = "showsStatusDot"
        static let showsModelLimits = "showsModelLimits"
        static let showsBreakdown = "showsBreakdown"
        static let showsClaudeSessions = "showsClaudeSessions"
        static let notificationsEnabled = "notificationsEnabled"
        static let warningThreshold = "warningThreshold"
        static let criticalThreshold = "criticalThreshold"
        static let notifiesForWeekly = "notifiesForWeekly"
        static let notifiesOnSessionReset = "notifiesOnSessionReset"
    }
}

private extension UserDefaults {
    func bool(forKey key: String, default defaultValue: Bool) -> Bool {
        object(forKey: key) as? Bool ?? defaultValue
    }
}

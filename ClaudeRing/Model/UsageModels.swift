import Foundation

// MARK: - Raw API response

/// Response of `GET https://api.anthropic.com/api/oauth/usage`.
/// Only the fields the app needs are decoded; everything else is ignored.
/// Decoded with `.convertFromSnakeCase`, so `five_hour` becomes `fiveHour` etc.
struct UsageResponse: Decodable {
    var fiveHour: UsageWindow?
    var sevenDay: UsageWindow?
    var limits: [UsageLimit]?
    var sevenDayBreakdown: UsageBreakdown?
}

/// A single rolling usage window (e.g. the 5-hour session or the 7-day limit).
struct UsageWindow: Decodable {
    /// Percent of the window already used, 0...100.
    var utilization: Double?
    var resetsAt: Date?
}

/// One entry of the `limits` array. This is the newer, more detailed
/// representation and also carries model-scoped weekly limits.
struct UsageLimit: Decodable {
    /// `session`, `weekly_all` or `weekly_scoped`.
    var kind: String
    var group: String?
    var percent: Double?
    var severity: String?
    var resetsAt: Date?
    var scope: Scope?
    var isActive: Bool?

    struct Scope: Decodable {
        var model: Model?

        struct Model: Decodable {
            var id: String?
            var displayName: String?
        }
    }
}

/// How the weekly usage splits across Claude surfaces (Claude Code, Chats, ...).
struct UsageBreakdown: Decodable {
    var asOf: Date?
    var rows: [Row]?

    struct Row: Codable, Identifiable, Equatable {
        var key: String
        var displayName: String
        var percent: Double

        var id: String { key }
    }
}

// MARK: - View-friendly snapshot

/// A usage window prepared for display.
struct UsageWindowInfo: Identifiable, Equatable, Codable {
    /// `session`, `weekly` or `weekly_scoped_<model>`.
    let id: String
    /// For a limit of a single model: the model's name from the API.
    let modelName: String?
    /// Percent already used, clamped to 0...100.
    let usedPercent: Double
    let resetsAt: Date?

    init(id: String, modelName: String? = nil, usedPercent: Double, resetsAt: Date?) {
        self.id = id
        self.modelName = modelName
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }

    var remainingPercent: Double {
        max(0, min(100, 100 - usedPercent))
    }

    /// Made when shown rather than stored, so it follows the app's language,
    /// also for data restored from the cache.
    var title: String {
        switch id {
        case "session": String(localized: "Aktuelle Sitzung (5 Std.)")
        case "weekly": String(localized: "Woche (alle Modelle)")
        default:
            if let modelName {
                String(localized: "Woche (\(modelName))")
            } else {
                String(localized: "Woche (ein Modell)")
            }
        }
    }
}

/// Everything the UI shows, derived from one successful API call. Equatable,
/// so storing an unchanged snapshot does not invalidate any view.
struct UsageSnapshot: Equatable, Codable {
    /// The 5-hour session limit. This is what the menu bar label shows.
    let session: UsageWindowInfo?
    /// The 7-day limit across all models.
    let weekly: UsageWindowInfo?
    /// Additional 7-day limits scoped to a single model (e.g. Fable).
    let scopedWeekly: [UsageWindowInfo]
    let breakdown: [UsageBreakdown.Row]
    let planName: String?

    /// The window shown in the menu bar: the session limit when available,
    /// otherwise the weekly limit.
    var primary: UsageWindowInfo? {
        session ?? weekly
    }

    init(
        session: UsageWindowInfo?,
        weekly: UsageWindowInfo?,
        scopedWeekly: [UsageWindowInfo],
        breakdown: [UsageBreakdown.Row],
        planName: String?
    ) {
        self.session = session
        self.weekly = weekly
        self.scopedWeekly = scopedWeekly
        self.breakdown = breakdown
        self.planName = planName
    }

    init(response: UsageResponse, credentials: ClaudeCredentials.OAuth) {
        let limits = response.limits ?? []

        // Prefer the detailed `limits` array; fall back to the legacy windows.
        if let limit = limits.first(where: { $0.kind == "session" }) {
            session = UsageWindowInfo(
                id: "session",
                usedPercent: Self.clamp(limit.percent),
                resetsAt: limit.resetsAt
            )
        } else if let window = response.fiveHour {
            session = UsageWindowInfo(
                id: "session",
                usedPercent: Self.clamp(window.utilization),
                resetsAt: window.resetsAt
            )
        } else {
            session = nil
        }

        if let limit = limits.first(where: { $0.kind == "weekly_all" }) {
            weekly = UsageWindowInfo(
                id: "weekly",
                usedPercent: Self.clamp(limit.percent),
                resetsAt: limit.resetsAt
            )
        } else if let window = response.sevenDay {
            weekly = UsageWindowInfo(
                id: "weekly",
                usedPercent: Self.clamp(window.utilization),
                resetsAt: window.resetsAt
            )
        } else {
            weekly = nil
        }

        scopedWeekly = limits
            .filter { $0.kind == "weekly_scoped" }
            .enumerated()
            .map { index, limit in
                let model = limit.scope?.model?.displayName ?? limit.scope?.model?.id
                return UsageWindowInfo(
                    id: "weekly_scoped_\(limit.scope?.model?.id ?? model ?? String(index + 1))",
                    modelName: model,
                    usedPercent: Self.clamp(limit.percent),
                    resetsAt: limit.resetsAt
                )
            }

        breakdown = response.sevenDayBreakdown?.rows?.filter { $0.percent > 0 } ?? []
        planName = Self.planName(subscriptionType: credentials.subscriptionType, rateLimitTier: credentials.rateLimitTier)
    }

    private static func clamp(_ value: Double?) -> Double {
        max(0, min(100, value ?? 0))
    }

    /// Turns `max` + `default_claude_max_5x` into "Max 5x".
    private static func planName(subscriptionType: String?, rateLimitTier: String?) -> String? {
        guard let subscriptionType, !subscriptionType.isEmpty else { return nil }
        var name = subscriptionType.prefix(1).uppercased() + subscriptionType.dropFirst()
        if let tier = rateLimitTier,
           let multiplier = tier.split(separator: "_").last,
           multiplier.hasSuffix("x"),
           multiplier.dropLast().allSatisfy(\.isNumber) {
            name += " \(multiplier)"
        }
        return name
    }
}

// MARK: - Reset

extension UsageWindowInfo {
    /// After its reset time a window starts over: nothing used, and the next
    /// reset is unknown until the next request.
    func resettingIfExpired(at now: Date) -> UsageWindowInfo {
        guard let resetsAt, resetsAt <= now else { return self }
        return UsageWindowInfo(id: id, modelName: modelName, usedPercent: 0, resetsAt: nil)
    }
}

extension UsageSnapshot {
    /// Shows windows whose reset time has passed as reset, so the menu bar
    /// doesn't keep a used-up session until the next successful request.
    func resettingExpiredWindows(at now: Date) -> UsageSnapshot {
        let weeklyExpired = weekly?.resetsAt.map { $0 <= now } ?? false
        return UsageSnapshot(
            session: session?.resettingIfExpired(at: now),
            weekly: weekly?.resettingIfExpired(at: now),
            scopedWeekly: scopedWeekly.map { $0.resettingIfExpired(at: now) },
            // The breakdown splits the weekly usage and goes with it.
            breakdown: weeklyExpired ? [] : breakdown,
            planName: planName
        )
    }

    /// The earliest reset still ahead.
    func nextReset(after now: Date) -> Date? {
        ([session, weekly].compactMap { $0 } + scopedWeekly)
            .compactMap(\.resetsAt)
            .filter { $0 > now }
            .min()
    }
}

// MARK: - Levels

/// Percent used at which a window is close to its limit (warning) or nearly
/// used up (critical). The same values color the ring and bars and trigger
/// the notifications, so what people see and what they hear agree.
struct UsageThresholds: Equatable, Sendable {
    var warning: Int
    var critical: Int

    static let standard = UsageThresholds(warning: 80, critical: 95)
}

/// How close a usage window is to its limit. Drives the ring and bar colors.
enum UsageLevel: Sendable, Equatable {
    case normal
    case warning
    case critical

    /// Rounded like the notifications, so both switch at the same value.
    init(usedPercent: Double, thresholds: UsageThresholds) {
        let used = Int(usedPercent.rounded())
        if used >= thresholds.critical {
            self = .critical
        } else if used >= thresholds.warning {
            self = .warning
        } else {
            self = .normal
        }
    }
}

extension UsageWindowInfo {
    func level(_ thresholds: UsageThresholds) -> UsageLevel {
        UsageLevel(usedPercent: usedPercent, thresholds: thresholds)
    }
}

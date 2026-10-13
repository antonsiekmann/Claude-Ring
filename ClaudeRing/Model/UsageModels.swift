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
    let id: String
    let title: String
    /// Percent already used, clamped to 0...100.
    let usedPercent: Double
    let resetsAt: Date?

    var remainingPercent: Double {
        max(0, min(100, 100 - usedPercent))
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

    init(response: UsageResponse, credentials: ClaudeCredentials.OAuth) {
        let limits = response.limits ?? []

        // Prefer the detailed `limits` array; fall back to the legacy windows.
        if let limit = limits.first(where: { $0.kind == "session" }) {
            session = UsageWindowInfo(
                id: "session",
                title: "Aktuelle Sitzung (5 Std.)",
                usedPercent: Self.clamp(limit.percent),
                resetsAt: limit.resetsAt
            )
        } else if let window = response.fiveHour {
            session = UsageWindowInfo(
                id: "session",
                title: "Aktuelle Sitzung (5 Std.)",
                usedPercent: Self.clamp(window.utilization),
                resetsAt: window.resetsAt
            )
        } else {
            session = nil
        }

        if let limit = limits.first(where: { $0.kind == "weekly_all" }) {
            weekly = UsageWindowInfo(
                id: "weekly",
                title: "Woche (alle Modelle)",
                usedPercent: Self.clamp(limit.percent),
                resetsAt: limit.resetsAt
            )
        } else if let window = response.sevenDay {
            weekly = UsageWindowInfo(
                id: "weekly",
                title: "Woche (alle Modelle)",
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
                let model = limit.scope?.model?.displayName ?? "Modell \(index + 1)"
                return UsageWindowInfo(
                    id: "weekly_scoped_\(limit.scope?.model?.id ?? model)",
                    title: "Woche (\(model))",
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

// MARK: - Levels

/// How close a usage window is to its limit. Drives the ring and bar colors.
enum UsageLevel: Sendable, Equatable {
    case normal
    case warning
    case critical

    init(remainingPercent: Double) {
        switch remainingPercent {
        case ..<10: self = .critical
        case ..<30: self = .warning
        default: self = .normal
        }
    }
}

extension UsageWindowInfo {
    var level: UsageLevel { UsageLevel(remainingPercent: remainingPercent) }
}

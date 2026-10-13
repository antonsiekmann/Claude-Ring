import Foundation

/// Remembers the last successful usage data, so the app shows the last known
/// state right after launch and while the endpoint answers 429. Holds only
/// percentages, reset times and the plan name, never the token.
struct UsageSnapshotCache {
    struct Entry: Codable, Equatable {
        var snapshot: UsageSnapshot
        var fetchedAt: Date
    }

    private static let key = "lastUsage"
    let defaults: UserDefaults

    func load() -> Entry? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        return try? JSONDecoder().decode(Entry.self, from: data)
    }

    func save(_ snapshot: UsageSnapshot, fetchedAt: Date) {
        defaults.set(try? JSONEncoder().encode(Entry(snapshot: snapshot, fetchedAt: fetchedAt)), forKey: Self.key)
    }
}

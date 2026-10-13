import Foundation
import Testing
@testable import ClaudeRing

struct UsageSnapshotTests {
    private let credentials = ClaudeCredentials.OAuth(
        accessToken: "token",
        expiresAt: nil,
        subscriptionType: "max",
        rateLimitTier: "default_claude_max_5x"
    )

    private func decode(_ json: String) throws -> UsageResponse {
        try UsageAPIClient.makeDecoder().decode(UsageResponse.self, from: Data(json.utf8))
    }

    @Test func `Prefers the detailed limits array over the legacy windows`() throws {
        let response = try decode("""
        {
          "five_hour": { "utilization": 10, "resets_at": "2026-10-08T18:00:00Z" },
          "seven_day": { "utilization": 20, "resets_at": "2026-10-12T09:00:00Z" },
          "limits": [
            { "kind": "session", "percent": 42.4, "resets_at": "2026-10-08T18:00:00.123Z" },
            { "kind": "weekly_all", "percent": 64, "resets_at": "2026-10-12T09:00:00Z" },
            { "kind": "weekly_scoped", "percent": 91, "resets_at": "2026-10-12T09:00:00Z",
              "scope": { "model": { "id": "fable", "display_name": "Fable" } } }
          ]
        }
        """)
        let snapshot = UsageSnapshot(response: response, credentials: credentials)

        let session = try #require(snapshot.session)
        #expect(session.usedPercent == 42.4)
        #expect(session.resetsAt != nil)
        #expect(snapshot.weekly?.usedPercent == 64)
        #expect(snapshot.scopedWeekly.map(\.title) == ["Woche (Fable)"])
        #expect(snapshot.primary?.id == "session")
    }

    @Test func `Falls back to the legacy windows without a limits array`() throws {
        let response = try decode("""
        { "five_hour": { "utilization": 12.5, "resets_at": "2026-10-08T18:00:00Z" },
          "seven_day": { "utilization": 30 } }
        """)
        let snapshot = UsageSnapshot(response: response, credentials: credentials)

        #expect(snapshot.session?.usedPercent == 12.5)
        #expect(snapshot.weekly?.usedPercent == 30)
        #expect(snapshot.weekly?.resetsAt == nil)
        #expect(snapshot.scopedWeekly.isEmpty)
    }

    @Test func `Clamps percentages and derives the remaining share`() throws {
        let response = try decode("""
        { "limits": [ { "kind": "session", "percent": 130 }, { "kind": "weekly_all", "percent": -5 } ] }
        """)
        let snapshot = UsageSnapshot(response: response, credentials: credentials)

        #expect(snapshot.session?.usedPercent == 100)
        #expect(snapshot.session?.remainingPercent == 0)
        #expect(snapshot.weekly?.usedPercent == 0)
        #expect(snapshot.weekly?.remainingPercent == 100)
    }

    @Test func `Drops breakdown rows without usage`() throws {
        let response = try decode("""
        { "seven_day_breakdown": { "rows": [
            { "key": "claude_code", "display_name": "Claude Code", "percent": 40 },
            { "key": "chat", "display_name": "Chats", "percent": 0 }
        ] } }
        """)
        let snapshot = UsageSnapshot(response: response, credentials: credentials)

        #expect(snapshot.breakdown.map(\.key) == ["claude_code"])
    }

    @Test(arguments: [
        ("max", "default_claude_max_5x", "Max 5x"),
        ("pro", nil, "Pro"),
        ("max", "default_claude_max", "Max"),
    ] as [(String, String?, String)])
    func `Formats the plan name`(subscriptionType: String, tier: String?, expected: String) throws {
        let credentials = ClaudeCredentials.OAuth(
            accessToken: "token", expiresAt: nil, subscriptionType: subscriptionType, rateLimitTier: tier
        )
        let snapshot = UsageSnapshot(response: try decode("{}"), credentials: credentials)

        #expect(snapshot.planName == expected)
    }
}

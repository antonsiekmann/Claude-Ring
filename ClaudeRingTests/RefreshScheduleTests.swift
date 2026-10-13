import Foundation
import Testing
@testable import ClaudeRing

struct RefreshScheduleTests {
    @Test func `Uses the configured interval while requests succeed`() {
        #expect(RefreshSchedule.delay(interval: .seconds(60), consecutiveFailures: 0, retryAfter: nil) == .seconds(60))
    }

    @Test(arguments: [
        (1, 120), (2, 240), (3, 480), (4, 900), (10, 900),
    ])
    func `Backs off exponentially up to 15 minutes`(failures: Int, expectedSeconds: Int) {
        let delay = RefreshSchedule.delay(interval: .seconds(60), consecutiveFailures: failures, retryAfter: nil)
        #expect(delay == .seconds(expectedSeconds))
    }

    @Test func `Backs off long intervals to 15 minutes as well`() {
        let delay = RefreshSchedule.delay(interval: .seconds(600), consecutiveFailures: 3, retryAfter: nil)
        #expect(delay == .seconds(900))
    }

    @Test func `Honors a longer Retry-After`() {
        let delay = RefreshSchedule.delay(interval: .seconds(60), consecutiveFailures: 1, retryAfter: .seconds(300))
        #expect(delay == .seconds(300))
    }

    @Test func `Caps Retry-After at one hour`() {
        let delay = RefreshSchedule.delay(interval: .seconds(60), consecutiveFailures: 1, retryAfter: .seconds(86_400))
        #expect(delay == .seconds(3600))
    }

    @Test func `Allows a tenth of the delay as timer tolerance`() {
        #expect(RefreshSchedule.tolerance(for: .seconds(60)) == .seconds(6))
    }

    @Test func `Treats missing or old data as stale`() {
        let now = Date()
        #expect(RefreshSchedule.isStale(lastUpdated: nil, now: now))
        #expect(RefreshSchedule.isStale(lastUpdated: now.addingTimeInterval(-121), now: now))
        #expect(!RefreshSchedule.isStale(lastUpdated: now.addingTimeInterval(-60), now: now))
    }

    @Test(arguments: [
        (1, 300), (2, 600), (3, 1200), (4, 1800), (9, 1800),
    ])
    func `Backs off much longer after 429 responses`(failures: Int, expectedSeconds: Int) {
        let delay = RefreshSchedule.delay(
            interval: .seconds(60), consecutiveFailures: failures, isRateLimited: true, retryAfter: .zero
        )
        #expect(delay == .seconds(expectedSeconds))
    }
}

@MainActor
struct AppSettingsTests {
    private func makeDefaults() -> UserDefaults {
        let name = "AppSettingsTests-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func `Starts with the documented defaults`() {
        let settings = AppSettings(defaults: makeDefaults())

        #expect(settings.refreshInterval == .minutes5)
        #expect(settings.menuBarStyle == .ring)
        #expect(settings.menuBarLimit == .session)
        #expect(settings.menuBarValue == .remaining)
        #expect(settings.colorsRing)
        #expect(settings.showsStatusDot)
        #expect(!settings.notificationsEnabled)
        #expect(settings.warningThreshold == 80)
        #expect(settings.criticalThreshold == 95)
    }

    @Test func `Persists changes`() {
        let defaults = makeDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.refreshInterval = .minutes5
        settings.menuBarStyle = .bars
        settings.colorsRing = false
        settings.warningThreshold = 70

        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.refreshInterval == .minutes5)
        #expect(reloaded.menuBarStyle == .bars)
        #expect(!reloaded.colorsRing)
        #expect(reloaded.warningThreshold == 70)
    }
}

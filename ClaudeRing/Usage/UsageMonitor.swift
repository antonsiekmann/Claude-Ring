import Foundation
import Observation
import OSLog

/// Owns the polling loop and the latest usage data for the UI.
///
/// Polling is deliberately frugal: it follows the interval from the settings
/// with timer tolerance, backs off after failures, honors `Retry-After`, and
/// pauses while the Mac sleeps, the screen is locked or the displays are off.
@MainActor
@Observable
final class UsageMonitor {
    /// Last successfully fetched data. Kept around when a refresh fails so the
    /// menu bar keeps showing the most recent known value.
    private(set) var snapshot: UsageSnapshot?
    /// Human-readable description of the most recent failure, if any.
    private(set) var errorMessage: String?
    private(set) var isRefreshing = false
    private(set) var lastUpdated: Date?
    /// Expiry of the token used for the last request, for the settings window.
    private(set) var tokenExpiry: Date?
    /// When the next request happens while backing off after failures.
    private(set) var nextAttempt: Date?

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let credentials: CredentialProvider
    @ObservationIgnored private let apiClient: UsageAPIClient
    @ObservationIgnored private let activity = SystemActivityObserver()
    @ObservationIgnored private var pollingTask: Task<Void, Never>?
    @ObservationIgnored private var settingsTask: Task<Void, Never>?
    /// A replaced refresh may still be winding down while the next one runs.
    @ObservationIgnored private var activeRefreshes = 0 {
        didSet { isRefreshing = activeRefreshes > 0 }
    }
    @ObservationIgnored private var consecutiveFailures = 0
    @ObservationIgnored private var retryAfter: Duration?
    @ObservationIgnored private var isRateLimited = false
    @ObservationIgnored private let cache: UsageSnapshotCache?
    /// While backing off after failures, opening the popover must not fetch.
    @ObservationIgnored private var backoffUntil: Date?
    @ObservationIgnored private let logger = Logger(subsystem: "eu.siekmann.ClaudeRing", category: "usage")

    init(
        settings: AppSettings,
        credentials: CredentialProvider = CredentialProvider(),
        apiClient: UsageAPIClient = UsageAPIClient(),
        cache: UsageSnapshotCache? = AppEnvironment.isRunningTests ? nil : UsageSnapshotCache(defaults: .standard)
    ) {
        self.settings = settings
        self.credentials = credentials
        self.apiClient = apiClient
        self.cache = cache
        if let cached = cache?.load() {
            snapshot = cached.snapshot
            lastUpdated = cached.fetchedAt
        }
    }

    /// Starts polling and the sleep/lock observation. Safe to call more than once.
    func start() {
        guard settingsTask == nil, !AppEnvironment.isRunningTests else { return }

        activity.onChange = { [weak self] isPaused in
            guard let self else { return }
            if isPaused {
                logger.info("Polling paused")
                stopPolling()
            } else {
                logger.info("Polling resumed")
                // Give the network a moment to come back after wake or unlock.
                startPolling(after: .seconds(3))
            }
        }
        activity.start()

        let settings = settings
        settingsTask = Task { [weak self] in
            // Restart the timer whenever the interval changes; the first value
            // is the current one and starts polling.
            for await _ in Observations({ settings.refreshInterval }) {
                self?.startPolling(after: .zero)
            }
        }
    }

    #if DEBUG
    /// Shows fixed data without network access, for previews and snapshot tests.
    func showPreview(snapshot: UsageSnapshot?, errorMessage: String? = nil) {
        self.snapshot = snapshot
        self.errorMessage = errorMessage
        lastUpdated = snapshot == nil ? nil : .now
    }
    #endif

    /// Stops polling and every observation for good.
    func stop() {
        settingsTask?.cancel()
        settingsTask = nil
        activity.onChange = nil
        activity.stop()
        stopPolling()
    }

    /// Refreshes right away when the shown data is older than a few seconds.
    /// Called when the popover opens.
    func refreshIfStale() {
        guard RefreshSchedule.isStale(lastUpdated: lastUpdated, now: .now) else { return }
        refreshUnlessBackingOff()
    }

    /// For automatic triggers: fetches now unless earlier failures (or the
    /// server's Retry-After) asked to wait. A manual refresh ignores this.
    func refreshUnlessBackingOff() {
        if let backoffUntil, backoffUntil > .now { return }
        startPolling(after: .zero)
    }

    /// Fetches now and restarts the timer from here.
    func refreshNow() {
        startPolling(after: .zero)
    }

    private func startPolling(after initialDelay: Duration) {
        pollingTask?.cancel()
        guard !activity.isPaused else { return }
        pollingTask = Task { [weak self] in
            if initialDelay > .zero {
                try? await Task.sleep(for: initialDelay)
            }
            while !Task.isCancelled {
                guard let delay = await self?.refreshAndScheduleNext() else { return }
                do {
                    try await Task.sleep(for: delay, tolerance: RefreshSchedule.tolerance(for: delay))
                } catch {
                    return // cancelled
                }
            }
        }
    }

    private func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    private func refreshAndScheduleNext() async -> Duration {
        await refresh()
        let delay = RefreshSchedule.delay(
            interval: settings.refreshInterval.duration,
            consecutiveFailures: consecutiveFailures,
            isRateLimited: isRateLimited,
            retryAfter: retryAfter
        )
        backoffUntil = consecutiveFailures > 0 ? .now.addingTimeInterval(delay.timeInterval) : nil
        nextAttempt = backoffUntil
        if consecutiveFailures > 0 {
            logger.info("Next attempt in \(Int(delay.timeInterval), privacy: .public) s (Retry-After: \(self.retryAfter.map { String(Int($0.timeInterval)) } ?? "none", privacy: .public))")
        }
        return delay
    }

    private func refresh() async {
        activeRefreshes += 1
        defer { activeRefreshes -= 1 }

        do {
            var oauth = try await credentials.credentials()
            let response: UsageResponse
            do {
                response = try await apiClient.fetchUsage(accessToken: oauth.accessToken)
            } catch UsageAPIError.unauthorized {
                // Claude Code may have refreshed the token in the meantime.
                guard let fresh = try await credentials.credentials(replacingRejected: oauth.accessToken) else {
                    throw UsageAPIError.unauthorized
                }
                oauth = fresh
                response = try await apiClient.fetchUsage(accessToken: oauth.accessToken)
            }
            let fetched = UsageSnapshot(response: response, credentials: oauth)
            let now = Date.now
            snapshot = fetched
            tokenExpiry = oauth.expiryDate
            lastUpdated = now
            errorMessage = nil
            consecutiveFailures = 0
            retryAfter = nil
            isRateLimited = false
            cache?.save(fetched, fetchedAt: now)
            logger.info("Usage refreshed, session \(self.snapshot?.session?.usedPercent ?? -1, privacy: .public) % used")
        } catch is CancellationError {
            // A newer refresh replaced this one.
        } catch let error as URLError where error.code == .cancelled {
            // Same, surfaced by URLSession.
        } catch {
            consecutiveFailures += 1
            if case UsageAPIError.rateLimited(let serverDelay) = error {
                retryAfter = serverDelay
                isRateLimited = true
            } else {
                retryAfter = nil
                isRateLimited = false
            }
            errorMessage = error.localizedDescription
            logger.error("Usage refresh failed (\(self.consecutiveFailures, privacy: .public)x): \(error.localizedDescription, privacy: .public)")
        }
    }
}

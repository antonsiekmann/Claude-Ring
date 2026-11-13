import Foundation
import Observation
import OSLog

/// What a failed refresh means for the person looking at the menu bar.
enum UsageProblem: Equatable, Sendable {
    /// No Claude Code login, or its token expired or was turned down. Fixed
    /// by running `claude`; the app watches the keychain instead of retrying.
    case signIn(String)
    /// Anthropic throttles the usage endpoint. Nothing to do; the last data stays.
    case rateLimited
    /// No connection right now.
    case offline
    /// Anything else, such as a server error or an unexpected answer.
    case other(String)

    private static let offlineCodes: Set<URLError.Code> = [
        .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
        .dnsLookupFailed, .timedOut, .dataNotAllowed, .internationalRoamingOff,
    ]

    init(_ error: Error) {
        switch error {
        case CredentialError.notFound, CredentialError.expired, CredentialError.malformed, UsageAPIError.unauthorized:
            self = .signIn(error.localizedDescription)
        case UsageAPIError.rateLimited:
            self = .rateLimited
        case let error as URLError where Self.offlineCodes.contains(error.code):
            self = .offline
        default:
            self = .other(error.localizedDescription)
        }
    }

    var isSignIn: Bool {
        if case .signIn = self { true } else { false }
    }

    /// Something the person can or should act on. Throttling and a short
    /// time offline are not; the last data stays in view without alarm.
    var needsAttention: Bool {
        switch self {
        case .signIn, .other: true
        case .rateLimited, .offline: false
        }
    }

    var message: String {
        switch self {
        case .signIn(let message), .other(let message):
            message
        case .rateLimited:
            String(localized: "Anthropic drosselt die Abfragen gerade.")
        case .offline:
            String(localized: "Gerade keine Internetverbindung.")
        }
    }
}

/// Owns the polling loop and the latest usage data for the UI.
///
/// Polling is deliberately frugal: it follows the interval from the settings
/// with timer tolerance, backs off after failures, honors `Retry-After`, and
/// pauses while the Mac sleeps, the screen is locked or the displays are off.
/// A missing or expired login doesn't back off: the app watches the keychain
/// instead and fetches as soon as Claude Code has signed in again.
@MainActor
@Observable
final class UsageMonitor {
    /// Last successfully fetched data. Kept around when a refresh fails so the
    /// menu bar keeps showing the most recent known value. Windows past their
    /// reset time show as reset.
    private(set) var snapshot: UsageSnapshot?
    /// Why the most recent refresh failed, if it did.
    private(set) var problem: UsageProblem?
    /// Data too old to show without a hint (see `RefreshSchedule.isOutdated`).
    private(set) var isOutdated = false
    private(set) var isRefreshing = false
    private(set) var lastUpdated: Date?
    /// Expiry of the token used for the last request, for the settings window.
    private(set) var tokenExpiry: Date?
    /// When the next request happens after a failure.
    private(set) var nextAttempt: Date?

    var errorMessage: String? { problem?.message }

    /// Whether the menu bar marks the data and the popover warns: for problems
    /// the person can fix, for outdated data, and when there is no data at all.
    var needsAttention: Bool {
        guard let problem else { return false }
        return problem.needsAttention || isOutdated || snapshot == nil
    }

    /// What blocks requests while `problem` is `.signIn`.
    private enum SignInIssue: Equatable {
        /// No usable login in the keychain.
        case missing
        /// The API turned this token down; another one is needed.
        case rejected(token: String)
    }

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let credentials: CredentialProvider
    @ObservationIgnored private let apiClient: UsageAPIClient
    @ObservationIgnored private let loginChecker: any LoginChecking
    @ObservationIgnored private let activity = SystemActivityObserver()
    @ObservationIgnored private var pollingTask: Task<Void, Never>?
    @ObservationIgnored private var settingsTask: Task<Void, Never>?
    @ObservationIgnored private var signInTask: Task<Void, Never>?
    @ObservationIgnored private var resetTask: Task<Void, Never>?
    /// A replaced refresh may still be winding down while the next one runs.
    @ObservationIgnored private var activeRefreshes = 0 {
        didSet { isRefreshing = activeRefreshes > 0 }
    }
    @ObservationIgnored private var consecutiveFailures = 0
    @ObservationIgnored private var retryAfter: Duration?
    @ObservationIgnored private var isRateLimited = false
    @ObservationIgnored private var signInIssue: SignInIssue?
    @ObservationIgnored private let cache: UsageSnapshotCache?
    /// While backing off after failures, automatic triggers must not fetch.
    @ObservationIgnored private var backoffUntil: Date?
    @ObservationIgnored private let logger = Logger(subsystem: "eu.siekmann.ClaudeRing", category: "usage")

    /// How often the keychain is checked while waiting for a login.
    private static let signInCheckInterval: Duration = .seconds(30)
    /// Automatic triggers leave data this young alone.
    private static let minimumAutomaticAge: TimeInterval = 60

    init(
        settings: AppSettings,
        credentials: CredentialProvider = CredentialProvider(),
        apiClient: UsageAPIClient = UsageAPIClient(),
        cache: UsageSnapshotCache? = AppEnvironment.isRunningTests ? nil : UsageSnapshotCache(defaults: .standard),
        loginChecker: any LoginChecking = SecurityToolLoginChecker()
    ) {
        self.settings = settings
        self.credentials = credentials
        self.apiClient = apiClient
        self.cache = cache
        self.loginChecker = loginChecker
        if let cached = cache?.load() {
            lastUpdated = cached.fetchedAt
            show(cached.snapshot)
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
                // Give the network a moment, but keep any wait that failures
                // or the server's Retry-After asked for.
                startPolling(after: max(.seconds(3), durationUntilDue()))
            }
        }
        activity.start()

        let settings = settings
        settingsTask = Task { [weak self] in
            // The first value is the current interval and starts polling; a
            // changed interval only moves the next request.
            var isFirst = true
            for await _ in Observations({ settings.refreshInterval }) {
                guard let self else { return }
                startPolling(after: isFirst ? .zero : durationUntilDue())
                isFirst = false
            }
        }
    }

    #if DEBUG
    /// Shows fixed data without network access, for previews and snapshot tests.
    func showPreview(snapshot: UsageSnapshot?, problem: UsageProblem? = nil, nextAttempt: Date? = nil) {
        self.snapshot = snapshot
        self.problem = problem
        self.nextAttempt = nextAttempt
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
        signInTask?.cancel()
        signInTask = nil
        resetTask?.cancel()
        resetTask = nil
    }

    /// Called when the popover opens: refreshes data older than a few
    /// minutes, or checks right away whether the missing login is there now.
    func refreshIfStale() {
        if problem?.isSignIn == true {
            Task { await checkSignIn() }
            return
        }
        guard RefreshSchedule.isStale(lastUpdated: lastUpdated, now: .now) else { return }
        refreshUnlessBackingOff()
    }

    /// For automatic triggers: fetches now unless earlier failures (or the
    /// server's Retry-After) asked to wait, a request is running already or
    /// the data is only a minute old. A manual refresh ignores this.
    func refreshUnlessBackingOff() {
        if let backoffUntil, backoffUntil > .now { return }
        guard activeRefreshes == 0 else { return }
        if let lastUpdated, Date.now.timeIntervalSince(lastUpdated) < Self.minimumAutomaticAge { return }
        startPolling(after: .zero)
    }

    /// Fetches now and restarts the timer from here.
    func refreshNow() {
        startPolling(after: .zero)
    }

    /// Looks only at the keychain, without a request: is there a usable login
    /// now? If so, fetches right away. Reading the secret is limited to once a
    /// minute by `CredentialProvider`; whether a login exists at all is asked
    /// without the secret, which never shows a password dialog.
    func checkSignIn() async {
        guard problem?.isSignIn == true, let issue = signInIssue else { return }
        let isReady: Bool
        switch issue {
        case .missing:
            if await loginChecker.hasLogin() {
                isReady = (try? await credentials.credentials()) != nil
            } else {
                isReady = false
            }
        case .rejected(let token):
            isReady = ((try? await credentials.credentials(replacingRejected: token)) ?? nil) != nil
        }
        guard isReady, problem?.isSignIn == true else { return }
        logger.info("Login available again")
        refreshNow()
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

    private func durationUntilDue(now: Date = .now) -> Duration {
        let due = RefreshSchedule.nextDue(lastUpdated: lastUpdated, interval: settings.refreshInterval.duration, backoffUntil: backoffUntil)
        return .seconds(max(0, due.timeIntervalSince(now)))
    }

    /// Internal for tests.
    func refreshAndScheduleNext() async -> Duration {
        await refresh()
        let interval = settings.refreshInterval.duration
        let delay: Duration
        switch problem {
        case .offline:
            delay = min(interval, RefreshSchedule.offlineRetry)
        case .signIn:
            // The keychain watch fetches as soon as the login is back.
            delay = interval
        case .rateLimited, .other, nil:
            delay = RefreshSchedule.delay(
                interval: interval,
                consecutiveFailures: consecutiveFailures,
                isRateLimited: isRateLimited,
                retryAfter: retryAfter
            )
        }
        let backsOff = switch problem {
        case .rateLimited, .other: true
        case .offline, .signIn, nil: false
        }
        backoffUntil = backsOff ? .now.addingTimeInterval(delay.timeInterval) : nil
        nextAttempt = problem == nil || problem?.isSignIn == true ? nil : .now.addingTimeInterval(delay.timeInterval)
        if let problem {
            logger.info("Next attempt in \(Int(delay.timeInterval), privacy: .public) s after \(String(describing: problem), privacy: .public) (Retry-After: \(self.retryAfter.map { String(Int($0.timeInterval)) } ?? "none", privacy: .public))")
        }
        return delay
    }

    private func refresh() async {
        activeRefreshes += 1
        defer { activeRefreshes -= 1 }

        var sentToken: String?
        do {
            var oauth = try await credentials.credentials()
            if case .rejected(let rejected) = signInIssue, oauth.accessToken == rejected {
                // Don't send a token the API has already turned down.
                guard let fresh = try await credentials.credentials(replacingRejected: rejected) else {
                    sentToken = rejected
                    throw UsageAPIError.unauthorized
                }
                oauth = fresh
            }
            let response: UsageResponse
            do {
                sentToken = oauth.accessToken
                response = try await apiClient.fetchUsage(accessToken: oauth.accessToken)
            } catch UsageAPIError.unauthorized {
                // Claude Code may have refreshed the token in the meantime.
                guard let fresh = try await credentials.credentials(replacingRejected: oauth.accessToken) else {
                    throw UsageAPIError.unauthorized
                }
                oauth = fresh
                sentToken = oauth.accessToken
                response = try await apiClient.fetchUsage(accessToken: oauth.accessToken)
            }
            let fetched = UsageSnapshot(response: response, credentials: oauth)
            let now = Date.now
            tokenExpiry = oauth.expiryDate
            lastUpdated = now
            show(fetched)
            problem = nil
            isOutdated = false
            consecutiveFailures = 0
            retryAfter = nil
            isRateLimited = false
            signInIssue = nil
            stopWatchingSignIn()
            cache?.save(fetched, fetchedAt: now)
            logger.info("Usage refreshed, session \(self.snapshot?.session?.usedPercent ?? -1, privacy: .public) % used")
        } catch is CancellationError {
            // A newer refresh replaced this one.
        } catch let error as URLError where error.code == .cancelled {
            // Same, surfaced by URLSession.
        } catch {
            let problem = UsageProblem(error)
            self.problem = problem
            switch problem {
            case .signIn:
                // A local problem: no backoff, the keychain is watched instead.
                if case UsageAPIError.unauthorized = error, let sentToken {
                    signInIssue = .rejected(token: sentToken)
                } else {
                    signInIssue = .missing
                }
                retryAfter = nil
                isRateLimited = false
                startWatchingSignIn()
            case .rateLimited:
                consecutiveFailures += 1
                if case UsageAPIError.rateLimited(let serverDelay) = error {
                    retryAfter = serverDelay
                }
                isRateLimited = true
            case .offline:
                retryAfter = nil
                isRateLimited = false
            case .other:
                consecutiveFailures += 1
                retryAfter = nil
                isRateLimited = false
            }
            isOutdated = RefreshSchedule.isOutdated(lastUpdated: lastUpdated, interval: settings.refreshInterval.duration, now: .now)
            logger.error("Usage refresh failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Waiting for a login

    private func startWatchingSignIn() {
        guard signInTask == nil, !AppEnvironment.isRunningTests else { return }
        signInTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.signInCheckInterval, tolerance: .seconds(5))
                guard !Task.isCancelled, let self, self.problem?.isSignIn == true else { return }
                await self.checkSignIn()
            }
        }
    }

    private func stopWatchingSignIn() {
        signInTask?.cancel()
        signInTask = nil
    }

    // MARK: - Resets

    /// Shows the data with windows past their reset time as reset, and wakes
    /// up at the next reset to do so again.
    private func show(_ data: UsageSnapshot?) {
        snapshot = data?.resettingExpiredWindows(at: .now)
        resetTask?.cancel()
        resetTask = nil
        guard let next = snapshot?.nextReset(after: .now) else { return }
        let delay = next.timeIntervalSinceNow + 1
        resetTask = Task { [weak self] in
            // The continuous clock keeps counting while the Mac sleeps.
            try? await Task.sleep(for: .seconds(delay), tolerance: .seconds(5))
            guard !Task.isCancelled, let self else { return }
            self.show(self.snapshot)
            self.refreshUnlessBackingOff()
        }
    }
}

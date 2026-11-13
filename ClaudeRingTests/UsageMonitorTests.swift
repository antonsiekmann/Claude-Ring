import Foundation
import Synchronization
import Testing
@preconcurrency import UserNotifications
@testable import ClaudeRing

// MARK: - Classification

struct UsageProblemTests {
    @Test func `Sorts failures by what they mean for the person`() {
        #expect(UsageProblem(CredentialError.notFound).isSignIn)
        #expect(UsageProblem(CredentialError.expired).isSignIn)
        #expect(UsageProblem(CredentialError.malformed).isSignIn)
        #expect(UsageProblem(UsageAPIError.unauthorized).isSignIn)
        #expect(UsageProblem(UsageAPIError.rateLimited(retryAfter: nil)) == .rateLimited)
        #expect(UsageProblem(URLError(.notConnectedToInternet)) == .offline)
        #expect(UsageProblem(URLError(.timedOut)) == .offline)
        #expect(UsageProblem(UsageAPIError.httpStatus(500)) == .other(UsageAPIError.httpStatus(500).localizedDescription))
        #expect(UsageProblem(CredentialError.timedOut) == .other(CredentialError.timedOut.localizedDescription))
    }

    @Test func `Asks for attention only when the person can do something`() {
        #expect(UsageProblem.signIn("x").needsAttention)
        #expect(UsageProblem.other("x").needsAttention)
        #expect(!UsageProblem.rateLimited.needsAttention)
        #expect(!UsageProblem.offline.needsAttention)
    }
}

// MARK: - Schedule

struct RefreshDueTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func `Is due once the interval since the last data is over`() {
        let due = RefreshSchedule.nextDue(lastUpdated: now.addingTimeInterval(-60), interval: .seconds(300), backoffUntil: nil)
        #expect(due == now.addingTimeInterval(240))
    }

    @Test func `Waits for a longer backoff`() {
        let due = RefreshSchedule.nextDue(
            lastUpdated: now.addingTimeInterval(-600), interval: .seconds(300), backoffUntil: now.addingTimeInterval(1_800)
        )
        #expect(due == now.addingTimeInterval(1_800))
    }

    @Test func `Is due right away without any data`() {
        #expect(RefreshSchedule.nextDue(lastUpdated: nil, interval: .seconds(300), backoffUntil: nil) <= now)
    }

    @Test func `Calls data outdated after three intervals, at least 15 minutes`() {
        #expect(!RefreshSchedule.isOutdated(lastUpdated: now.addingTimeInterval(-14 * 60), interval: .seconds(60), now: now))
        #expect(RefreshSchedule.isOutdated(lastUpdated: now.addingTimeInterval(-16 * 60), interval: .seconds(60), now: now))
        #expect(!RefreshSchedule.isOutdated(lastUpdated: now.addingTimeInterval(-25 * 60), interval: .seconds(600), now: now))
        #expect(RefreshSchedule.isOutdated(lastUpdated: now.addingTimeInterval(-31 * 60), interval: .seconds(600), now: now))
        #expect(RefreshSchedule.isOutdated(lastUpdated: nil, interval: .seconds(300), now: now))
    }
}

// MARK: - Reset

struct UsageResetTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func snapshot(sessionReset: Date, weeklyReset: Date) -> UsageSnapshot {
        UsageSnapshot(
            session: UsageWindowInfo(id: "session", usedPercent: 97, resetsAt: sessionReset),
            weekly: UsageWindowInfo(id: "weekly", usedPercent: 60, resetsAt: weeklyReset),
            scopedWeekly: [],
            breakdown: [.init(key: "claude_code", displayName: "Claude Code", percent: 40)],
            planName: "Max"
        )
    }

    @Test func `Shows a window as reset once its reset time has passed`() {
        let data = snapshot(sessionReset: now.addingTimeInterval(-1), weeklyReset: now.addingTimeInterval(86_400))

        let shown = data.resettingExpiredWindows(at: now)

        #expect(shown.session?.usedPercent == 0)
        #expect(shown.session?.resetsAt == nil)
        #expect(shown.weekly == data.weekly)
        #expect(shown.breakdown == data.breakdown)
    }

    @Test func `Drops the weekly breakdown together with the weekly window`() {
        let data = snapshot(sessionReset: now.addingTimeInterval(3_600), weeklyReset: now.addingTimeInterval(-1))

        #expect(data.resettingExpiredWindows(at: now).breakdown.isEmpty)
    }

    @Test func `Knows the next reset ahead`() {
        let data = snapshot(sessionReset: now.addingTimeInterval(3_600), weeklyReset: now.addingTimeInterval(86_400))

        #expect(data.nextReset(after: now) == now.addingTimeInterval(3_600))
        #expect(data.nextReset(after: now.addingTimeInterval(4_000)) == now.addingTimeInterval(86_400))
    }
}

// MARK: - Expired token

private actor ScriptedKeychain: KeychainReading {
    private var results: [Result<Data, CredentialError>]
    private(set) var reads = 0

    init(_ results: [Result<Data, CredentialError>]) {
        self.results = results
    }

    func set(_ results: [Result<Data, CredentialError>]) {
        self.results = results
    }

    func readSecret() async throws -> Data {
        reads += 1
        return try (results.count > 1 ? results.removeFirst() : results[0]).get()
    }
}

private func credentialsJSON(token: String, expiresAt: Date?) -> Data {
    let expiry = expiresAt.map { ", \"expiresAt\": \(Int($0.timeIntervalSince1970 * 1000))" } ?? ""
    return Data("""
    { "claudeAiOauth": { "accessToken": "\(token)"\(expiry), "subscriptionType": "max" } }
    """.utf8)
}

private let noFallbackFile = URL(filePath: "/nonexistent/credentials.json")

struct ExpiredTokenTests {
    @Test func `Reports an expired token instead of sending it`() async throws {
        let keychain = ScriptedKeychain([.success(credentialsJSON(token: "old", expiresAt: .now.addingTimeInterval(-3_600)))])
        let provider = CredentialProvider(keychain: keychain, fallbackFileURL: noFallbackFile)

        await #expect(throws: CredentialError.expired) { try await provider.credentials() }
        // Asked again within the reload interval: still expired, without reading the keychain again.
        await #expect(throws: CredentialError.expired) { try await provider.credentials() }
        #expect(await keychain.reads == 1)
    }
}

// MARK: - Monitor

/// Answers the usage requests of one test with scripted responses.
final class StubUsageServer: URLProtocol, @unchecked Sendable {
    enum Answer {
        case status(Int, body: String = "{}")
        case failure(URLError.Code)
    }

    private static let state = Mutex<(answers: [Answer], requests: Int)>(([], 0))

    static func reset(_ answers: [Answer]) {
        state.withLock { $0 = (answers, 0) }
    }

    static var requests: Int { state.withLock { $0.requests } }

    static let usageBody = #"{ "limits": [ { "kind": "session", "percent": 13, "resets_at": "2099-01-01T00:00:00Z" } ] }"#

    static func makeClient() -> UsageAPIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubUsageServer.self]
        return UsageAPIClient(session: URLSession(configuration: configuration))
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let answer = Self.state.withLock { state -> Answer in
            state.requests += 1
            return state.answers.count > 1 ? state.answers.removeFirst() : state.answers.first ?? .status(500)
        }
        switch answer {
        case .status(let code, let body):
            let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        }
    }
}

private final class SwitchableLoginChecker: LoginChecking, @unchecked Sendable {
    private let value = Mutex(false)
    var hasLoginValue: Bool {
        get { value.withLock { $0 } }
        set { value.withLock { $0 = newValue } }
    }
    func hasLogin() async -> Bool { hasLoginValue }
}

@MainActor
@Suite(.serialized)
struct UsageMonitorTests {
    private let store = TestDefaults()

    private func makeMonitor(keychain: ScriptedKeychain, loginChecker: SwitchableLoginChecker = SwitchableLoginChecker()) -> UsageMonitor {
        UsageMonitor(
            settings: AppSettings(defaults: store.defaults),
            credentials: CredentialProvider(keychain: keychain, fallbackFileURL: noFallbackFile, minimumReloadInterval: .zero),
            apiClient: StubUsageServer.makeClient(),
            cache: nil,
            loginChecker: loginChecker
        )
    }

    @Test func `Waits for the login without backing off and fetches once it appears`() async throws {
        StubUsageServer.reset([.status(200, body: StubUsageServer.usageBody)])
        let keychain = ScriptedKeychain([.failure(.notFound)])
        let login = SwitchableLoginChecker()
        let monitor = makeMonitor(keychain: keychain, loginChecker: login)

        _ = await monitor.refreshAndScheduleNext()

        #expect(monitor.problem?.isSignIn == true)
        #expect(monitor.needsAttention)
        #expect(monitor.nextAttempt == nil)
        #expect(StubUsageServer.requests == 0)

        await keychain.set([.success(credentialsJSON(token: "fresh", expiresAt: .now.addingTimeInterval(3_600)))])
        login.hasLoginValue = true
        await monitor.checkSignIn()
        try await waitUntil { monitor.snapshot != nil }

        #expect(monitor.problem == nil)
        #expect(monitor.snapshot?.session?.usedPercent == 13)
        #expect(StubUsageServer.requests == 1)
    }

    @Test func `Does not send a token the API has already turned down`() async {
        StubUsageServer.reset([.status(401)])
        let keychain = ScriptedKeychain([.success(credentialsJSON(token: "rejected", expiresAt: .now.addingTimeInterval(3_600)))])
        let monitor = makeMonitor(keychain: keychain)

        _ = await monitor.refreshAndScheduleNext()
        let afterFirst = StubUsageServer.requests
        _ = await monitor.refreshAndScheduleNext()

        #expect(monitor.problem?.isSignIn == true)
        #expect(afterFirst == 1)
        #expect(StubUsageServer.requests == afterFirst)
    }

    @Test func `Keeps the last data without alarm while Anthropic throttles`() async {
        StubUsageServer.reset([.status(200, body: StubUsageServer.usageBody), .status(429)])
        let keychain = ScriptedKeychain([.success(credentialsJSON(token: "t", expiresAt: .now.addingTimeInterval(3_600)))])
        let monitor = makeMonitor(keychain: keychain)

        _ = await monitor.refreshAndScheduleNext()
        _ = await monitor.refreshAndScheduleNext()

        #expect(monitor.problem == .rateLimited)
        #expect(!monitor.needsAttention)
        #expect(monitor.snapshot?.session?.usedPercent == 13)
        #expect(monitor.nextAttempt != nil)
    }

    @Test func `Retries soon without counting a missing connection as a failure`() async throws {
        StubUsageServer.reset([.status(200, body: StubUsageServer.usageBody), .failure(.notConnectedToInternet)])
        let keychain = ScriptedKeychain([.success(credentialsJSON(token: "t", expiresAt: .now.addingTimeInterval(3_600)))])
        let monitor = makeMonitor(keychain: keychain)

        _ = await monitor.refreshAndScheduleNext()
        let delay = await monitor.refreshAndScheduleNext()

        #expect(monitor.problem == .offline)
        #expect(!monitor.needsAttention)
        #expect(delay <= RefreshSchedule.offlineRetry)
    }

    @Test func `Asks for attention when there is no data at all`() async {
        StubUsageServer.reset([.status(429)])
        let keychain = ScriptedKeychain([.success(credentialsJSON(token: "t", expiresAt: .now.addingTimeInterval(3_600)))])
        let monitor = makeMonitor(keychain: keychain)

        _ = await monitor.refreshAndScheduleNext()

        #expect(monitor.problem == .rateLimited)
        #expect(monitor.needsAttention)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

// MARK: - Notification permission

private final class PermissionBox: @unchecked Sendable {
    private let lock = Mutex(UNAuthorizationStatus.denied)
    var status: UNAuthorizationStatus {
        get { lock.withLock { $0 } }
        set { lock.withLock { $0 = newValue } }
    }
}

@MainActor
struct NotificationPermissionTests {
    private let store = TestDefaults()

    @Test func `Notices permission given in System Settings meanwhile`() async throws {
        let settings = AppSettings(defaults: store.defaults)
        settings.notificationsEnabled = true
        let box = PermissionBox()
        let notifier = UsageNotifier(settings: settings, defaults: store.defaults, authorizationStatus: { box.status })
        await notifier.refreshAuthorization()
        #expect(notifier.authorization == .denied)

        box.status = .authorized
        notifier.evaluate(UsageSnapshot(
            session: UsageWindowInfo(id: "session", usedPercent: 5, resetsAt: nil),
            weekly: nil, scopedWeekly: [], breakdown: [], planName: nil
        ))
        for _ in 0..<200 where notifier.authorization != .authorized {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(notifier.authorization == .authorized)
    }
}

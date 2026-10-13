import Foundation
import Synchronization
import Testing
@testable import ClaudeRing

/// Keychain stand-in that hands out queued results and counts reads.
private actor FakeKeychain: KeychainReading {
    private var results: [Result<Data, CredentialError>]
    private(set) var reads = 0

    init(_ results: [Result<Data, CredentialError>]) {
        self.results = results
    }

    func readSecret() async throws -> Data {
        reads += 1
        return try (results.count > 1 ? results.removeFirst() : results[0]).get()
    }
}

private final class TestClock: Sendable {
    private let current: Mutex<Date>

    init(_ date: Date = Date(timeIntervalSince1970: 1_000_000)) {
        current = Mutex(date)
    }

    var now: Date { current.withLock { $0 } }

    func advance(by seconds: TimeInterval) {
        current.withLock { $0 = $0.addingTimeInterval(seconds) }
    }
}

private func credentialsJSON(token: String, expiresAt: Date?) -> Data {
    let expiry = expiresAt.map { ", \"expiresAt\": \(Int($0.timeIntervalSince1970 * 1000))" } ?? ""
    return Data("""
    { "claudeAiOauth": { "accessToken": "\(token)"\(expiry), "subscriptionType": "max" } }
    """.utf8)
}

private let missingFile = URL(filePath: "/nonexistent/credentials.json")

struct SecurityToolOutputTests {
    @Test func `Returns JSON output without the trailing newline`() {
        let secret = SecurityToolOutput.secret(from: Data("{\"a\":1}\n".utf8))
        #expect(secret == Data("{\"a\":1}".utf8))
    }

    @Test func `Decodes hex output`() {
        let secret = SecurityToolOutput.secret(from: Data("7b2261223a317d\n".utf8))
        #expect(secret == Data("{\"a\":1}".utf8))
    }

    @Test func `Keeps text that is not hex`() {
        let secret = SecurityToolOutput.secret(from: Data("not-hex\n".utf8))
        #expect(secret == Data("not-hex".utf8))
    }

    @Test func `Rejects empty output`() {
        #expect(SecurityToolOutput.secret(from: Data("\n".utf8)) == nil)
    }
}

struct CredentialRedactionTests {
    private let oauth = ClaudeCredentials.OAuth(
        accessToken: "sk-ant-secret", expiresAt: nil, subscriptionType: "max", rateLimitTier: nil
    )

    @Test func `Never prints the token`() {
        var dumped = ""
        dump(oauth, to: &dumped)

        #expect(String(describing: oauth) == "<redacted>")
        #expect(String(reflecting: oauth) == "<redacted>")
        #expect(!"\(oauth)".contains("secret"))
        #expect(!dumped.contains("secret"))
    }
}

struct CredentialProviderTests {
    @Test func `Reads the keychain only once while the token is valid`() async throws {
        let clock = TestClock()
        let keychain = FakeKeychain([.success(credentialsJSON(token: "a", expiresAt: clock.now.addingTimeInterval(3600)))])
        let provider = CredentialProvider(keychain: keychain, fallbackFileURL: missingFile, now: { clock.now })

        _ = try await provider.credentials()
        clock.advance(by: 600)
        let second = try await provider.credentials()

        #expect(second.accessToken == "a")
        #expect(await keychain.reads == 1)
    }

    @Test func `Reloads an expired token, but at most once per interval`() async throws {
        let clock = TestClock()
        let keychain = FakeKeychain([
            .success(credentialsJSON(token: "old", expiresAt: clock.now.addingTimeInterval(120))),
            .success(credentialsJSON(token: "old", expiresAt: clock.now.addingTimeInterval(120))),
            .success(credentialsJSON(token: "new", expiresAt: clock.now.addingTimeInterval(7200))),
        ])
        let provider = CredentialProvider(keychain: keychain, fallbackFileURL: missingFile, now: { clock.now })

        _ = try await provider.credentials()
        clock.advance(by: 90) // within 60 s of expiry → expired, and the last read is 90 s ago
        #expect(try await provider.credentials().accessToken == "old")
        clock.advance(by: 30) // only 30 s since the last read
        #expect(try await provider.credentials().accessToken == "old")
        #expect(await keychain.reads == 2)

        clock.advance(by: 60)
        #expect(try await provider.credentials().accessToken == "new")
        #expect(await keychain.reads == 3)
    }

    @Test func `Hands out a newer token after a rejection`() async throws {
        let clock = TestClock()
        let keychain = FakeKeychain([
            .success(credentialsJSON(token: "old", expiresAt: nil)),
            .success(credentialsJSON(token: "new", expiresAt: nil)),
        ])
        let provider = CredentialProvider(keychain: keychain, fallbackFileURL: missingFile, now: { clock.now })

        _ = try await provider.credentials()
        clock.advance(by: 61)
        let replacement = try await provider.credentials(replacingRejected: "old")

        #expect(replacement?.accessToken == "new")
    }

    @Test func `Returns nil when the keychain still holds the rejected token`() async throws {
        let clock = TestClock()
        let keychain = FakeKeychain([.success(credentialsJSON(token: "old", expiresAt: nil))])
        let provider = CredentialProvider(keychain: keychain, fallbackFileURL: missingFile, now: { clock.now })

        _ = try await provider.credentials()
        #expect(try await provider.credentials(replacingRejected: "old") == nil) // throttled, no read
        clock.advance(by: 61)
        #expect(try await provider.credentials(replacingRejected: "old") == nil)
        #expect(await keychain.reads == 2)
    }

    @Test func `Falls back to the credentials file when the keychain has no item`() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "credentials-\(UUID()).json")
        try credentialsJSON(token: "from-file", expiresAt: nil).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let provider = CredentialProvider(keychain: FakeKeychain([.failure(.notFound)]), fallbackFileURL: file)

        #expect(try await provider.credentials().accessToken == "from-file")
    }

    @Test func `Reports malformed data`() async {
        let provider = CredentialProvider(keychain: FakeKeychain([.success(Data("{}".utf8))]), fallbackFileURL: missingFile)

        await #expect(throws: CredentialError.malformed) {
            try await provider.credentials()
        }
    }

    @Test func `Reports a missing login`() async {
        let provider = CredentialProvider(keychain: FakeKeychain([.failure(.notFound)]), fallbackFileURL: missingFile)

        await #expect(throws: CredentialError.notFound) {
            try await provider.credentials()
        }
    }
}

struct RetryAfterTests {
    private let now = Date(timeIntervalSince1970: 1_760_000_000)

    @Test func `Parses delay seconds`() {
        #expect(UsageAPIClient.retryAfter("120", now: now) == .seconds(120))
    }

    @Test func `Parses an HTTP date`() {
        let header = "Thu, 09 Oct 2025 08:54:20 GMT" // 1_760_000_060
        #expect(UsageAPIClient.retryAfter(header, now: now) == .seconds(60))
    }

    @Test(arguments: [nil, "", "soon"])
    func `Ignores missing or invalid values`(header: String?) {
        #expect(UsageAPIClient.retryAfter(header, now: now) == nil)
    }
}

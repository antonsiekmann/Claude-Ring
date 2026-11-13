import Foundation

/// The JSON blob Claude Code stores in the login keychain under the
/// service name "Claude Code-credentials".
struct ClaudeCredentials: Decodable {
    var claudeAiOauth: OAuth

    struct OAuth: Decodable, Sendable, Equatable {
        var accessToken: String
        /// Milliseconds since 1970.
        var expiresAt: Double?
        var subscriptionType: String?
        var rateLimitTier: String?

        var expiryDate: Date? {
            expiresAt.map { Date(timeIntervalSince1970: $0 / 1000) }
        }
    }
}

// Keep the token out of logs, `print` and debugger summaries.
extension ClaudeCredentials.OAuth: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String { "<redacted>" }
    var debugDescription: String { "<redacted>" }
    var customMirror: Mirror { Mirror(self, children: [:]) }
}

enum CredentialError: LocalizedError, Equatable {
    case notFound
    case accessDenied
    case timedOut
    case keychainFailure(Int32)
    case malformed
    /// Claude Code hasn't renewed its token yet; it does so when it runs.
    case expired

    var errorDescription: String? {
        switch self {
        case .notFound:
            String(localized: "Keine Claude-Code-Anmeldung gefunden. Bitte einmal „claude“ im Terminal starten und anmelden.")
        case .accessDenied:
            String(localized: "Zugriff auf den Schlüsselbund wurde verweigert.")
        case .timedOut:
            String(localized: "Der Schlüsselbund hat nicht rechtzeitig geantwortet.")
        case .keychainFailure(let status):
            String(localized: "Schlüsselbund-Fehler (\(status)).")
        case .malformed:
            String(localized: "Die gespeicherten Claude-Code-Zugangsdaten konnten nicht gelesen werden.")
        case .expired:
            String(localized: "Das Claude-Code-Token ist abgelaufen. Bitte einmal „claude“ im Terminal starten, damit es erneuert wird.")
        }
    }
}

/// Reads the raw secret Claude Code stored in the keychain.
protocol KeychainReading: Sendable {
    func readSecret() async throws -> Data
}

/// Reads the secret through `/usr/bin/security`. Claude Code creates and
/// updates its keychain item with that tool, so the tool is on the item's
/// access list and macOS does not ask for the keychain password, no matter
/// how often this app is rebuilt or Claude Code rewrites the item.
struct SecurityToolKeychainReader: KeychainReading {
    static let serviceName = "Claude Code-credentials"
    /// `security` exits with 44 (errSecItemNotFound) when there is no item.
    private static let itemNotFoundStatus: Int32 = 44

    var timeout: Duration = .seconds(30)

    func readSecret() async throws -> Data {
        let timeout = timeout
        return try await Task.detached(priority: .utility) {
            try Self.runSecurityTool(timeout: timeout)
        }.value
    }

    private static func runSecurityTool(timeout: Duration) throws -> Data {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", serviceName, "-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()

        // Stop the tool if macOS shows a keychain dialog that nobody answers.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout.timeInterval) {
            if process.isRunning { process.terminate() }
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        if process.terminationReason == .uncaughtSignal {
            throw CredentialError.timedOut
        }
        switch process.terminationStatus {
        case 0:
            guard let secret = SecurityToolOutput.secret(from: data) else { throw CredentialError.malformed }
            return secret
        case itemNotFoundStatus:
            throw CredentialError.notFound
        case let status:
            throw CredentialError.keychainFailure(status)
        }
    }
}

/// Tells whether Claude Code has stored a login, without reading the secret.
protocol LoginChecking: Sendable {
    func hasLogin() async -> Bool
}

/// Asks `security` only for the attributes of Claude Code's keychain item.
/// Attributes never need the keychain password, so unlike reading the secret
/// this can run every few seconds without ever showing a dialog.
struct SecurityToolLoginChecker: LoginChecking {
    var fallbackFileURL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/.credentials.json")

    func hasLogin() async -> Bool {
        let fallbackFileURL = fallbackFileURL
        return await Task.detached(priority: .utility) {
            if FileManager.default.fileExists(atPath: fallbackFileURL.path) { return true }
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/security")
            process.arguments = ["find-generic-password", "-s", SecurityToolKeychainReader.serviceName]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return false }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10) {
                if process.isRunning { process.terminate() }
            }
            process.waitUntilExit()
            return process.terminationReason == .exit && process.terminationStatus == 0
        }.value
    }
}

enum SecurityToolOutput {
    /// Turns the stdout of `security find-generic-password -w` into the stored
    /// bytes. The tool prints printable secrets as text and everything else as
    /// a hex string, always followed by a newline.
    static func secret(from output: Data) -> Data? {
        guard let text = String(data: output, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty
        else { return nil }

        if text.hasPrefix("{") { return Data(text.utf8) }
        return hexDecoded(text) ?? Data(text.utf8)
    }

    private static func hexDecoded(_ text: String) -> Data? {
        let digits = Array(text.utf8)
        guard digits.count.isMultiple(of: 2) else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(digits.count / 2)
        for index in stride(from: 0, to: digits.count, by: 2) {
            guard let high = hexValue(digits[index]), let low = hexValue(digits[index + 1]) else { return nil }
            bytes.append(high << 4 | low)
        }
        return Data(bytes)
    }

    private static func hexValue(_ digit: UInt8) -> UInt8? {
        switch digit {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): digit - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): digit - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): digit - UInt8(ascii: "A") + 10
        default: nil
        }
    }
}

/// Hands out the OAuth token that Claude Code keeps on this Mac.
///
/// The token lives only in memory. The keychain is read again only when the
/// cached token has expired or the API rejected it, and at most once per
/// `minimumReloadInterval`. The app never writes or refreshes the token;
/// Claude Code keeps it current.
actor CredentialProvider {
    private let keychain: any KeychainReading
    private let fallbackFileURL: URL
    private let minimumReloadInterval: Duration
    private let now: @Sendable () -> Date

    private var cached: ClaudeCredentials.OAuth?
    private var lastReload: Date?

    init(
        keychain: any KeychainReading = SecurityToolKeychainReader(),
        fallbackFileURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".claude/.credentials.json"),
        minimumReloadInterval: Duration = .seconds(60),
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.keychain = keychain
        self.fallbackFileURL = fallbackFileURL
        self.minimumReloadInterval = minimumReloadInterval
        self.now = now
    }

    func credentials() async throws -> ClaudeCredentials.OAuth {
        if let cached, !Self.isExpired(cached, at: now()) {
            return cached
        }
        if let cached, reloadedRecently {
            // Just read: a token past its expiry would only earn a 401.
            if Self.hasExpired(cached, at: now()) { throw CredentialError.expired }
            return cached
        }
        return try await reload()
    }

    /// Call after the API rejected `token`. Returns newer credentials when the
    /// keychain holds a different token by now, otherwise nil.
    func credentials(replacingRejected token: String) async throws -> ClaudeCredentials.OAuth? {
        if let cached, cached.accessToken != token { return cached }
        guard !reloadedRecently else { return nil }
        let fresh = try await reload()
        return fresh.accessToken == token ? nil : fresh
    }

    nonisolated static func isExpired(_ credentials: ClaudeCredentials.OAuth, at date: Date) -> Bool {
        guard let expiry = credentials.expiryDate else { return false }
        return expiry.addingTimeInterval(-60) <= date
    }

    /// Past the expiry itself, without the margin of `isExpired`.
    nonisolated static func hasExpired(_ credentials: ClaudeCredentials.OAuth, at date: Date) -> Bool {
        guard let expiry = credentials.expiryDate else { return false }
        return expiry <= date
    }

    private var reloadedRecently: Bool {
        guard let lastReload else { return false }
        return now().timeIntervalSince(lastReload) < minimumReloadInterval.timeInterval
    }

    private func reload() async throws -> ClaudeCredentials.OAuth {
        lastReload = now()
        let data: Data
        do {
            data = try await keychain.readSecret()
        } catch CredentialError.notFound {
            // Claude Code falls back to this file when the keychain is unavailable.
            guard let fileData = try? Data(contentsOf: fallbackFileURL) else { throw CredentialError.notFound }
            data = fileData
        }

        let decoded: ClaudeCredentials
        do {
            decoded = try JSONDecoder().decode(ClaudeCredentials.self, from: data)
        } catch {
            throw CredentialError.malformed
        }
        cached = decoded.claudeAiOauth
        if Self.hasExpired(decoded.claudeAiOauth, at: now()) {
            throw CredentialError.expired
        }
        return decoded.claudeAiOauth
    }
}

extension Duration {
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}

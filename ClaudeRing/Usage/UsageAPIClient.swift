import Foundation

enum UsageAPIError: LocalizedError {
    case invalidResponse
    case unauthorized
    case rateLimited(retryAfter: Duration?)
    case httpStatus(Int)
    case decoding(Error)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "Ungültige Antwort vom Server."
        case .unauthorized:
            "Das Claude-Code-Token ist abgelaufen oder ungültig. Bitte einmal „claude“ im Terminal starten, damit es erneuert wird."
        case .rateLimited:
            "Anthropic begrenzt gerade die Abfragen der Nutzung. Angezeigt wird der letzte Stand."
        case .httpStatus(let code):
            "Server antwortete mit HTTP \(code)."
        case .decoding(let error):
            "Antwort konnte nicht gelesen werden: \(error.localizedDescription)"
        }
    }
}

/// The endpoint never redirects; refusing redirects guarantees the token is
/// only ever sent to api.anthropic.com.
private final class RefuseRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = RefuseRedirects()

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}

/// Fetches the usage limits of the signed-in Claude account.
/// Uses the same endpoint Claude Code's `/usage` command relies on.
struct UsageAPIClient: Sendable {
    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")

    private let session: URLSession

    /// The default session is ephemeral: no response cache or cookies on disk.
    init(session: URLSession = URLSession(configuration: .ephemeral)) {
        self.session = session
    }

    func fetchUsage(accessToken: String) async throws -> UsageResponse {
        guard let url = Self.usageURL else { throw UsageAPIError.invalidResponse }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        // OAuth tokens are only accepted together with this beta header.
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request, delegate: RefuseRedirects.shared)
        guard let http = response as? HTTPURLResponse else { throw UsageAPIError.invalidResponse }

        switch http.statusCode {
        case 200:
            break
        case 401, 403:
            throw UsageAPIError.unauthorized
        case 429:
            throw UsageAPIError.rateLimited(
                retryAfter: Self.retryAfter(http.value(forHTTPHeaderField: "Retry-After"), now: .now)
            )
        default:
            throw UsageAPIError.httpStatus(http.statusCode)
        }

        do {
            return try Self.makeDecoder().decode(UsageResponse.self, from: data)
        } catch {
            throw UsageAPIError.decoding(error)
        }
    }

    /// Parses a `Retry-After` header, which is either a number of seconds or
    /// an HTTP date.
    static func retryAfter(_ header: String?, now: Date) -> Duration? {
        guard let header = header?.trimmingCharacters(in: .whitespaces), !header.isEmpty else { return nil }
        if let seconds = Int(header) {
            return .seconds(max(0, seconds))
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: header) else { return nil }
        return .seconds(max(0, date.timeIntervalSince(now).rounded(.up)))
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            // The API mixes timestamps with and without fractional seconds.
            if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string) {
                return date
            }
            if let date = try? Date.ISO8601FormatStyle().parse(string) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unerwartetes Datumsformat: \(string)")
        }
        return decoder
    }
}

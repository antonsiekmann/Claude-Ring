import Foundation

/// The newest published release, reduced to what the updater needs.
struct AppRelease: Equatable, Sendable {
    let version: AppVersion
    /// The release page with the change notes.
    let pageURL: URL
    /// The DMG; nil when the release has none or GitHub lists no checksum
    /// for it. Then only the release page is offered.
    let download: Download?

    struct Download: Equatable, Sendable {
        let url: URL
        /// SHA-256 of the DMG as lowercase hex, as GitHub reports it.
        let sha256: String
        let size: Int
    }
}

enum ReleaseClientError: LocalizedError {
    case invalidResponse
    case noRelease
    case rateLimited
    case httpStatus(Int)
    case unknownVersion(String)
    case decoding(Error)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "Ungültige Antwort von GitHub."
        case .noRelease:
            "Auf GitHub gibt es noch keine veröffentlichte Version."
        case .rateLimited:
            "GitHub begrenzt gerade die Abfragen. Bitte später noch einmal versuchen."
        case .httpStatus(let code):
            "GitHub antwortete mit HTTP \(code)."
        case .unknownVersion(let tag):
            "Die neueste Version auf GitHub („\(tag)“) hat kein bekanntes Format."
        case .decoding(let error):
            "Antwort von GitHub konnte nicht gelesen werden: \(error.localizedDescription)"
        }
    }
}

/// Asks GitHub for the newest release of Claude Ring. Unauthenticated; GitHub
/// allows 60 such requests per hour, the app needs one a day.
struct ReleaseClient: Sendable {
    static let repository = "antonsiekmann/Claude-Ring"
    /// The release workflow uploads the DMG under this name in every release.
    static let assetName = "ClaudeRing.dmg"
    private static let latestURL = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")

    private let session: URLSession

    init(session: URLSession = URLSession(configuration: .ephemeral)) {
        self.session = session
    }

    func latestRelease() async throws -> AppRelease {
        guard let url = Self.latestURL else { throw ReleaseClientError.invalidResponse }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ReleaseClientError.invalidResponse }

        switch http.statusCode {
        case 200:
            return try Self.parse(data)
        case 404:
            throw ReleaseClientError.noRelease
        case 403, 429:
            throw ReleaseClientError.rateLimited
        default:
            throw ReleaseClientError.httpStatus(http.statusCode)
        }
    }

    /// Reads the response of `GET /repos/{owner}/{repo}/releases/latest`.
    static func parse(_ data: Data) throws -> AppRelease {
        let release: GitHubRelease
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            release = try decoder.decode(GitHubRelease.self, from: data)
        } catch {
            throw ReleaseClientError.decoding(error)
        }
        guard let version = AppVersion(release.tagName) else {
            throw ReleaseClientError.unknownVersion(release.tagName)
        }

        let download = release.assets.first { $0.name == assetName }.flatMap { asset -> AppRelease.Download? in
            // Only downloads from github.com over HTTPS, and only with a checksum.
            guard asset.browserDownloadUrl.scheme == "https", asset.browserDownloadUrl.host() == "github.com",
                  let sha256 = sha256Hex(fromDigest: asset.digest)
            else { return nil }
            return AppRelease.Download(url: asset.browserDownloadUrl, sha256: sha256, size: asset.size)
        }
        return AppRelease(version: version, pageURL: release.htmlUrl, download: download)
    }

    /// GitHub reports asset checksums as `sha256:<64 hex digits>`.
    static func sha256Hex(fromDigest digest: String?) -> String? {
        guard let digest, digest.hasPrefix("sha256:") else { return nil }
        let hex = digest.dropFirst("sha256:".count).lowercased()
        guard hex.count == 64, hex.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        return hex
    }

    private struct GitHubRelease: Decodable {
        let tagName: String
        let htmlUrl: URL
        let assets: [Asset]

        struct Asset: Decodable {
            let name: String
            let browserDownloadUrl: URL
            let digest: String?
            let size: Int
        }
    }
}

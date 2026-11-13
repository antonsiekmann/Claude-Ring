import Foundation

/// A folder in the temporary directory that is deleted together with this
/// object. Keep it in a stored property of the test suite: Swift Testing
/// creates the suite anew for every test and releases it afterwards.
final class TemporaryFolder {
    let url: URL

    init(_ prefix: String = "ClaudeRingTests") {
        url = FileManager.default.temporaryDirectory.appending(path: "\(prefix)-\(UUID())", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

/// UserDefaults for a single test, stored in a temporary folder.
///
/// A suite named only by a UUID lands in ~/Library/Preferences, and macOS
/// writes an empty plist for it again after the process exits, even when the
/// test removed the domain. A suite named by an absolute path is stored at
/// that path instead, so nothing piles up in the user's preferences.
final class TestDefaults {
    let defaults: UserDefaults
    private let folder = TemporaryFolder("ClaudeRingDefaults")

    init() {
        defaults = UserDefaults(suiteName: folder.url.appending(path: "defaults").path)!
    }
}

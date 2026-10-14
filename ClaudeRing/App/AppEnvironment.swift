import Foundation

enum AppEnvironment {
    /// True while the app only serves as the host for unit tests. The app then
    /// skips everything with side effects: status item, polling, keychain
    /// access, notifications.
    static let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    /// Whether the app runs from „Programme“ (`/Applications` or
    /// `~/Applications`), not from Xcode's build folder or a translocated copy.
    static func isInstalled(
        bundleURL: URL = Bundle.main.bundleURL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        let path = bundleURL.path
        return path.hasPrefix("/Applications/") || path.hasPrefix(home.path + "/Applications/")
    }
}

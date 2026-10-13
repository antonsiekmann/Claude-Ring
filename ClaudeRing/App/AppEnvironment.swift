import Foundation

enum AppEnvironment {
    /// True while the app only serves as the host for unit tests. The app then
    /// skips everything with side effects: status item, polling, keychain
    /// access, notifications.
    static let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
}

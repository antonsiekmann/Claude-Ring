import Foundation
import Testing
@testable import ClaudeRing

@MainActor
struct WelcomePolicyTests {
    private let store = TestDefaults()

    @Test func `Shows the window on the first launch`() {
        let settings = AppSettings(defaults: store.defaults)

        #expect(WelcomePolicy.shouldShow(settings: settings, loginItemEnabled: false, hasUsageData: false))
        #expect(settings.completedWelcomeVersion == nil)
    }

    @Test func `Does not show the window again once finished`() {
        let settings = AppSettings(defaults: store.defaults)
        settings.completedWelcomeVersion = WelcomePolicy.currentVersion

        #expect(!WelcomePolicy.shouldShow(settings: settings, loginItemEnabled: false, hasUsageData: false))
    }

    @Test func `Shows a newer welcome window to people who finished an older one`() {
        let settings = AppSettings(defaults: store.defaults)
        settings.completedWelcomeVersion = WelcomePolicy.currentVersion - 1

        #expect(WelcomePolicy.shouldShow(settings: settings, loginItemEnabled: true, hasUsageData: true))
    }

    @Test(arguments: [(true, false), (false, true)])
    func `Skips the window for people who used the app before it existed`(signs: (Bool, Bool)) {
        let settings = AppSettings(defaults: store.defaults)

        #expect(!WelcomePolicy.shouldShow(settings: settings, loginItemEnabled: signs.0, hasUsageData: signs.1))
        #expect(settings.completedWelcomeVersion == WelcomePolicy.currentVersion)
        #expect(AppSettings(defaults: store.defaults).completedWelcomeVersion == WelcomePolicy.currentVersion)
    }
}

private final class FakeLoginChecker: LoginChecking, @unchecked Sendable {
    var hasLoginValue = false
    func hasLogin() async -> Bool { hasLoginValue }
}

@MainActor
struct WelcomeModelTests {
    private let folder = TemporaryFolder("welcome-model")

    private func makeModel(checker: FakeLoginChecker, claudeCodeInstalled: Bool = true, onSignedIn: @escaping () -> Void = {}) -> WelcomeModel {
        WelcomeModel(
            installer: HookInstaller(paths: .init(home: folder.url)),
            launchAtLogin: LaunchAtLogin(),
            loginChecker: checker,
            claudeCodeInstalled: { claudeCodeInstalled },
            needsMove: false,
            onSignedIn: onSignedIn
        )
    }

    @Test func `Reports a signed-in Claude Code`() async {
        let checker = FakeLoginChecker()
        checker.hasLoginValue = true
        let model = makeModel(checker: checker)

        await model.checkLogin()

        #expect(model.login == .signedIn)
    }

    @Test func `Tells a missing login apart from a missing Claude Code`() async {
        let installed = makeModel(checker: FakeLoginChecker(), claudeCodeInstalled: true)
        let missing = makeModel(checker: FakeLoginChecker(), claudeCodeInstalled: false)

        await installed.checkLogin()
        await missing.checkLogin()

        #expect(installed.login == .signedOut)
        #expect(missing.login == .claudeCodeMissing)
    }

    @Test func `Fetches the usage once when the login appears`() async {
        let checker = FakeLoginChecker()
        var fetches = 0
        let model = makeModel(checker: checker, onSignedIn: { fetches += 1 })

        await model.checkLogin()
        checker.hasLoginValue = true
        await model.checkLogin()
        await model.checkLogin()

        #expect(model.login == .signedIn)
        #expect(fetches == 1)
    }

    @Test func `Does not fetch again when the login was there from the start`() async {
        let checker = FakeLoginChecker()
        checker.hasLoginValue = true
        var fetches = 0
        let model = makeModel(checker: checker, onSignedIn: { fetches += 1 })

        await model.checkLogin()

        #expect(fetches == 0)
    }

    @Test func `Sets up the status dot with one click`() throws {
        let settingsFile = folder.url.appending(path: ".claude/settings.json")
        try FileManager.default.createDirectory(at: settingsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: settingsFile)
        let model = makeModel(checker: FakeLoginChecker())
        #expect(model.hasPendingSetup)

        model.setUp()

        #expect(model.statusDotDone)
        #expect(!model.hasPendingSetup)
    }

    @Test func `Leaves the hooks alone when the box is unchecked`() {
        let model = makeModel(checker: FakeLoginChecker())
        model.setsUpStatusDot = false

        model.setUp()

        #expect(!model.statusDotDone)
        #expect(!model.hasPendingSetup)
    }
}

struct AppMoverTests {
    private let folder = TemporaryFolder("app-mover")
    private let fileManager = FileManager.default

    private func makeApp(at url: URL, version: String, quarantined: Bool = false) throws {
        let contents = url.appending(path: "Contents", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: contents.appending(path: "MacOS"), withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "eu.siekmann.ClaudeRing", "CFBundleShortVersionString": version]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appending(path: "Info.plist"))
        try Data("binary \(version)".utf8).write(to: contents.appending(path: "MacOS/ClaudeRing"))
        if quarantined {
            for path in [url.path, contents.appending(path: "MacOS/ClaudeRing").path] {
                let value = "0083;00000000;Safari;"
                #expect(setxattr(path, "com.apple.quarantine", value, value.utf8.count, 0, XATTR_NOFOLLOW) == 0)
            }
        }
    }

    private func isQuarantined(_ url: URL) -> Bool {
        getxattr(url.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) >= 0
    }

    private func version(of app: URL) -> String? {
        NSDictionary(contentsOf: app.appending(path: "Contents/Info.plist"))?["CFBundleShortVersionString"] as? String
    }

    @Test func `Copies the app into the folder without quarantine`() throws {
        let source = folder.url.appending(path: "Volume/Claude Ring.app", directoryHint: .isDirectory)
        try makeApp(at: source, version: "1.2.0", quarantined: true)
        let applications = folder.url.appending(path: "Applications", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: applications, withIntermediateDirectories: true)

        let installed = try AppMover.install(from: source, into: [applications], verify: { _ in })

        #expect(installed == applications.appending(path: "Claude Ring.app", directoryHint: .isDirectory))
        #expect(version(of: installed) == "1.2.0")
        #expect(!isQuarantined(installed))
        #expect(!isQuarantined(installed.appending(path: "Contents/MacOS/ClaudeRing")))
        #expect(try fileManager.contentsOfDirectory(atPath: applications.path) == ["Claude Ring.app"])
    }

    @Test func `Replaces an older copy`() throws {
        let source = folder.url.appending(path: "Volume/Claude Ring.app", directoryHint: .isDirectory)
        try makeApp(at: source, version: "1.2.0")
        let applications = folder.url.appending(path: "Applications", directoryHint: .isDirectory)
        try makeApp(at: applications.appending(path: "Claude Ring.app"), version: "1.0.0")

        let installed = try AppMover.install(from: source, into: [applications], verify: { _ in })

        #expect(version(of: installed) == "1.2.0")
        #expect(try fileManager.contentsOfDirectory(atPath: applications.path) == ["Claude Ring.app"])
    }

    @Test func `Replaces a copy of the same version, which may still be in quarantine`() throws {
        let source = folder.url.appending(path: "Volume/Claude Ring.app", directoryHint: .isDirectory)
        try makeApp(at: source, version: "1.2.0")
        let applications = folder.url.appending(path: "Applications", directoryHint: .isDirectory)
        let existing = applications.appending(path: "Claude Ring.app", directoryHint: .isDirectory)
        try makeApp(at: existing, version: "1.2.0", quarantined: true)

        let installed = try AppMover.install(from: source, into: [applications], verify: { _ in })

        #expect(!isQuarantined(installed))
        #expect(!isQuarantined(installed.appending(path: "Contents/MacOS/ClaudeRing")))
    }

    @Test func `Keeps a newer copy`() throws {
        let source = folder.url.appending(path: "Volume/Claude Ring.app", directoryHint: .isDirectory)
        try makeApp(at: source, version: "1.2.0")
        let applications = folder.url.appending(path: "Applications", directoryHint: .isDirectory)
        try makeApp(at: applications.appending(path: "Claude Ring.app"), version: "2.0.0")

        let installed = try AppMover.install(from: source, into: [applications], verify: { _ in })

        #expect(version(of: installed) == "2.0.0")
    }

    @Test func `Falls back to the next folder when the first is not writable`() throws {
        let source = folder.url.appending(path: "Volume/Claude Ring.app", directoryHint: .isDirectory)
        try makeApp(at: source, version: "1.2.0")
        let locked = folder.url.appending(path: "Locked", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: locked, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        let personal = folder.url.appending(path: "Home/Applications", directoryHint: .isDirectory)

        let installed = try AppMover.install(from: source, into: [locked, personal], verify: { _ in })

        #expect(installed.deletingLastPathComponent().standardizedFileURL == personal.standardizedFileURL)
        #expect(version(of: installed) == "1.2.0")
    }

    @Test func `Leaves nothing behind when the signature check fails`() throws {
        let source = folder.url.appending(path: "Volume/Claude Ring.app", directoryHint: .isDirectory)
        try makeApp(at: source, version: "1.2.0")
        let applications = folder.url.appending(path: "Applications", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: applications, withIntermediateDirectories: true)

        #expect(throws: AppMover.MoveError.self) {
            try AppMover.install(from: source, into: [applications], verify: { _ in throw AppMover.MoveError.invalidCopy })
        }
        #expect(try fileManager.contentsOfDirectory(atPath: applications.path).isEmpty)
    }
}

struct ClaudeCodeInstallationTests {
    private let folder = TemporaryFolder("claude-installation")

    @Test func `Finds Claude Code by its config file`() throws {
        #expect(!ClaudeCodeInstallation.isInstalled(home: folder.url, systemPaths: []))
        try Data("{}".utf8).write(to: folder.url.appending(path: ".claude.json"))

        #expect(ClaudeCodeInstallation.isInstalled(home: folder.url, systemPaths: []))
    }

    @Test func `Finds the command line tool in the home folder`() throws {
        let tool = folder.url.appending(path: ".local/bin/claude")
        try FileManager.default.createDirectory(at: tool.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: tool)

        #expect(ClaudeCodeInstallation.isInstalled(home: folder.url, systemPaths: []))
    }

    @Test func `Does not count the folder this app creates for its hooks`() throws {
        try FileManager.default.createDirectory(at: folder.url.appending(path: ".claude"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: folder.url.appending(path: ".claude/settings.json"))

        #expect(!ClaudeCodeInstallation.isInstalled(home: folder.url, systemPaths: []))
    }
}

@MainActor
struct WelcomeVersionStorageTests {
    @Test func `Reads the version given as text on the command line`() {
        let store = TestDefaults()
        store.defaults.set("0", forKey: "completedWelcomeVersion")

        #expect(AppSettings(defaults: store.defaults).completedWelcomeVersion == 0)
    }
}

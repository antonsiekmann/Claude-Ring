import Foundation
import Testing
@testable import ClaudeRing

struct AppVersionTests {
    @Test(arguments: [
        ("1.2.3", "1.2.3"), ("v1.2.3", "1.2.3"), ("1.2", "1.2.0"), ("2", "2.0.0"), (" 1.10.0 ", "1.10.0"),
    ])
    func `Reads release tags and bundle versions`(text: String, expected: String) {
        #expect(AppVersion(text)?.description == expected)
    }

    @Test(arguments: ["", "v", "1.2.3.4", "1.2.0-beta", "1..2", "a.b.c", "+1.2.3", "1.-2.3", "V1.2.3"])
    func `Rejects anything else`(text: String) {
        #expect(AppVersion(text) == nil)
    }

    @Test func `Compares numerically, not as text`() {
        #expect(AppVersion("1.10.0")! > AppVersion("1.9.9")!)
        #expect(AppVersion("2.0.0")! > AppVersion("1.99.99")!)
        #expect(AppVersion("1.0.1")! > AppVersion("1.0.0")!)
        #expect(AppVersion("v1.2")! == AppVersion("1.2.0")!)
    }
}

struct ReleaseClientTests {
    private func json(tag: String = "v1.1.0", assets: String? = nil) -> Data {
        let assets = assets ?? #"""
        [ { "name": "ClaudeRing-1.1.0.dmg", "size": 10,
            "browser_download_url": "https://github.com/antonsiekmann/Claude-Ring/releases/download/v1.1.0/ClaudeRing-1.1.0.dmg",
            "digest": "sha256:1111111111111111111111111111111111111111111111111111111111111111" },
          { "name": "ClaudeRing.dmg", "size": 3073344,
            "browser_download_url": "https://github.com/antonsiekmann/Claude-Ring/releases/download/v1.1.0/ClaudeRing.dmg",
            "digest": "sha256:659EFCD3CA3F449808DBAE6E222B5BAA3641F6AFA6F32C9E769CC1BBAC1497B4" } ]
        """#
        return Data(#"""
        { "tag_name": "\#(tag)", "name": "Claude Ring 1.1.0", "draft": false, "prerelease": false,
          "html_url": "https://github.com/antonsiekmann/Claude-Ring/releases/tag/\#(tag)",
          "body": "**Full Changelog**: …", "assets": \#(assets) }
        """#.utf8)
    }

    @Test func `Reads version, page and the DMG with its checksum`() throws {
        let release = try ReleaseClient.parse(json())

        #expect(release.version == AppVersion("1.1.0"))
        #expect(release.pageURL.absoluteString == "https://github.com/antonsiekmann/Claude-Ring/releases/tag/v1.1.0")
        let download = try #require(release.download)
        #expect(download.url.lastPathComponent == "ClaudeRing.dmg")
        #expect(download.sha256 == "659efcd3ca3f449808dbae6e222b5baa3641f6afa6f32c9e769cc1bbac1497b4")
        #expect(download.size == 3_073_344)
    }

    @Test func `Offers no download without a checksum`() throws {
        let release = try ReleaseClient.parse(json(assets: #"""
        [ { "name": "ClaudeRing.dmg", "size": 1, "digest": null,
            "browser_download_url": "https://github.com/antonsiekmann/Claude-Ring/releases/download/v1.1.0/ClaudeRing.dmg" } ]
        """#))
        #expect(release.download == nil)
    }

    @Test func `Offers no download from other hosts`() throws {
        let release = try ReleaseClient.parse(json(assets: #"""
        [ { "name": "ClaudeRing.dmg", "size": 1,
            "digest": "sha256:659efcd3ca3f449808dbae6e222b5baa3641f6afa6f32c9e769cc1bbac1497b4",
            "browser_download_url": "http://example.com/ClaudeRing.dmg" } ]
        """#))
        #expect(release.download == nil)
    }

    @Test func `Offers no download when the DMG is missing`() throws {
        #expect(try ReleaseClient.parse(json(assets: "[]")).download == nil)
    }

    @Test func `Rejects tags that are not versions`() {
        #expect(throws: ReleaseClientError.self) {
            try ReleaseClient.parse(json(tag: "nightly"))
        }
    }

    @Test(arguments: [
        ("sha256:" + String(repeating: "ab", count: 32), String(repeating: "ab", count: 32)),
        ("sha256:" + String(repeating: "AB", count: 32), String(repeating: "ab", count: 32)),
    ])
    func `Reads GitHub digests`(digest: String, expected: String) {
        #expect(ReleaseClient.sha256Hex(fromDigest: digest) == expected)
    }

    @Test(arguments: [
        nil, "", "sha256:", "sha256:abc", "md5:" + String(repeating: "a", count: 64),
        "sha256:" + String(repeating: "g", count: 64), "sha256:" + String(repeating: "a", count: 65),
    ] as [String?])
    func `Ignores broken digests`(digest: String?) {
        #expect(ReleaseClient.sha256Hex(fromDigest: digest) == nil)
    }
}

struct UpdateInstallerTests {
    private let root: URL
    private let fileManager = FileManager.default

    init() throws {
        root = fileManager.temporaryDirectory.appending(path: "update-\(UUID())", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func makeApp(
        named name: String = "Claude Ring.app",
        in directory: URL? = nil,
        identifier: String = "eu.siekmann.ClaudeRing",
        version: String = "1.1.0",
        minimumSystem: String? = "26.0"
    ) throws -> URL {
        let app = (directory ?? root).appending(path: name, directoryHint: .isDirectory)
        try fileManager.createDirectory(at: app.appending(path: "Contents"), withIntermediateDirectories: true)
        var info: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleShortVersionString": version]
        info["LSMinimumSystemVersion"] = minimumSystem
        try (info as NSDictionary).write(to: app.appending(path: "Contents/Info.plist"))
        return app
    }

    private var installer: UpdateInstaller {
        UpdateInstaller(appURL: root.appending(path: "Installed.app"), bundleIdentifier: "eu.siekmann.ClaudeRing")
    }

    @Test func `Accepts the announced version of the same app`() throws {
        try installer.validate(makeApp(), version: #require(AppVersion("1.1.0")))
    }

    @Test func `Rejects another app or another version`() throws {
        let version = try #require(AppVersion("1.1.0"))
        #expect(throws: UpdateInstallError.self) {
            try installer.validate(makeApp(named: "A.app", identifier: "com.example.Other"), version: version)
        }
        #expect(throws: UpdateInstallError.self) {
            try installer.validate(makeApp(named: "B.app", version: "1.0.9"), version: version)
        }
    }

    @Test func `Rejects an app that needs a newer macOS`() throws {
        let app = try makeApp(minimumSystem: "99.0")
        let error = #expect(throws: UpdateInstallError.self) {
            try installer.validate(app, version: AppVersion("1.1.0")!)
        }
        guard case .requiresNewerSystem("99.0") = error else {
            Issue.record("Unexpected error: \(String(describing: error))")
            return
        }
    }

    @Test func `Rejects a missing app or a symlink in its place`() throws {
        let version = try #require(AppVersion("1.1.0"))
        let real = try makeApp(named: "Real.app")
        let link = root.appending(path: "Link.app")
        try fileManager.createSymbolicLink(at: link, withDestinationURL: real)

        #expect(throws: UpdateInstallError.self) { try installer.validate(link, version: version) }
        #expect(throws: UpdateInstallError.self) {
            try installer.validate(root.appending(path: "Missing.app"), version: version)
        }
    }

    @Test func `Computes SHA-256 as lowercase hex`() throws {
        let file = root.appending(path: "abc")
        try Data("abc".utf8).write(to: file)
        #expect(try UpdateInstaller.sha256Hex(of: file) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func `Replaces only installed, writable copies`() throws {
        let home = root.appending(path: "home", directoryHint: .isDirectory)
        let applications = home.appending(path: "Applications", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: applications, withIntermediateDirectories: true)
        let installed = try makeApp(in: applications)
        let elsewhere = try makeApp(in: home)

        #expect(UpdateInstaller.canReplace(appURL: installed, home: home))
        #expect(!UpdateInstaller.canReplace(appURL: elsewhere, home: home))

        try fileManager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: applications.path)
        defer { try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: applications.path) }
        #expect(!UpdateInstaller.canReplace(appURL: installed, home: home))
    }

    @Test func `Knows installed copies from builds elsewhere`() {
        let home = URL(filePath: "/Users/me", directoryHint: .isDirectory)
        #expect(AppEnvironment.isInstalled(bundleURL: URL(filePath: "/Applications/Claude Ring.app"), home: home))
        #expect(AppEnvironment.isInstalled(bundleURL: URL(filePath: "/Users/me/Applications/Claude Ring.app"), home: home))
        #expect(!AppEnvironment.isInstalled(bundleURL: URL(filePath: "/Users/me/Downloads/Claude Ring.app"), home: home))
        #expect(!AppEnvironment.isInstalled(
            bundleURL: URL(filePath: "/private/var/folders/x/AppTranslocation/1/d/Claude Ring.app"), home: home
        ))
    }

    /// Downloads the published DMG and installs it over a stand-in, with
    /// everything but the relaunch. Needs the network, so it only runs with
    /// `TEST_RUNNER_UPDATE_E2E=1`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["UPDATE_E2E"] == "1"))
    func `Installs the latest release over an existing app`() async throws {
        let release = try await ReleaseClient().latestRelease()
        let download = try #require(release.download)
        let target = try makeApp(named: "Claude Ring.app", version: "0.0.1")

        try await UpdateInstaller(appURL: target, bundleIdentifier: "eu.siekmann.ClaudeRing")
            .install(download, version: release.version)

        let info = try #require(NSDictionary(contentsOf: target.appending(path: "Contents/Info.plist")))
        #expect(info["CFBundleShortVersionString"] as? String == release.version.description)
        #expect(fileManager.fileExists(atPath: target.appending(path: "Contents/MacOS/ClaudeRing").path))
        #expect(try fileManager.contentsOfDirectory(atPath: root.path) == ["Claude Ring.app"])
    }
}

@MainActor
struct AppUpdaterTests {
    private func makeDefaults() -> UserDefaults {
        let name = "AppUpdaterTests-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private let release = AppRelease(
        version: AppVersion("1.1.0")!,
        pageURL: URL(string: "https://github.com/antonsiekmann/Claude-Ring/releases/tag/v1.1.0")!,
        download: nil
    )

    @Test func `Hides a release put off with Später, also after a restart`() {
        let defaults = makeDefaults()
        let settings = AppSettings(defaults: defaults)
        let updater = AppUpdater(settings: settings, defaults: defaults, currentVersion: AppVersion("1.0.0"))
        updater.showPreview(release: release)
        #expect(updater.showsBanner)

        updater.dismiss()
        #expect(!updater.showsBanner)

        let restarted = AppUpdater(settings: settings, defaults: defaults, currentVersion: AppVersion("1.0.0"))
        restarted.showPreview(release: release)
        #expect(!restarted.showsBanner)

        let newer = AppRelease(version: AppVersion("1.2.0")!, pageURL: release.pageURL, download: nil)
        restarted.showPreview(release: newer)
        #expect(restarted.showsBanner)
    }

    @Test func `Checks for updates and announces them by default`() {
        let settings = AppSettings(defaults: makeDefaults())
        #expect(settings.checksForUpdates)
        #expect(settings.notifiesAboutUpdates)
    }
}

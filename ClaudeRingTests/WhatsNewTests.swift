import Foundation
import Testing
@testable import ClaudeRing

struct ChangelogTests {
    private static let sample = """
    # Änderungen

    Ein Abschnitt pro Version.

    ## 1.2.0

    ### Neu

    - Ein Fenster, das über
      zwei Zeilen geht.
    - Mit `code` und **fett**.

    ### Behoben

    - Ein Fehler.

    ## Unveröffentlicht

    - Kommt noch.

    ## 1.1.0

    - Ohne Gruppe.
    """

    @Test func `Reads versions, groups and bullets`() {
        let changelog = Changelog(markdown: Self.sample)

        #expect(changelog.releases.map(\.version.description) == ["1.2.0", "1.1.0"])
        #expect(changelog.releases[0].groups == [
            .init(title: "Neu", items: ["Ein Fenster, das über zwei Zeilen geht.", "Mit `code` und **fett**."]),
            .init(title: "Behoben", items: ["Ein Fehler."]),
        ])
        #expect(changelog.releases[1].groups == [.init(title: nil, items: ["Ohne Gruppe."])])
    }

    @Test func `Picks the versions since the last one`() {
        let changelog = Changelog(markdown: """
        ## 1.2.4
        - d
        ## 1.2.3
        - c
        ## 1.2.2
        - b
        ## 1.2.1
        - a
        """)

        let since = changelog.releases(after: AppVersion("1.2.1"), upTo: AppVersion("1.2.3")!)
        #expect(since.map(\.version.description) == ["1.2.3", "1.2.2"])
        // Unknown old version: only the new one.
        #expect(changelog.releases(after: nil, upTo: AppVersion("1.2.4")!).map(\.version.description) == ["1.2.4"])
    }

    @Test func `Ships the changelog inside the app`() throws {
        let file = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "CHANGELOG.md")
        let fromRepository = Changelog(markdown: try String(contentsOf: file, encoding: .utf8))

        #expect(!Changelog.bundled.releases.isEmpty)
        #expect(Changelog.bundled == fromRepository)
    }
}

@MainActor
struct WhatsNewPolicyTests {
    private let store = TestDefaults()

    private func settings(lastLaunched: String? = nil, welcomeDone: Bool = true) -> AppSettings {
        let settings = AppSettings(defaults: store.defaults)
        settings.lastLaunchedVersion = lastLaunched
        settings.completedWelcomeVersion = welcomeDone ? WelcomePolicy.currentVersion : nil
        return settings
    }

    @Test func `Shows the changes after an update`() {
        let settings = settings(lastLaunched: "1.2.3")

        let update = WhatsNewPolicy.update(settings: settings, current: AppVersion("1.2.5"))
        #expect(update == .init(from: AppVersion("1.2.3"), to: AppVersion("1.2.5")!))
        #expect(settings.lastLaunchedVersion == "1.2.5")
        // Only once.
        #expect(WhatsNewPolicy.update(settings: settings, current: AppVersion("1.2.5")) == nil)
    }

    @Test func `Stays quiet after a fresh install`() {
        let settings = settings(welcomeDone: false)

        #expect(WhatsNewPolicy.update(settings: settings, current: AppVersion("1.2.4")) == nil)
        #expect(settings.lastLaunchedVersion == "1.2.4")
    }

    @Test func `Shows the new version after an update from before the record existed`() {
        let settings = settings(lastLaunched: nil, welcomeDone: true)

        #expect(WhatsNewPolicy.update(settings: settings, current: AppVersion("1.2.4")) == .init(from: nil, to: AppVersion("1.2.4")!))
    }

    @Test func `Keeps the highest version through a local build`() {
        let settings = settings(lastLaunched: "1.2.4")

        #expect(WhatsNewPolicy.update(settings: settings, current: AppVersion("1.0.0")) == nil)
        #expect(settings.lastLaunchedVersion == "1.2.4")
        #expect(WhatsNewPolicy.update(settings: settings, current: AppVersion("1.2.5")) == .init(from: AppVersion("1.2.4"), to: AppVersion("1.2.5")!))
    }
}

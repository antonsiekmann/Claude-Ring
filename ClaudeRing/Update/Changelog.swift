import Foundation

/// The release notes from CHANGELOG.md, which the app carries as a resource
/// for the window after an update. Works offline and needs no request to
/// GitHub.
struct Changelog: Equatable, Sendable {
    struct Group: Equatable, Sendable {
        /// The `###` heading, such as „Neu“; nil for notes without one.
        var title: String?
        /// One entry per bullet, as Markdown.
        var items: [String] = []
    }

    struct Release: Equatable, Identifiable, Sendable {
        let version: AppVersion
        var groups: [Group] = []
        var id: AppVersion { version }
    }

    /// Newest first, as in the file.
    let releases: [Release]

    init(releases: [Release]) {
        self.releases = releases
    }

    /// Reads `## 1.2.3` sections with optional `###` groups and `-` bullets;
    /// lines indented below a bullet continue it. Text above the first
    /// version and sections that are no version are left out.
    init(markdown: String) {
        var releases: [Release] = []
        var release: Release?
        var group: Group?
        var item: String?

        func finishItem() {
            if let text = item {
                group = group ?? Group(title: nil)
                group?.items.append(text)
            }
            item = nil
        }
        func finishGroup() {
            finishItem()
            if let group, !group.items.isEmpty {
                release?.groups.append(group)
            }
            group = nil
        }
        func finishRelease() {
            finishGroup()
            if let release, !release.groups.isEmpty {
                releases.append(release)
            }
            release = nil
        }

        for rawLine in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                finishRelease()
                release = AppVersion(String(line.dropFirst(3))).map { Release(version: $0) }
            } else if release == nil {
                continue
            } else if line.hasPrefix("### ") {
                finishGroup()
                group = Group(title: String(line.dropFirst(4)))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                finishItem()
                item = String(line.dropFirst(2))
            } else if line.isEmpty {
                finishItem()
            } else if let text = item {
                item = text + " " + line
            } else {
                // A paragraph without a bullet shows like an entry.
                item = line
            }
        }
        finishRelease()
        self.releases = releases
    }

    /// The notes after `old` up to and including `current`, newest first;
    /// only those of `current` when the old version is unknown.
    func releases(after old: AppVersion?, upTo current: AppVersion) -> [Release] {
        releases.filter { release in
            guard release.version <= current else { return false }
            guard let old else { return release.version == current }
            return release.version > old
        }
    }

    /// CHANGELOG.md from the app bundle; empty if it is missing.
    static let bundled: Changelog = {
        guard let url = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return Changelog(releases: []) }
        return Changelog(markdown: text)
    }()
}

import AppKit
import SwiftUI

/// The window after an update: the notes of the new version, and of any
/// versions skipped on the way, from CHANGELOG.md.
struct WhatsNewView: View {
    static let width: CGFloat = 520
    /// Longer notes scroll; shorter ones get a smaller window.
    static let maxNotesHeight: CGFloat = 420

    let version: AppVersion
    /// The version before the update; nil when unknown.
    let previous: AppVersion?
    let releases: [Changelog.Release]
    /// From `notesHeight(for:)`, measured once, so the window has its final
    /// size before it shows.
    let notesHeight: CGFloat
    let close: () -> Void

    @MainActor
    static func notesHeight(for releases: [Changelog.Release]) -> CGFloat {
        let probe = NSHostingController(rootView: ReleaseNotes(releases: releases).frame(width: width))
        let height = probe.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
        return min(height, maxNotesHeight)
    }

    var body: some View {
        VStack(spacing: 0) {
            Header(version: version, previous: releases.count > 1 ? previous : nil)
            ScrollView {
                ReleaseNotes(releases: releases)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: notesHeight)
            Divider()
            HStack {
                Link("Alle Versionen auf GitHub",
                     destination: URL(string: "https://github.com/\(ReleaseClient.repository)/releases")!)
                Spacer()
                Button("Weiter", action: close)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct Header: View {
    let version: AppVersion
    /// Named when the notes span several versions.
    let previous: AppVersion?

    var body: some View {
        HStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Neu in Claude Ring \(version.description)")
                    .font(.title2.weight(.semibold))
                Group {
                    if let previous {
                        Text("Das Update ist installiert. Das hat sich seit Version \(previous.description) geändert:")
                    } else {
                        Text("Das Update ist installiert. Das hat sich geändert:")
                    }
                }
                .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
        .padding(.top, 20)
        .padding(.bottom, 12)
    }
}

/// The notes laid out like the grouped forms of the other windows.
private struct ReleaseNotes: View {
    let releases: [Changelog.Release]

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            ForEach(releases) { release in
                VStack(alignment: .leading, spacing: 10) {
                    // With one version, the header already names it.
                    if releases.count > 1 {
                        Text("Version \(release.version.description)")
                            .font(.title3.weight(.semibold))
                            .padding(.leading, 10)
                    }
                    ForEach(release.groups.indices, id: \.self) { index in
                        NoteGroup(group: release.groups[index])
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 20)
    }
}

private struct NoteGroup: View {
    let group: Changelog.Group

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title = group.title {
                Text(title)
                    .font(.headline)
                    .padding(.leading, 10)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(group.items.indices, id: \.self) { index in
                    if index > 0 {
                        Divider()
                    }
                    Text(Self.formatted(group.items[index]))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 9)
                }
            }
            .padding(.horizontal, 10)
            .background(.quinary, in: .rect(cornerRadius: 10))
        }
    }

    /// Inline Markdown such as `code` and **bold**.
    private static func formatted(_ item: String) -> AttributedString {
        (try? AttributedString(markdown: item, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(item)
    }
}

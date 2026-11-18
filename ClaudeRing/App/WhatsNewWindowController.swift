import AppKit
import SwiftUI

/// Decides whether the window with the changes opens at launch.
@MainActor
enum WhatsNewPolicy {
    struct Update: Equatable {
        /// nil after an update from a version that did not record itself
        /// yet, 1.2.3 and older.
        let from: AppVersion?
        let to: AppVersion
    }

    /// Records the running version. Call once per launch, after the welcome
    /// policy, which records people who used the app before.
    ///
    /// - Returns: The update since the last launch; nil after a fresh
    ///   install, a reinstall of the same version or a downgrade.
    static func update(settings: AppSettings, current: AppVersion?) -> Update? {
        guard let current else { return nil }
        let last = settings.lastLaunchedVersion.flatMap(AppVersion.init)
        // Never lower: local builds report 1.0.0, and the next update should
        // still show only what is new since the last release.
        if last.map({ current > $0 }) ?? true {
            settings.lastLaunchedVersion = current.description
        }
        if let last {
            return current > last ? Update(from: last, to: current) : nil
        }
        // Without a record, a finished welcome window means the app ran
        // before. "Vollständig entfernen" clears both, so a reinstall gets
        // the welcome window instead.
        return settings.completedWelcomeVersion != nil ? Update(from: nil, to: current) : nil
    }
}

/// The window after an update that shows what has changed.
@MainActor
final class WhatsNewWindowController: NSWindowController, NSWindowDelegate {
    init(version: AppVersion, previous: AppVersion?, releases: [Changelog.Release]) {
        let notesHeight = WhatsNewView.notesHeight(for: releases)
        let host = NSHostingController(rootView: WhatsNewView(
            version: version, previous: previous, releases: releases, notesHeight: notesHeight, close: {}
        ))
        host.sizingOptions = .preferredContentSize
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable]
        window.title = String(localized: "Neu in Claude Ring")
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        super.init(window: window)
        window.delegate = self
        host.rootView = WhatsNewView(
            version: version, previous: previous, releases: releases, notesHeight: notesHeight,
            close: { [weak self] in self?.close() }
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show() {
        AppActivation.windowWillShow()
        window?.layoutIfNeeded()
        if window?.isVisible == false {
            window?.center()
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        // Activation is only a request; at login another app may stay active.
        window?.orderFrontRegardless()
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) {
        AppActivation.windowWillClose(window)
    }
}

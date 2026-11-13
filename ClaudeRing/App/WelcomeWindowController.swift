import AppKit
import OSLog
import SwiftUI

/// The welcome window at the first launch. It has a fixed size; the form
/// inside scrolls if it ever needs more room.
@MainActor
final class WelcomeWindowController: NSWindowController, NSWindowDelegate {
    private let model: WelcomeModel
    private let settings: AppSettings
    private let isIconVisible: () -> Bool
    private let showIcon: () -> Void
    private let logger = Logger(subsystem: "eu.siekmann.ClaudeRing", category: "welcome")

    init(model: WelcomeModel, settings: AppSettings, isIconVisible: @escaping () -> Bool, showIcon: @escaping () -> Void) {
        self.model = model
        self.settings = settings
        self.isIconVisible = isIconVisible
        self.showIcon = showIcon

        let host = NSHostingController(rootView: AnyView(EmptyView()))
        host.sizingOptions = []
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable]
        window.title = String(localized: "Willkommen bei Claude Ring")
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        super.init(window: window)
        window.delegate = self
        host.rootView = AnyView(WelcomeView(
            model: model,
            finish: { [weak self] in self?.finish() },
            later: { [weak self] in self?.close() }
        ))
        window.setContentSize(WelcomeView.size(needsMove: model.needsMove))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show() {
        AppActivation.windowWillShow()
        if window?.isVisible == false {
            window?.center()
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        // Activation is only a request; at login another app may stay active.
        window?.orderFrontRegardless()
        NSApp.activate()
        model.startWatchingLogin()
        logger.info("Welcome window shown")
    }

    /// "Fertig": closes the window and opens the popover at the menu bar icon,
    /// so people see where Claude Ring lives. If the icon is hidden, the
    /// window stays and explains why; a second click closes it anyway.
    private func finish() {
        if !isIconVisible(), !model.iconIsHidden {
            model.markIconHidden()
            return
        }
        let iconVisible = !model.iconIsHidden || isIconVisible()
        close()
        if iconVisible {
            showIcon()
        }
    }

    /// Closing counts as finished, also with "Später": the window doesn't
    /// come back by itself. Moving to „Programme“ quits without closing, so
    /// the copy there opens with the window again.
    func windowWillClose(_ notification: Notification) {
        model.stopWatchingLogin()
        settings.completedWelcomeVersion = WelcomePolicy.currentVersion
        AppActivation.windowWillClose(window)
    }
}

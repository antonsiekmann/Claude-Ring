import AppKit
import Observation
import QuartzCore
import SwiftUI

/// Owns the menu bar item. A left click toggles the popover, a right click
/// (or Control-click) opens a small menu.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let monitor: UsageMonitor
    private let settings: AppSettings
    private let sessions: ClaudeSessionStore
    private let openSettings: () -> Void
    private let checkForUpdates: () -> Void
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var displayTask: Task<Void, Never>?
    private var renderedDisplay: MenuBarDisplay?
    private var appearanceObservation: NSKeyValueObservation?
    private var accessibilityObserver: NSObjectProtocol?
    private var powerStateObserver: NSObjectProtocol?
    /// The pulsing dot while Claude Code works. Core Animation runs the
    /// animation in the window server, so the app does not wake up for it.
    private var pulseLayer: CAShapeLayer?
    /// A click on the status item while the popover is open first closes the
    /// transient popover on mouse-down; the action on mouse-up must then not
    /// open it again.
    private var popoverClosedAt: Date?

    init(
        monitor: UsageMonitor,
        settings: AppSettings,
        sessions: ClaudeSessionStore,
        updater: AppUpdater,
        openSettings: @escaping () -> Void,
        checkForUpdates: @escaping () -> Void
    ) {
        self.monitor = monitor
        self.settings = settings
        self.sessions = sessions
        self.openSettings = openSettings
        self.checkForUpdates = checkForUpdates
        super.init()

        statusItem.autosaveName = "ClaudeRing"
        if let button = statusItem.button {
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(handleClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            // The image draws lazily, but redraw anyway when the menu bar
            // switches between light and dark.
            appearanceObservation = button.observe(\.effectiveAppearance) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.redraw() }
            }
        }

        // Low Power Mode switches the pulsing off.
        powerStateObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name.NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.redraw() }
        }

        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.redraw() }
        }

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let hostingController = NSHostingController(rootView: UsagePopoverView(
            monitor: monitor,
            settings: settings,
            sessions: sessions,
            updater: updater,
            openSettings: { [weak self] in self?.openSettingsFromPopover() }
        ))
        hostingController.sizingOptions = .preferredContentSize
        popover.contentViewController = hostingController

        observeDisplay()
    }

    /// Takes the item out of the menu bar for good.
    func remove() {
        displayTask?.cancel()
        appearanceObservation = nil
        if let accessibilityObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver)
        }
        if let powerStateObserver {
            NotificationCenter.default.removeObserver(powerStateObserver)
        }
        pulseLayer?.removeFromSuperlayer()
        popover.performClose(nil)
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    // MARK: - Menu bar image

    private func observeDisplay() {
        let monitor = monitor
        let settings = settings
        let sessions = sessions
        displayTask = Task { [weak self] in
            let displays = Observations {
                MenuBarDisplay.make(
                    snapshot: monitor.snapshot,
                    hasError: monitor.errorMessage != nil,
                    preferences: MenuBarDisplay.Preferences(
                        style: settings.menuBarStyle,
                        limit: settings.menuBarLimit,
                        value: settings.menuBarValue,
                        colorsRing: settings.colorsRing,
                        showsStatusDot: settings.showsStatusDot
                    ),
                    activity: sessions.aggregate
                )
            }
            for await display in displays {
                self?.render(display)
            }
        }
    }

    private func render(_ display: MenuBarDisplay) {
        guard display != renderedDisplay else { return }
        renderedDisplay = display
        redraw()
    }

    private func redraw() {
        guard let display = renderedDisplay, let button = statusItem.button else { return }
        let pulses = Self.shouldPulse(display)
        button.image = MenuBarIconRenderer.image(
            for: display,
            differentiateWithoutColor: NSWorkspace.shared.accessibilityDisplayShouldDifferentiateWithoutColor,
            drawsDot: !pulses
        )
        button.setAccessibilityLabel(display.accessibilityLabel)
        updatePulse(pulses ? display : nil, in: button)
    }

    /// Only "working" pulses, and not with Reduce Motion or in Low Power Mode.
    private static func shouldPulse(_ display: MenuBarDisplay) -> Bool {
        display.activity == .working
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            && !ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    private func updatePulse(_ display: MenuBarDisplay?, in button: NSStatusBarButton) {
        guard let display, let activity = display.activity, let dot = MenuBarIconRenderer.dotRect(for: display),
              let imageSize = button.image?.size
        else {
            pulseLayer?.removeFromSuperlayer()
            pulseLayer = nil
            return
        }

        button.wantsLayer = true
        button.layoutSubtreeIfNeeded()
        let imageRect = button.cell?.imageRect(forBounds: button.bounds)
            ?? NSRect(x: (button.bounds.width - imageSize.width) / 2, y: (button.bounds.height - imageSize.height) / 2,
                      width: imageSize.width, height: imageSize.height)
        // The dot is centered vertically, so the frame works in flipped and
        // unflipped coordinates alike.
        let frame = NSRect(x: imageRect.minX + dot.minX, y: imageRect.midY - dot.height / 2, width: dot.width, height: dot.height)

        let layer = pulseLayer ?? makePulseLayer(in: button)
        var color: CGColor?
        button.effectiveAppearance.performAsCurrentDrawingAppearance {
            color = activity.nsColor.cgColor
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = frame
        layer.path = CGPath(ellipseIn: CGRect(origin: .zero, size: frame.size), transform: nil)
        layer.fillColor = color
        layer.contentsScale = button.window?.backingScaleFactor ?? 2
        CATransaction.commit()
    }

    private func makePulseLayer(in button: NSStatusBarButton) -> CAShapeLayer {
        let layer = CAShapeLayer()
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0.3
        let shrink = CABasicAnimation(keyPath: "transform.scale")
        shrink.fromValue = 1
        shrink.toValue = 0.7
        let pulse = CAAnimationGroup()
        pulse.animations = [fade, shrink]
        pulse.duration = 0.9
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(pulse, forKey: "pulse")
        button.layer?.addSublayer(layer)
        pulseLayer = layer
        return layer
    }

    // MARK: - Clicks

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        if let popoverClosedAt, Date.now.timeIntervalSince(popoverClosedAt) < 0.3 {
            return
        }
        monitor.refreshIfStale()
        // An accessory app must be active, or clicks outside won't close the popover.
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        button.highlight(true)
    }

    func popoverDidClose(_ notification: Notification) {
        popoverClosedAt = .now
        statusItem.button?.highlight(false)
    }

    /// macOS 27 menus show icons only for a few standard items, so these
    /// items have none.
    private func showMenu() {
        let menu = NSMenu()
        let settingsItem = NSMenuItem(title: String(localized: "Einstellungen …"), action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        let refresh = NSMenuItem(title: String(localized: "Jetzt aktualisieren"), action: #selector(refreshNow), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)
        let updates = NSMenuItem(title: String(localized: "Nach Updates suchen …"), action: #selector(showUpdates), keyEquivalent: "")
        updates.target = self
        menu.addItem(updates)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: String(localized: "Claude Ring beenden"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func refreshNow() {
        monitor.refreshNow()
    }

    @objc private func showSettings() {
        openSettings()
    }

    @objc private func showUpdates() {
        checkForUpdates()
    }

    private func openSettingsFromPopover() {
        popover.performClose(nil)
        openSettings()
    }
}

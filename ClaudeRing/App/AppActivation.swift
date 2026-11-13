import AppKit

/// The app appears in the Dock and the app switcher only while one of its
/// windows is open; otherwise it lives in the menu bar alone.
@MainActor
enum AppActivation {
    static func windowWillShow() {
        NSApp.setActivationPolicy(.regular)
    }

    /// Call from `windowWillClose`. Another open window, such as the settings
    /// next to the welcome window, keeps the app in the Dock.
    static func windowWillClose(_ closing: NSWindow?) {
        let othersOpen = NSApp.windows.contains { window in
            window !== closing && window.isVisible && window.styleMask.contains(.titled)
        }
        if !othersOpen {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

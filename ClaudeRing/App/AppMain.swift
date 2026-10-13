import AppKit

/// AppKit entry point. The app lives in the menu bar only: no Dock icon, no
/// SwiftUI scenes. Its windows (popover, settings) host SwiftUI content.
@main
@MainActor
enum AppMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}

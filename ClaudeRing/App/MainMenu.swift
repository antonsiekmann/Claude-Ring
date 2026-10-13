import AppKit

/// The main menu exists only for the settings window: while it is open the
/// app becomes a regular app, and without a main menu standard shortcuts like
/// ⌘C, ⌘V or ⌘W would do nothing.
@MainActor
enum MainMenu {
    static func make(settingsAction: Selector, target: AnyObject) -> NSMenu {
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Claude Ring"
        let mainMenu = NSMenu()

        let appMenu = NSMenu(title: appName)
        appMenu.addItem(withTitle: String(localized: "Über \(appName)"),
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settings = appMenu.addItem(withTitle: String(localized: "Einstellungen …"), action: settingsAction, keyEquivalent: ",")
        settings.target = target
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(localized: "\(appName) ausblenden"),
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(localized: "\(appName) beenden"),
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        mainMenu.addItem(submenu: appMenu)

        let editMenu = NSMenu(title: String(localized: "Bearbeiten"))
        editMenu.addItem(withTitle: String(localized: "Widerrufen"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: String(localized: "Wiederholen"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: String(localized: "Ausschneiden"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: String(localized: "Kopieren"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: String(localized: "Einsetzen"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: String(localized: "Alles auswählen"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        mainMenu.addItem(submenu: editMenu)

        let windowMenu = NSMenu(title: String(localized: "Fenster"))
        windowMenu.addItem(withTitle: String(localized: "Schließen"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: String(localized: "Im Dock ablegen"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        mainMenu.addItem(submenu: windowMenu)
        NSApp.windowsMenu = windowMenu

        return mainMenu
    }
}

private extension NSMenu {
    func addItem(submenu: NSMenu) {
        let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }
}

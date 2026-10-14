import AppKit
import Observation

/// Removes the app and everything it added, then quits.
///
/// Claude Code itself, its login and every setting that is not ours stay
/// untouched. If the hooks cannot be taken out of Claude Code's settings,
/// nothing is removed at all, so the user can fix the file and try again.
@MainActor
@Observable
final class AppUninstaller {
    private(set) var lastError: String?

    /// Stops polling, file watching and the menu bar item before files go away.
    @ObservationIgnored var stopApp: () -> Void = {}

    @ObservationIgnored private let footprint: AppFootprint
    @ObservationIgnored private let hookInstaller: HookInstaller
    @ObservationIgnored private let launchAtLogin: LaunchAtLogin
    @ObservationIgnored private let notifier: UsageNotifier
    @ObservationIgnored private let terminate: () -> Void
    @ObservationIgnored private var isUninstalling = false

    init(
        footprint: AppFootprint,
        hookInstaller: HookInstaller,
        launchAtLogin: LaunchAtLogin,
        notifier: UsageNotifier,
        terminate: @escaping () -> Void = { NSApp.terminate(nil) }
    ) {
        self.footprint = footprint
        self.hookInstaller = hookInstaller
        self.launchAtLogin = launchAtLogin
        self.notifier = notifier
        self.terminate = terminate
    }

    /// Only an installed copy moves itself to the Trash; a build in Xcode's
    /// build folder stays where it is.
    var trashesApp: Bool { launchAtLogin.isAvailable }

    var summary: String {
        var items = [
            String(localized: "die Claude-Code-Hooks aus „~/.claude/settings.json“ (alles andere darin bleibt)"),
            String(localized: "Hook-Skript, Sitzungsdaten und Sicherungen"),
            String(localized: "alle Einstellungen der App"),
            String(localized: "das Anmeldeobjekt und die Mitteilungen der App"),
            String(localized: "Caches, gespeicherte Fensterzustände und Reste abgebrochener Updates"),
        ]
        if trashesApp {
            items.append(String(localized: "die App selbst (in den Papierkorb)"))
        }
        return String(localized: "Entfernt werden \(items.formatted()). Claude Code und seine Anmeldung bleiben unverändert.")
    }

    func uninstall() {
        lastError = nil
        do {
            try hookInstaller.removeHooksFromSettings()
        } catch {
            lastError = String(localized: "Die Hooks konnten nicht aus „~/.claude/settings.json“ entfernt werden, deshalb wurde nichts gelöscht. \(error.localizedDescription)")
            return
        }

        stopApp()
        if launchAtLogin.isEnabled || launchAtLogin.requiresApproval {
            launchAtLogin.setEnabled(false)
        }
        notifier.removeAllNotifications()
        footprint.removeItems(includingPreferencesFile: false, settingsDirectories: settingsDirectories)
        if trashesApp {
            try? FileManager.default.trashItem(at: Bundle.main.bundleURL, resultingItemURL: nil)
        }

        isUninstalling = true
        terminate()
    }

    /// Called from `applicationWillTerminate`, when nothing writes anymore:
    /// removes the preferences and whatever macOS saved while quitting.
    func finishTermination() {
        guard isUninstalling else { return }
        UserDefaults.standard.removePersistentDomain(forName: footprint.bundleIdentifier)
        CFPreferencesAppSynchronize(footprint.bundleIdentifier as CFString)
        footprint.removeItems(includingPreferencesFile: true, settingsDirectories: settingsDirectories)
        Self.launchPreferencesCleanup(for: footprint.preferencesFile)
    }

    /// The preferences daemon writes an empty preferences file a few seconds
    /// after the domain was cleared, when the app has already quit. A small
    /// shell that outlives the app removes that empty file; a file with
    /// content, for example from a reinstall in the meantime, stays.
    nonisolated static let preferencesCleanupScript = #"""
    for i in $(/usr/bin/seq "$2"); do
      /bin/sleep 1
      if [ -f "$1" ] && [ "$(/usr/bin/plutil -convert json -o - "$1" 2>/dev/null)" = "{}" ]; then
        /bin/rm -f "$1"
      fi
    done
    """#

    nonisolated static func launchPreferencesCleanup(for file: URL, seconds: Int = 30) {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", preferencesCleanupScript, "cleanup", file.path, String(seconds)]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    /// `~/.claude` and, if settings.json is a symlink, the folder it points into.
    private var settingsDirectories: [URL] {
        let link = hookInstaller.paths.claudeSettings
        return [link.deletingLastPathComponent(), link.resolvingSymlinksInPath().deletingLastPathComponent()]
    }
}

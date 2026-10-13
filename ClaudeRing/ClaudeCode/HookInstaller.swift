import Foundation
import Observation

enum HookInstallerError: LocalizedError {
    case invalidSettings
    case settingsChanged

    var errorDescription: String? {
        switch self {
        case .invalidSettings:
            "„~/.claude/settings.json“ ist kein gültiges JSON. Die App ändert die Datei deshalb nicht."
        case .settingsChanged:
            "Claude Code hat seine Einstellungen gerade geändert. Bitte noch einmal versuchen."
        }
    }
}

/// Installs the hook script and registers it in Claude Code's settings, on
/// request only. Before every change it backs up the settings file.
@MainActor
@Observable
final class HookInstaller {
    enum Status: Equatable {
        case notInstalled
        case installed
        /// Our entries exist, but the script or the registrations are outdated.
        case needsUpdate
    }

    struct Paths: Sendable {
        let appSupport: URL
        let script: URL
        let sessions: URL
        let backups: URL
        let claudeSettings: URL

        init(home: URL) {
            appSupport = home.appending(path: "Library/Application Support/ClaudeRing", directoryHint: .isDirectory)
            script = appSupport.appending(path: "claude-ring-hook.sh")
            sessions = appSupport.appending(path: "Sessions", directoryHint: .isDirectory)
            backups = appSupport.appending(path: "Backups", directoryHint: .isDirectory)
            claudeSettings = home.appending(path: ".claude/settings.json")
        }

        static var standard: Paths { Paths(home: FileManager.default.homeDirectoryForCurrentUser) }
    }

    private(set) var status: Status = .notInstalled
    private(set) var lastError: String?
    private(set) var lastBackup: URL?

    @ObservationIgnored let paths: Paths
    @ObservationIgnored private let fileManager = FileManager.default

    init(paths: Paths = .standard) {
        self.paths = paths
        refresh()
    }

    func refresh() {
        guard let settings = try? readSettings() else {
            status = .notInstalled
            return
        }
        if HookSettingsMerger.isInstalled(in: settings) && isScriptCurrent {
            status = .installed
        } else if HookSettingsMerger.containsOurs(in: settings) {
            status = .needsUpdate
        } else {
            status = .notInstalled
        }
    }

    func install() {
        perform {
            try installScript()
            try updateSettings { HookSettingsMerger.installing(into: $0) }
        }
    }

    func uninstall() {
        perform {
            try updateSettings { HookSettingsMerger.removing(from: $0) }
            try? fileManager.removeItem(at: paths.script)
            try? fileManager.removeItem(at: paths.sessions)
        }
    }

    /// Takes our entries out of Claude Code's settings and reports failures to
    /// the caller instead of showing them. Used by the complete removal.
    func removeHooksFromSettings() throws {
        defer { refresh() }
        try updateSettings { HookSettingsMerger.removing(from: $0) }
    }

    /// Keeps an existing installation working after an app update by
    /// rewriting an outdated script. Never touches Claude Code's settings.
    func repairScriptIfNeeded() {
        guard let settings = try? readSettings(), HookSettingsMerger.containsOurs(in: settings), !isScriptCurrent else { return }
        perform { try installScript() }
    }

    // MARK: - Script

    private var isScriptCurrent: Bool {
        (try? String(contentsOf: paths.script, encoding: .utf8)) == HookScript.contents
            && fileManager.isExecutableFile(atPath: paths.script.path)
    }

    private func installScript() throws {
        for directory in [paths.appSupport, paths.sessions] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try Data(HookScript.contents.utf8).write(to: paths.script, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.script.path)
    }

    // MARK: - Claude Code settings

    /// A symlinked settings file (for example from a dotfiles repository) is
    /// edited at its destination instead of being replaced by a copy.
    private var settingsURL: URL { paths.claudeSettings.resolvingSymlinksInPath() }

    private func readSettings() throws -> OrderedJSON {
        guard fileManager.fileExists(atPath: settingsURL.path) else { return .object([]) }
        do {
            return try OrderedJSON(parsing: Data(contentsOf: settingsURL))
        } catch is OrderedJSON.ParseError {
            throw HookInstallerError.invalidSettings
        }
    }

    private func updateSettings(_ transform: (OrderedJSON) -> OrderedJSON) throws {
        let url = settingsURL
        let original = try readIfPresent(url)
        let permissions = original == nil ? 0o600
            : (try fileManager.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0o600

        let current: OrderedJSON
        do {
            current = try original.map { try OrderedJSON(parsing: $0) } ?? .object([])
        } catch {
            throw HookInstallerError.invalidSettings
        }
        let updated = transform(current)
        guard updated != current else { return }

        if let original {
            lastBackup = try backUp(original)
        } else {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
        }

        var text = updated.serialized()
        if original == nil || original?.last == UInt8(ascii: "\n") {
            text += "\n"
        }
        // Claude Code may have written the file since it was read.
        guard try readIfPresent(url) == original else {
            throw HookInstallerError.settingsChanged
        }
        try writeAtomically(Data(text.utf8), to: url, permissions: permissions)
    }

    private func readIfPresent(_ url: URL) throws -> Data? {
        fileManager.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
    }

    /// Writes a temporary file that has its final permissions from the start
    /// (the settings may contain secrets) and renames it into place.
    private func writeAtomically(_ data: Data, to url: URL, permissions: Int) throws {
        let temporary = url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).\(UUID().uuidString)")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(permissions & 0o777))
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            guard rename(temporary.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } catch {
            unlink(temporary.path)
            throw error
        }
    }

    /// Keeps the newest few backups; they are full copies of the settings.
    private static let backupLimit = 5

    private func backUp(_ data: Data) throws -> URL {
        try fileManager.createDirectory(at: paths.backups, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let stamp = Date.now.formatted(.iso8601.year().month().day().dateSeparator(.omitted)
            .time(includingFractionalSeconds: false).timeSeparator(.omitted))
        let url = paths.backups.appending(path: "settings-\(stamp)-\(UUID().uuidString.prefix(6)).json")
        try writeAtomically(data, to: url, permissions: 0o600)

        let backups = try fileManager.contentsOfDirectory(at: paths.backups, includingPropertiesForKeys: [.creationDateKey])
            .filter { $0.lastPathComponent.hasPrefix("settings-") }
            .sorted { lhs, rhs in
                let left = (try? lhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let right = (try? rhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return (left, lhs.lastPathComponent) < (right, rhs.lastPathComponent)
            }
        for old in backups.dropLast(Self.backupLimit) where old != url {
            try? fileManager.removeItem(at: old)
        }
        return url
    }

    private func perform(_ work: () throws -> Void) {
        do {
            try work()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }
}

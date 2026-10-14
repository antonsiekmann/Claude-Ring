import Foundation

/// Everything the app, or macOS on its behalf, creates outside the app bundle.
/// Used to remove all of it on request.
struct AppFootprint: Sendable {
    let home: URL
    let bundleIdentifier: String
    /// The earlier Swift package build had no bundle identifier; macOS stored
    /// its caches under the executable name instead.
    let executableName: String

    static var current: AppFootprint {
        AppFootprint(
            home: FileManager.default.homeDirectoryForCurrentUser,
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "eu.siekmann.ClaudeRing",
            executableName: "ClaudeRing"
        )
    }

    private var library: URL { home.appending(path: "Library", directoryHint: .isDirectory) }

    var preferencesFile: URL {
        library.appending(path: "Preferences/\(bundleIdentifier).plist")
    }

    /// Work folders of running updates: download, mounted image, new app.
    /// An update removes its folder when it ends; after a crash or power loss
    /// the next launch does.
    var updatesDirectory: URL {
        library.appending(path: "Caches/\(bundleIdentifier)/Updates", directoryHint: .isDirectory)
    }

    /// Folders and files to delete: hook script, sessions and backups, caches,
    /// HTTP storage and saved window state.
    var items: [URL] {
        let names = [bundleIdentifier, executableName]
        return [HookInstaller.Paths(home: home).appSupport]
            + names.map { library.appending(path: "Caches/\($0)") }
            + names.map { library.appending(path: "HTTPStorages/\($0)") }
            + names.map { library.appending(path: "HTTPStorages/\($0).binarycookies") }
            + [library.appending(path: "Saved Application State/\(bundleIdentifier).savedState")]
    }

    /// Temporary files of an interrupted settings write, named
    /// `.settings.json.<UUID>`, in the given folders. Nothing else matches.
    func settingsTemporaries(in directories: [URL], fileManager: FileManager = .default) -> [URL] {
        let prefix = ".settings.json."
        return directories.flatMap { directory in
            ((try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? [])
                .filter { $0.hasPrefix(prefix) && UUID(uuidString: String($0.dropFirst(prefix.count))) != nil }
                .map { directory.appending(path: $0) }
        }
    }

    /// Ejects a disk image still attached in a work folder of an update and
    /// deletes the folders. Runs at launch and when the app is removed.
    /// - Returns: The folders that could not be deleted.
    @discardableResult
    func removeUpdateWorkspaces(fileManager: FileManager = .default) -> [URL] {
        UpdateInstaller.removeWorkspaces(in: updatesDirectory, fileManager: fileManager)
    }

    /// Deletes everything that exists.
    /// - Returns: The items that exist but could not be deleted.
    @discardableResult
    func removeItems(
        includingPreferencesFile: Bool,
        settingsDirectories: [URL],
        fileManager: FileManager = .default
    ) -> [URL] {
        // First, so no disk image is attached inside the caches deleted below.
        let updateFailures = removeUpdateWorkspaces(fileManager: fileManager)
        var targets = items + settingsTemporaries(in: settingsDirectories, fileManager: fileManager)
        if includingPreferencesFile {
            targets.append(preferencesFile)
        }
        let failures = targets.filter { url in
            guard fileManager.fileExists(atPath: url.path) else { return false }
            do {
                try fileManager.removeItem(at: url)
                return false
            } catch {
                return true
            }
        }
        return updateFailures + failures
    }
}

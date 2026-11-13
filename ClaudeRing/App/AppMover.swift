import AppKit

/// Copies the running app into „Programme“ and starts the copy there. For a
/// first launch straight from the disk image or the Downloads folder: only an
/// installed copy can open at login and replace itself on updates.
enum AppMover {
    enum MoveError: LocalizedError {
        case noWritableFolder
        case invalidCopy

        var errorDescription: String? {
            switch self {
            case .noWritableFolder: String(localized: "In „Programme“ darf Claude Ring keine Dateien anlegen.")
            case .invalidCopy: String(localized: "Die Kopie in „Programme“ ist unvollständig.")
            }
        }
    }

    static let appName = "Claude Ring.app"
    private static let quarantineAttribute = "com.apple.quarantine"

    /// `/Applications`, or `~/Applications` for a user who may not write there.
    static func candidateFolders(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        [URL(filePath: "/Applications", directoryHint: .isDirectory), home.appending(path: "Applications", directoryHint: .isDirectory)]
    }

    /// Puts the app into the first writable folder and returns the copy to
    /// open. A newer copy there stays and is returned. One of the same
    /// version is replaced: it may still be in quarantine, for example when
    /// it was dragged there but never opened, and would be blocked again.
    ///
    /// The copy loses the quarantine flag: the person has just allowed this
    /// app to open, and with the flag macOS would run the copy from a random
    /// read-only location again (App Translocation).
    static func install(
        from source: URL = Bundle.main.bundleURL,
        into folders: [URL] = candidateFolders(),
        fileManager: FileManager = .default,
        verify: (URL) throws -> Void = verifySignature
    ) throws -> URL {
        for folder in folders {
            if !fileManager.fileExists(atPath: folder.path) {
                try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            guard fileManager.isWritableFile(atPath: folder.path) else { continue }

            let target = folder.appending(path: appName, directoryHint: .isDirectory)
            if fileManager.fileExists(atPath: target.path),
               let existing = version(of: target), let running = version(of: source), existing > running {
                return target
            }

            let staged = folder.appending(path: ".\(appName).\(UUID().uuidString)", directoryHint: .isDirectory)
            defer { try? fileManager.removeItem(at: staged) }
            try fileManager.copyItem(at: source, to: staged)
            removeQuarantine(from: staged, fileManager: fileManager)
            try verify(staged)
            if fileManager.fileExists(atPath: target.path) {
                _ = try fileManager.replaceItemAt(target, withItemAt: staged)
            } else {
                try fileManager.moveItem(at: staged, to: target)
            }
            return target
        }
        throw MoveError.noWritableFolder
    }

    /// Opens the installed copy once this process has quit, then quits.
    @MainActor
    static func relaunch(into installed: URL) {
        UpdateInstaller.launchRelaunch(of: installed)
        NSApp.terminate(nil)
    }

    static func verifySignature(of app: URL) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/codesign")
        process.arguments = ["--verify", "--deep", "--strict", app.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else { throw MoveError.invalidCopy }
    }

    private static func version(of app: URL) -> AppVersion? {
        (NSDictionary(contentsOf: app.appending(path: "Contents/Info.plist"))?["CFBundleShortVersionString"] as? String)
            .flatMap(AppVersion.init)
    }

    private static func removeQuarantine(from app: URL, fileManager: FileManager) {
        removexattr(app.path, quarantineAttribute, XATTR_NOFOLLOW)
        for case let relative as String in fileManager.enumerator(atPath: app.path) ?? FileManager.DirectoryEnumerator() {
            removexattr(app.appending(path: relative).path, quarantineAttribute, XATTR_NOFOLLOW)
        }
    }
}

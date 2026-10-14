import CryptoKit
import Foundation
import OSLog

enum UpdateInstallError: LocalizedError {
    case downloadFailed
    case checksumMismatch
    case mountFailed
    case appMissing
    case unexpectedApp
    case requiresNewerSystem(String)
    case invalidSignature
    case copyFailed

    var errorDescription: String? {
        switch self {
        case .downloadFailed:
            "Der Download ist fehlgeschlagen."
        case .checksumMismatch:
            "Die heruntergeladene Datei stimmt nicht mit der Prüfsumme auf GitHub überein."
        case .mountFailed:
            "Das Disk-Image ließ sich nicht öffnen."
        case .appMissing:
            "Im Disk-Image fehlt „Claude Ring.app“."
        case .unexpectedApp:
            "Die App im Disk-Image ist nicht die erwartete Version von Claude Ring."
        case .requiresNewerSystem(let version):
            "Die neue Version braucht macOS \(version) oder neuer."
        case .invalidSignature:
            "Die Signatur der neuen App ist ungültig."
        case .copyFailed:
            "Die neue App ließ sich nicht kopieren."
        }
    }
}

/// Downloads a release DMG, checks it and puts the app inside in place of the
/// installed one.
///
/// The DMG must match the SHA-256 that GitHub lists for it; the app inside
/// must have the same bundle identifier, the announced version, an intact
/// signature and run on this macOS. Only then is the old bundle swapped out,
/// in one step on the same volume. The running process keeps its old files
/// until it quits.
///
/// The app is ad-hoc signed, so there is no signer to pin: its designated
/// requirement is its own code hash, which changes with every build. The
/// signature check catches damaged or altered files; who built the release
/// rests on GitHub, as with a manual download.
struct UpdateInstaller: Sendable {
    /// The app's name in the DMG; the installed copy may be named differently.
    static let appNameInImage = "Claude Ring.app"
    /// The DMG is attached at this folder inside the workspace.
    static let mountFolderName = "mount"

    /// The bundle to replace, normally the running app.
    let appURL: URL
    let bundleIdentifier: String
    /// Holds one work folder per running update; see `AppFootprint.updatesDirectory`.
    let updatesDirectory: URL
    private let session: URLSession
    private static let logger = Logger(subsystem: "eu.siekmann.ClaudeRing", category: "update")

    init(
        appURL: URL = Bundle.main.bundleURL,
        bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "eu.siekmann.ClaudeRing",
        updatesDirectory: URL = AppFootprint.current.updatesDirectory,
        session: URLSession = URLSession(configuration: .ephemeral)
    ) {
        self.appURL = appURL
        self.bundleIdentifier = bundleIdentifier
        self.updatesDirectory = updatesDirectory
        self.session = session
    }

    /// Only an installed copy replaces itself, and only where the user may
    /// write. A build from Xcode or a copy in Downloads gets the release page.
    var canReplaceApp: Bool {
        Self.canReplace(appURL: appURL)
    }

    static func canReplace(
        appURL: URL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> Bool {
        AppEnvironment.isInstalled(bundleURL: appURL, home: home)
            && fileManager.isWritableFile(atPath: appURL.deletingLastPathComponent().path)
            && fileManager.isWritableFile(atPath: appURL.path)
    }

    func install(_ download: AppRelease.Download, version: AppVersion) async throws {
        let fileManager = FileManager.default
        // Holds the download, the mounted image and the copy, and receives the
        // old app during the swap; all of it goes away with the folder.
        let workspace = try makeWorkspace(fileManager: fileManager)
        defer {
            Self.removeWorkspace(workspace, fileManager: fileManager)
            Self.removeWorkspaces(in: updatesDirectory, fileManager: fileManager)
        }

        let (file, response) = try await session.download(from: download.url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            try? fileManager.removeItem(at: file)
            throw UpdateInstallError.downloadFailed
        }
        let image = workspace.appending(path: ReleaseClient.assetName)
        try fileManager.moveItem(at: file, to: image)

        try await Task.detached(priority: .userInitiated) { [self] in
            try replaceApp(withAppIn: image, sha256: download.sha256, version: version, workspace: workspace)
        }.value
    }

    private func replaceApp(withAppIn image: URL, sha256: String, version: AppVersion, workspace: URL) throws {
        guard try Self.sha256Hex(of: image) == sha256 else { throw UpdateInstallError.checksumMismatch }

        let mountPoint = workspace.appending(path: Self.mountFolderName, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: false)
        try Self.run("/usr/bin/hdiutil", ["attach", image.path, "-readonly", "-nobrowse", "-noautoopen",
                                          "-mountpoint", mountPoint.path], else: .mountFailed)
        defer { Self.detach(mountPoint) }

        let mountedApp = mountPoint.appending(path: Self.appNameInImage, directoryHint: .isDirectory)
        try validate(mountedApp, version: version)

        let staged = workspace.appending(path: appURL.lastPathComponent, directoryHint: .isDirectory)
        try Self.run("/usr/bin/ditto", [mountedApp.path, staged.path], else: .copyFailed)
        try Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", staged.path], else: .invalidSignature)

        _ = try FileManager.default.replaceItemAt(appURL, withItemAt: staged)
    }

    /// Checks bundle identifier, version and minimum macOS of the new app.
    func validate(_ app: URL, version: AppVersion) throws {
        let values = try? app.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values?.isDirectory == true, values?.isSymbolicLink == false else { throw UpdateInstallError.appMissing }

        guard let info = NSDictionary(contentsOf: app.appending(path: "Contents/Info.plist")) as? [String: Any],
              info["CFBundleIdentifier"] as? String == bundleIdentifier,
              (info["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init) == version
        else { throw UpdateInstallError.unexpectedApp }

        if let minimum = info["LSMinimumSystemVersion"] as? String, let required = AppVersion(minimum) {
            let system = ProcessInfo.processInfo.operatingSystemVersion
            let running = AppVersion("\(system.majorVersion).\(system.minorVersion).\(system.patchVersion)")
            if let running, running < required {
                throw UpdateInstallError.requiresNewerSystem(minimum)
            }
        }
    }

    static func sha256Hex(of file: URL) throws -> String {
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// A new folder in `updatesDirectory`, where a crash cannot hide it: the
    /// next launch finds and removes it. The swap at the end must be a rename,
    /// so if the caches sit on another volume than the app, FileManager
    /// provides a temporary folder on the app's volume instead.
    private func makeWorkspace(fileManager: FileManager) throws -> URL {
        if (try? fileManager.createDirectory(at: updatesDirectory, withIntermediateDirectories: true)) != nil,
           let volume = Self.volume(of: updatesDirectory), volume == Self.volume(of: appURL.deletingLastPathComponent()) {
            let workspace = updatesDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
            try fileManager.createDirectory(at: workspace, withIntermediateDirectories: false)
            return workspace
        }
        Self.removeWorkspaces(in: updatesDirectory, fileManager: fileManager)
        return try fileManager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: appURL, create: true)
    }

    private static func volume(of url: URL) -> NSObject? {
        (try? url.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
    }

    /// Removes every work folder in `updatesDirectory`, then the folder itself
    /// and the caches folder above it, if nothing else is left there.
    /// - Returns: The work folders that could not be deleted.
    @discardableResult
    static func removeWorkspaces(in updatesDirectory: URL, fileManager: FileManager = .default) -> [URL] {
        let workspaces = ((try? fileManager.contentsOfDirectory(atPath: updatesDirectory.path)) ?? [])
            .map { updatesDirectory.appending(path: $0, directoryHint: .isDirectory) }
        let failures = workspaces.filter { !removeWorkspace($0, fileManager: fileManager) }
        for folder in [updatesDirectory, updatesDirectory.deletingLastPathComponent()] {
            if (try? fileManager.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
                try? fileManager.removeItem(at: folder)
            }
        }
        return failures
    }

    /// Ejects the disk image if it is still attached, then deletes the work
    /// folder. If the image will not eject, the folder stays, so nothing on
    /// the mounted volume is touched.
    /// - Returns: Whether the folder is gone.
    @discardableResult
    static func removeWorkspace(_ workspace: URL, fileManager: FileManager = .default) -> Bool {
        let mountPoint = workspace.appending(path: mountFolderName, directoryHint: .isDirectory)
        if isMounted(mountPoint) {
            detach(mountPoint)
            guard !isMounted(mountPoint) else { return false }
        }
        try? fileManager.removeItem(at: workspace)
        return !fileManager.fileExists(atPath: workspace.path)
    }

    /// A fresh URL each time, so no cached value hides an eject.
    private static func isMounted(_ folder: URL) -> Bool {
        (try? URL(filePath: folder.path).resourceValues(forKeys: [.isVolumeKey]))?.isVolume == true
    }

    // MARK: - Relaunch

    /// Waits up to 30 seconds for the app to quit, then opens it again. If it
    /// is still running by then, the new version starts with the next launch.
    nonisolated static let relaunchScript = #"""
    for i in $(/usr/bin/seq 300); do
      if ! /bin/kill -0 "$1" 2>/dev/null; then
        /usr/bin/open "$2"
        exit 0
      fi
      /bin/sleep 0.1
    done
    """#

    /// Starts a small shell that outlives the app and opens the new version
    /// once this process has quit. Quit right after calling this.
    static func launchRelaunch(of appURL: URL, pid: Int32 = ProcessInfo.processInfo.processIdentifier) {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", relaunchScript, "relaunch", String(pid), appURL.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    // MARK: - Tools

    private static func detach(_ mountPoint: URL) {
        if (try? run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-quiet"], else: .mountFailed)) == nil {
            try? run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-quiet", "-force"], else: .mountFailed)
        }
    }

    /// Runs a tool and throws `error` unless it exits with 0. Stops the tool
    /// after two minutes.
    private static func run(_ tool: String, _ arguments: [String], else error: UpdateInstallError) throws {
        let process = Process()
        process.executableURL = URL(filePath: tool)
        process.arguments = arguments
        let errorOutput = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorOutput
        try process.run()

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 120) {
            if process.isRunning { process.terminate() }
        }

        let message = errorOutput.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            let text = String(decoding: message, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            logger.error("\(tool, privacy: .public) failed (\(process.terminationStatus, privacy: .public)): \(text, privacy: .public)")
            throw error
        }
    }
}

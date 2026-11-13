import Foundation

/// A folder in the temporary directory that is deleted together with this
/// object. Keep it in a stored property of the test suite: Swift Testing
/// creates the suite anew for every test and releases it afterwards.
final class TemporaryFolder {
    let url: URL

    init(_ prefix: String = "ClaudeRingTests") {
        url = FileManager.default.temporaryDirectory.appending(path: "\(prefix)-\(UUID())", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Disk images for tests, made with `diskutil` like the update function
/// opens them, so the tests also show that `diskutil image` works on the
/// macOS of the CI runner.
enum TestDiskImage {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// Writes a compressed, read-only disk image (UDZO, like the release DMG)
    /// with the given files and symbolic links to `image`.
    static func make(at image: URL, files: [String: Data] = [:], links: [String: URL] = [:]) throws {
        let blank = image.deletingLastPathComponent().appending(path: "blank-\(UUID()).dmg")
        defer { try? FileManager.default.removeItem(at: blank) }
        try diskutil("image", "create", "blank", "--size", "10m", "--volumeName", "Test", blank.path)

        // On macOS 26 the folder must exist; only macOS 27 creates it itself.
        let mountPoint = image.deletingLastPathComponent().appending(path: "filling-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: mountPoint) }
        try diskutil("image", "attach", "--mountOptions", "nobrowse", "--mountPoint", mountPoint.path, blank.path)
        do {
            for (name, data) in files {
                try data.write(to: mountPoint.appending(path: name))
            }
            for (name, destination) in links {
                try FileManager.default.createSymbolicLink(at: mountPoint.appending(path: name), withDestinationURL: destination)
            }
        } catch {
            eject(mountPoint)
            throw error
        }
        try diskutil("eject", mountPoint.path)
        try diskutil("image", "create", "from", "--format", "UDZO", blank.path, image.path)
    }

    static func isMounted(_ folder: URL) -> Bool {
        (try? URL(filePath: folder.path).resourceValues(forKeys: [.isVolumeKey]))?.isVolume == true
    }

    /// Ejects an image a failing test left attached.
    static func eject(_ mountPoint: URL) {
        if isMounted(mountPoint) { try? diskutil("eject", "force", mountPoint.path) }
    }

    private static func diskutil(_ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/sbin/diskutil")
        process.arguments = arguments
        let errorOutput = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorOutput
        try process.run()
        let message = errorOutput.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let text = String(decoding: message, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure(description: "diskutil \(arguments.joined(separator: " ")) failed: \(text)")
        }
    }
}

/// UserDefaults for a single test, stored in a temporary folder.
///
/// A suite named only by a UUID lands in ~/Library/Preferences, and macOS
/// writes an empty plist for it again after the process exits, even when the
/// test removed the domain. A suite named by an absolute path is stored at
/// that path instead, so nothing piles up in the user's preferences.
final class TestDefaults {
    let defaults: UserDefaults
    private let folder = TemporaryFolder("ClaudeRingDefaults")

    init() {
        defaults = UserDefaults(suiteName: folder.url.appending(path: "defaults").path)!
    }
}

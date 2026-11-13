import Foundation

/// Whether Claude Code seems to be on this Mac, to tell "not installed" apart
/// from "not signed in". Looks only at files, never at the keychain.
enum ClaudeCodeInstallation {
    /// Where the installers put the command line tool.
    static let standardSystemPaths = ["/opt/homebrew/bin/claude", "/usr/local/bin/claude"]

    /// `~/.claude` alone does not count: this app creates it for its hooks.
    static func isInstalled(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        systemPaths: [String] = standardSystemPaths,
        fileManager: FileManager = .default
    ) -> Bool {
        let inHome = [".claude.json", ".local/bin/claude", ".claude/local/claude"].map { home.appending(path: $0).path }
        return (inHome + systemPaths).contains { fileManager.fileExists(atPath: $0) }
    }
}

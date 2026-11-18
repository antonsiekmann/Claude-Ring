import AppKit
import Darwin

/// Finds the app a process runs in, such as the terminal or the editor of a
/// Claude Code session, by following its parent processes.
enum HostApp {
    /// - Returns: The first app with a Dock icon among the parents of `pid`;
    ///   nil for sessions without one, such as background sessions or those
    ///   inside tmux, whose server does not run in the terminal.
    @MainActor
    static func of(pid: pid_t) -> NSRunningApplication? {
        var current = pid
        // Terminal → login → shell → claude is the usual chain; the limit only
        // guards against surprises.
        for _ in 0..<16 {
            if let app = NSRunningApplication(processIdentifier: current), app.activationPolicy == .regular {
                return app
            }
            guard let parent = parentPID(of: current) else { return nil }
            current = parent
        }
        return nil
    }

    /// The parent of `pid`; nil when the process is gone or its parent is
    /// launchd.
    static func parentPID(of pid: pid_t) -> pid_t? {
        guard pid > 1 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        // The size comes back as 0 when no such process exists.
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let parent = info.kp_eproc.e_ppid
        return parent > 1 ? parent : nil
    }
}

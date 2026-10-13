import Darwin
import Foundation

protocol ProcessProbing: Sendable {
    /// True when `pid` is still the process that wrote a record at `date`:
    /// it exists and did not start after the record was written (which would
    /// mean macOS reused the PID for another process).
    func isAlive(pid: Int32, recordedAt date: Date) -> Bool
}

struct SystemProcessProbe: ProcessProbing {
    func isAlive(pid: Int32, recordedAt date: Date) -> Bool {
        // 0 is the kernel, 1 is launchd: never a Claude Code session.
        guard pid > 1 else { return false }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        // The size comes back as 0 when no such process exists.
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return false }
        let start = info.kp_proc.p_starttime
        let started = Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
        return started <= date.addingTimeInterval(1)
    }
}

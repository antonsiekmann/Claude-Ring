import Foundation
import Synchronization
import Testing
@testable import ClaudeRing

private func record(
    _ event: String, pid: Int32 = 100, tool: String? = nil, ntype: String? = nil,
    source: String? = nil, error: String? = nil, cwd: String? = "/Users/me/projekt"
) -> HookEventRecord {
    HookEventRecord(pid: pid, event: event, session: "s", cwd: cwd, tool: tool, ntype: ntype,
                    source: source, reason: nil, error: error)
}

struct SessionReducerTests {
    @Test(arguments: [
        (record("SessionStart", source: "startup"), ClaudeActivity?.some(.idle)),
        (record("SessionStart", source: "resume"), .idle),
        (record("UserPromptSubmit"), .working),
        (record("PreToolUse", tool: "AskUserQuestion"), .waiting),
        (record("PreToolUse", tool: "ExitPlanMode"), .waiting),
        (record("PreToolUse", tool: "Bash"), .working),
        (record("PermissionRequest", tool: "Bash"), .waiting),
        (record("PostToolUse", tool: "Bash"), .working),
        (record("PostToolUseFailure", tool: "Bash"), .working),
        (record("Elicitation"), .waiting),
        (record("ElicitationResult"), .working),
        (record("Notification", ntype: "permission_prompt"), .waiting),
        (record("Notification", ntype: "elicitation_dialog"), .waiting),
        (record("Notification", ntype: "agent_needs_input"), .waiting),
        (record("Notification", ntype: "idle_prompt"), .idle),
        (record("Stop"), .idle),
        (record("StopFailure", error: "rate_limit"), .idle),
        (record("SessionEnd"), nil),
    ])
    func `Maps each hook event`(record: HookEventRecord, expected: ClaudeActivity?) {
        #expect(SessionReducer.activity(after: record, previous: .working) == expected)
    }

    @Test func `Keeps the previous state for events without meaning`() {
        #expect(SessionReducer.activity(after: record("Notification", ntype: "auth_success"), previous: .waiting) == .waiting)
        #expect(SessionReducer.activity(after: record("SessionStart", source: "compact"), previous: .working) == .working)
        #expect(SessionReducer.activity(after: record("CwdChanged"), previous: nil) == .idle)
    }

    @Test func `Clears a stuck state with the idle notification`() {
        #expect(SessionReducer.activity(after: record("Notification", ntype: "idle_prompt"), previous: .waiting) == .idle)
    }
}

private final class FakeProbe: ProcessProbing {
    private let alive: Mutex<Set<Int32>>

    init(alive: Set<Int32>) {
        self.alive = Mutex(alive)
    }

    func kill(_ pid: Int32) {
        _ = alive.withLock { $0.remove(pid) }
    }

    func isAlive(pid: Int32, recordedAt date: Date) -> Bool {
        alive.withLock { $0.contains(pid) }
    }
}

@MainActor
struct ClaudeSessionStoreTests {
    private let directory: URL
    private let probe = FakeProbe(alive: [100, 200, 300])
    private let store: ClaudeSessionStore

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "sessions-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = ClaudeSessionStore(directory: directory, processProbe: probe)
    }

    private func write(_ json: String, pid: Int32 = 100, session: String = "s1", modified: Date = .now) throws {
        let url = directory.appending(path: "\(pid)-\(session).json")
        // Atomic like the hook script's mv, which is what the folder watcher sees.
        try Data(json.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }

    private func event(_ name: String, pid: Int32 = 100, cwd: String = "/Users/me/app", extra: String = "") -> String {
        #"{"v":1,"pid":\#(pid),"event":"\#(name)","session":"s","cwd":"\#(cwd)"\#(extra)}"#
    }

    @Test func `Shows one session per running process with its project`() throws {
        try write(event("UserPromptSubmit"))
        store.reloadNow()

        #expect(store.sessions.map(\.projectName) == ["app"])
        #expect(store.aggregate == .working)
        #expect(store.lastEventDate != nil)
    }

    @Test func `Marks sessions that run in the background`() throws {
        try write(event("SessionStart", pid: 100, extra: #","kind":"bg""#), pid: 100)
        try write(event("UserPromptSubmit", pid: 200), pid: 200)
        store.reloadNow()

        let background = Dictionary(uniqueKeysWithValues: store.sessions.map { ($0.pid, $0.isBackground) })
        #expect(background == [100: true, 200: false])
    }

    @Test func `Prefers waiting over working over idle`() throws {
        try write(event("Stop", pid: 100, cwd: "/a"), pid: 100)
        try write(event("UserPromptSubmit", pid: 200, cwd: "/b"), pid: 200)
        try write(event("PermissionRequest", pid: 300, cwd: "/c"), pid: 300)
        store.reloadNow()

        #expect(store.aggregate == .waiting)
        #expect(store.sessions.map(\.activity) == [.waiting, .working, .idle])
    }

    @Test func `Has no aggregate without sessions`() {
        store.reloadNow()
        #expect(store.sessions.isEmpty)
        #expect(store.aggregate == nil)
    }

    @Test func `Removes ended sessions and their files`() throws {
        try write(event("SessionEnd"))
        store.reloadNow()

        #expect(store.sessions.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test func `Drops sessions whose process is gone`() throws {
        try write(event("UserPromptSubmit"))
        store.reloadNow()
        #expect(store.aggregate == .working)

        probe.kill(100)
        store.reloadNow()

        #expect(store.sessions.isEmpty)
    }

    @Test func `Keeps only the newest file of a process`() throws {
        try write(event("Stop"), session: "old", modified: .now.addingTimeInterval(-600))
        try write(event("UserPromptSubmit"), session: "new")
        store.reloadNow()

        #expect(store.sessions.map(\.id) == ["100-new"])
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "100-old.json").path))
    }

    @Test func `Keeps the start time while the activity stays the same`() throws {
        let start = Date.now.addingTimeInterval(-120)
        try write(event("UserPromptSubmit"), modified: start)
        store.reloadNow()
        try write(event("PostToolUse"), modified: .now)
        store.reloadNow()

        let since = try #require(store.sessions.first?.since)
        #expect(abs(since.timeIntervalSince(start)) < 1)
    }

    @Test func `Keeps the state for an event without meaning`() throws {
        try write(event("PermissionRequest"), modified: .now.addingTimeInterval(-5))
        store.reloadNow()
        try write(event("Notification", extra: #","ntype":"auth_success""#))
        store.reloadNow()

        #expect(store.aggregate == .waiting)
    }

    @Test func `Removes temporary files left behind by killed hooks`() throws {
        let old = directory.appending(path: ".tmp.111")
        let fresh = directory.appending(path: ".tmp.222")
        try Data("{}".utf8).write(to: old)
        try Data("{}".utf8).write(to: fresh)
        try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-120)], ofItemAtPath: old.path)
        store.reloadNow()

        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: fresh.path))
    }

    @Test func `Ignores hidden temporary files and broken records`() throws {
        try Data(event("UserPromptSubmit").utf8).write(to: directory.appending(path: ".tmp.123"))
        try Data("garbage".utf8).write(to: directory.appending(path: "100-x.json"))
        store.reloadNow()

        #expect(store.sessions.isEmpty)
    }

    @Test func `Reports a fresh rate limit failure`() throws {
        let calls = Mutex(0)
        store.onRateLimited = { calls.withLock { $0 += 1 } }
        try write(event("StopFailure", extra: #","error":"rate_limit""#))
        store.reloadNow()
        store.reloadNow()

        #expect(calls.withLock { $0 } == 1)
    }

    @Test func `Keeps watching after a restart that interrupted a pending reload`() async throws {
        store.start()
        try write(event("UserPromptSubmit"), session: "a")
        try await Task.sleep(for: .milliseconds(20)) // the event arrived, its reload is pending
        store.stop()
        store.start()
        try write(event("PermissionRequest"), session: "a")

        for _ in 0..<40 where store.aggregate != .waiting {
            try await Task.sleep(for: .milliseconds(50))
        }
        store.stop()
        #expect(store.aggregate == .waiting)
    }

    @Test func `Picks up new files through the folder watcher`() async throws {
        store.start()
        defer { store.stop() }
        try write(event("UserPromptSubmit"))

        for _ in 0..<40 where store.aggregate == nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(store.aggregate == .working)
    }
}

struct SystemProcessProbeTests {
    @Test func `Knows the running test process`() {
        #expect(SystemProcessProbe().isAlive(pid: getpid(), recordedAt: .now))
    }

    @Test func `Rejects launchd, the kernel and missing processes`() {
        let probe = SystemProcessProbe()
        #expect(!probe.isAlive(pid: 1, recordedAt: .now))
        #expect(!probe.isAlive(pid: 0, recordedAt: .now))
        #expect(!probe.isAlive(pid: 99_999, recordedAt: .now))
    }

    @Test func `Detects a reused process ID`() {
        // A record written before this process started belongs to another one.
        #expect(!SystemProcessProbe().isAlive(pid: getpid(), recordedAt: .now.addingTimeInterval(-86_400)))
    }
}

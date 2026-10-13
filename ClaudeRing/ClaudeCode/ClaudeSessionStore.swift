import Foundation
import Observation
import OSLog

/// One running Claude Code session as reported by the hooks.
struct ClaudeSession: Identifiable, Equatable, Sendable {
    /// `<pid>-<session id>`, the name of the session's file.
    let id: String
    let pid: Int32
    let projectName: String
    /// Runs in the background (agent view, `claude --bg`) instead of a terminal.
    let isBackground: Bool
    let activity: ClaudeActivity
    /// When the session entered its current activity.
    let since: Date
}

/// Keeps track of the running Claude Code sessions.
///
/// The hook script writes one small file per session. The store watches that
/// folder with a file system event source, so it costs nothing while Claude
/// Code is quiet. Processes that ended without saying goodbye are found by a
/// slow liveness check that only runs while sessions exist.
@MainActor
@Observable
final class ClaudeSessionStore {
    private(set) var sessions: [ClaudeSession] = [] {
        didSet {
            aggregate = ClaudeActivity.aggregate(sessions.map(\.activity))
            updateLivenessCheck()
        }
    }
    /// What the menu bar dot shows; nil when no session runs.
    private(set) var aggregate: ClaudeActivity?
    /// When any session last reported an event; shown in the settings.
    private(set) var lastEventDate: Date?

    /// Called when a turn failed because of the usage limit, so the usage
    /// can be refreshed right away.
    @ObservationIgnored var onRateLimited: (() -> Void)?

    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let processProbe: any ProcessProbing
    @ObservationIgnored private let livenessInterval: Duration
    @ObservationIgnored private var source: (any DispatchSourceFileSystemObject)?
    @ObservationIgnored private var pendingReload: Task<Void, Never>?
    @ObservationIgnored private var livenessTask: Task<Void, Never>?
    @ObservationIgnored private var known: [String: Known] = [:]
    @ObservationIgnored private let logger = Logger(subsystem: "eu.siekmann.ClaudeRing", category: "sessions")

    private struct Known {
        var activity: ClaudeActivity
        var since: Date
        var modified: Date
    }

    init(
        directory: URL = HookInstaller.Paths.standard.sessions,
        processProbe: any ProcessProbing = SystemProcessProbe(),
        livenessInterval: Duration = .seconds(60)
    ) {
        self.directory = directory
        self.processProbe = processProbe
        self.livenessInterval = livenessInterval
    }

    /// Starts watching the sessions folder. Call again after the hooks were
    /// set up, because the folder only exists from then on.
    func start() {
        guard source == nil else { return }
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else {
            sessions = []
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .delete, .rename], queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let source = self.source else { return }
                if source.data.contains(.delete) || source.data.contains(.rename) {
                    // The hooks were removed together with the folder.
                    self.stop()
                    self.sessions = []
                } else {
                    self.scheduleReload()
                }
            }
        }
        source.setCancelHandler {
            close(descriptor)
        }
        self.source = source
        source.resume()
        reloadNow()
    }

    func stop() {
        source?.cancel()
        source = nil
        pendingReload?.cancel()
        pendingReload = nil
    }

    /// Hooks fire in bursts (two events per tool call); read once per burst.
    private func scheduleReload() {
        guard pendingReload == nil else { return }
        pendingReload = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            self?.pendingReload = nil
            self?.reloadNow()
        }
    }

    /// Reads all session files. Internal for tests.
    func reloadNow() {
        let fileManager = FileManager.default
        removeStaleTemporaryFiles()
        let urls = (try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        )) ?? []

        // Newest record per process: a process runs one session at a time,
        // older files of the same process are left over from /clear or /resume.
        var newestPerProcess: [Int32: (url: URL, record: HookEventRecord, modified: Date)] = [:]
        for url in urls where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let record = try? JSONDecoder().decode(HookEventRecord.self, from: data)
            else { continue }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if let existing = newestPerProcess[record.pid], existing.modified >= modified {
                try? fileManager.removeItem(at: url)
                continue
            }
            if let existing = newestPerProcess[record.pid] {
                try? fileManager.removeItem(at: existing.url)
            }
            newestPerProcess[record.pid] = (url, record, modified)
        }

        var updated: [ClaudeSession] = []
        var updatedKnown: [String: Known] = [:]
        for (url, record, modified) in newestPerProcess.values {
            let id = url.deletingPathExtension().lastPathComponent
            let previous = known[id]
            let isNewEvent = previous?.modified != modified

            // Only react to fresh failures, not to an old file found at launch.
            if isNewEvent, record.event == "StopFailure", record.error == "rate_limit",
               modified > .now.addingTimeInterval(-60) {
                onRateLimited?()
            }

            guard processProbe.isAlive(pid: record.pid, recordedAt: modified),
                  let activity = isNewEvent
                    ? SessionReducer.activity(after: record, previous: previous?.activity)
                    : previous?.activity
            else {
                try? fileManager.removeItem(at: url)
                continue
            }

            let since = previous?.activity == activity ? previous?.since ?? modified : modified
            updatedKnown[id] = Known(activity: activity, since: since, modified: modified)
            updated.append(ClaudeSession(
                id: id,
                pid: record.pid,
                projectName: record.cwd.map { URL(filePath: $0).lastPathComponent } ?? "Claude Code",
                isBackground: record.kind == "bg",
                activity: activity,
                since: since
            ))
        }

        known = updatedKnown
        // Sessions that need attention first, then by project.
        let sorted = updated.sorted { a, b in
            if a.activity != b.activity { return a.activity > b.activity }
            return a.projectName.localizedStandardCompare(b.projectName) == .orderedAscending
        }
        if sorted != sessions {
            sessions = sorted
            logger.info("Sessions: \(sorted.count, privacy: .public), aggregate \(String(describing: self.aggregate), privacy: .public)")
        }
        let newest = newestPerProcess.values.map(\.modified).max()
        if newest != nil, newest != lastEventDate {
            lastEventDate = newest
        }
    }

    /// The hook script writes `.tmp.<pid>` and renames it. If the hook was
    /// killed in between, the file stays behind.
    private func removeStaleTemporaryFiles() {
        let fileManager = FileManager.default
        let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix(".tmp.") {
            let url = directory.appending(path: name)
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < .now.addingTimeInterval(-60) {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    // MARK: - Liveness

    private func updateLivenessCheck() {
        if sessions.isEmpty {
            livenessTask?.cancel()
            livenessTask = nil
        } else if livenessTask == nil {
            let interval = livenessInterval
            livenessTask = Task { [weak self] in
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(for: interval, tolerance: interval / 6)
                    } catch {
                        return
                    }
                    self?.reloadNow()
                }
            }
        }
    }
}

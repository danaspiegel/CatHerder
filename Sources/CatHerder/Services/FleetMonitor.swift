import Foundation
import Observation

/// Owns the app's whole view of the world and refreshes it on a timer.
///
/// Live instances are cheap to observe, so they refresh often. History is
/// expensive (transcripts run to tens of megabytes) so it is parsed lazily in
/// the background, newest first, and cached between launches.
@MainActor
@Observable
final class FleetMonitor {

    // MARK: - Published state

    var live: [MonitoredSession] = []
    var history: [MonitoredSession] = []

    var isRefreshing = false
    var lastRefresh: Date?
    var historyLoaded = 0
    var historyTotal = 0
    /// Non-nil when a terminal-activation attempt has something to say.
    var statusMessage: StatusMessage?

    struct StatusMessage: Identifiable, Sendable {
        let id = UUID()
        var text: String
        var isError: Bool
    }

    /// How often the live view re-scans the process table.
    var liveRefreshInterval: TimeInterval = 3

    // MARK: - Collaborators

    private let store = SessionStore()
    private var timer: Timer?
    private var historyTask: Task<Void, Never>?
    private var isWarmed = false

    // MARK: - Lifecycle

    func start() {
        Task { await refreshLive() }
        Task { await loadHistory() }

        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: liveRefreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refreshLive()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        historyTask?.cancel()
        Task { await store.persistCache() }
    }

    // MARK: - Live refresh

    func refreshLive() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false; lastRefresh = Date() }

        let processes = await ProcessScanner.scan()
        let transcripts = await store.index()
        let matches = SessionResolver.resolve(processes: processes, transcripts: transcripts)

        let byID = Dictionary(uniqueKeysWithValues: transcripts.map { ($0.sessionID, $0) })

        var rows: [MonitoredSession] = []
        for process in processes {
            let sessionID = matches[process.pid]?.sessionID
            var digest: TranscriptDigest
            if let sessionID, let file = byID[sessionID] {
                digest = await store.digest(for: file)
            } else {
                // A brand-new instance may not have written a transcript yet.
                digest = .empty(sessionID: sessionID ?? "pid-\(process.pid)", path: "")
                digest.cwd = process.cwd
            }

            let git = GitInspector.inspect(directory: process.cwd ?? digest.cwd)
            let status = SessionStatusPolicy.classify(digest: digest, process: process)

            rows.append(MonitoredSession(
                sessionID: digest.sessionID,
                digest: digest,
                process: process,
                git: git,
                status: status
            ))
        }

        // Most recently active first; unmatched instances sink to the bottom.
        rows.sort { ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast) }
        live = rows

        // Keep history free of anything currently running.
        let liveIDs = Set(rows.map(\.sessionID))
        if !liveIDs.isEmpty {
            history.removeAll { liveIDs.contains($0.sessionID) }
        }
    }

    // MARK: - History

    /// Parses every transcript newest-first, publishing in batches so the list
    /// fills in progressively instead of blocking on the whole corpus.
    func loadHistory() async {
        historyTask?.cancel()
        let alreadyWarmed = isWarmed
        isWarmed = true

        // Detached so transcript parsing and the git/filesystem probes never run
        // on the main actor; only the publishing hops back.
        historyTask = Task.detached(priority: .utility) { [store] in
            let files = await store.index().sorted { $0.modified > $1.modified }
            await MainActor.run {
                self.historyTotal = files.count
                self.historyLoaded = 0
            }

            // One cheap pass for Notion titles, so cards referenced only by id
            // still show a readable name on the very first render.
            if !alreadyWarmed {
                await store.warmNotionTitles(from: files)
            }

            var batch: [MonitoredSession] = []
            var completed = 0

            for file in files {
                if Task.isCancelled { return }
                let digest = await store.digest(for: file)
                completed += 1

                // Skip transcripts with no real content — aborted launches.
                guard digest.userMessageCount > 0 || digest.assistantMessageCount > 0 else {
                    if completed % 12 == 0 {
                        let count = completed
                        await MainActor.run { self.historyLoaded = count }
                    }
                    continue
                }

                // Historical directories get deleted (worktrees especially), so
                // fall back to the branch the transcript last recorded.
                let git = Self.gitInfo(for: digest)
                batch.append(MonitoredSession(
                    sessionID: digest.sessionID,
                    digest: digest,
                    process: nil,
                    git: git,
                    status: .ended
                ))

                if batch.count >= 12 {
                    let published = batch
                    let count = completed
                    batch = []
                    await MainActor.run {
                        self.appendHistory(published)
                        self.historyLoaded = count
                    }
                }
            }

            let remaining = batch
            let count = completed
            await MainActor.run {
                self.appendHistory(remaining)
                self.historyLoaded = count
            }
            await store.persistCache()
        }
    }

    /// Git state for a *historical* session.
    ///
    /// The branch comes from the transcript rather than from disk: the working
    /// directory has almost certainly been checked out to something else since,
    /// and what matters here is the branch the session was actually working on.
    /// Repository identity still comes from disk when it is available.
    nonisolated static func gitInfo(for digest: TranscriptDigest) -> GitInfo {
        let recorded = digest.gitBranchAtEnd.flatMap { branch -> String? in
            let trimmed = branch.trimmingCharacters(in: .whitespaces)
            // "HEAD" is a detached checkout, which names no branch.
            return (trimmed.isEmpty || trimmed == "HEAD") ? nil : trimmed
        }

        var live = GitInspector.inspect(directory: digest.cwd)
        if live.isRepo {
            if let recorded { live.branch = recorded }
            return live
        }

        // Directory is gone (a deleted worktree, typically) — reconstruct.
        guard let branch = recorded, let cwd = digest.cwd else { return live }

        // The worktree path encodes the parent repo: …/<repo>/.claude/worktrees/<name>
        var repo = URL(fileURLWithPath: cwd).lastPathComponent
        if let range = cwd.range(of: "/.claude/worktrees/") {
            repo = URL(fileURLWithPath: String(cwd[cwd.startIndex..<range.lowerBound])).lastPathComponent
        }
        return GitInfo(repoName: repo, repoRoot: cwd, branch: branch,
                       isWorktree: cwd.contains("/.claude/worktrees/"))
    }

    private func appendHistory(_ rows: [MonitoredSession]) {
        guard !rows.isEmpty else { return }
        let liveIDs = Set(live.map(\.sessionID))
        let existing = Set(history.map(\.sessionID))
        let additions = rows.filter { !liveIDs.contains($0.sessionID) && !existing.contains($0.sessionID) }
        guard !additions.isEmpty else { return }
        history.append(contentsOf: additions)
        history.sort { ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast) }
    }

    // MARK: - Actions

    /// Brings the terminal tab for a session to the front.
    func focusTerminal(for session: MonitoredSession) {
        guard let process = session.process else {
            statusMessage = StatusMessage(
                text: "That session isn't running, so there's no tab to switch to.", isError: true)
            return
        }
        Task {
            let result = await TerminalActivator.activate(terminal: process.terminal)
            statusMessage = StatusMessage(text: result.message, isError: !result.isSuccess)
        }
    }

    func revealInFinder(_ path: String?) {
        guard let path, !path.isEmpty else { return }
        NSWorkspaceBridge.reveal(path: path)
    }

    var workingCount: Int { live.filter { $0.status == .working }.count }
    var needsAttentionCount: Int { live.filter { $0.status == .awaitingInput }.count }
}

// MARK: - AppKit bridge

import AppKit

enum NSWorkspaceBridge {
    static func reveal(path: String) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }
    static func open(url: URL) {
        NSWorkspace.shared.open(url)
    }
}

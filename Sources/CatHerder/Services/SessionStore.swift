import Foundation

/// One transcript file on disk.
struct TranscriptFile: Sendable, Hashable {
    var path: String
    var sessionID: String
    var projectSlug: String
    var size: Int
    var modified: Date

    /// Cache identity: a transcript that has not grown does not need re-parsing.
    var fingerprint: String { "\(size)-\(modified.timeIntervalSince1970)" }
}

/// Canonical locations Claude Code writes to.
enum ClaudePaths {
    static var home: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    }
    static var projects: URL { home.appendingPathComponent("projects") }
    static var sessionEnv: URL { home.appendingPathComponent("session-env") }

    /// Per-session scratchpad root, e.g. /tmp/claude-501
    static var scratchRoot: URL {
        URL(fileURLWithPath: "/tmp/claude-\(getuid())")
    }

    static var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("CatHerder", isDirectory: true)
    }

    /// Claude Code slugs a working directory by replacing every "/" with "-".
    static func slug(for directory: String) -> String {
        directory.replacingOccurrences(of: "/", with: "-")
    }
}

/// Indexes transcripts and parses them into digests, caching by fingerprint so
/// repeat launches are cheap. An actor because the UI hits it from many tasks.
actor SessionStore {

    /// Injectable so tests can point at a fixture tree instead of the real
    /// ~/.claude directory.
    private let projectsRoot: URL
    private let cacheRoot: URL

    init(projectsRoot: URL = ClaudePaths.projects,
         cacheRoot: URL = ClaudePaths.cacheDirectory) {
        self.projectsRoot = projectsRoot
        self.cacheRoot = cacheRoot
    }

    private var digests: [String: (fingerprint: String, digest: TranscriptDigest)] = [:]
    /// Page id → best known human title, pooled across every transcript. A slug
    /// seen in one session names a card referenced only by id in another.
    private var notionTitles: [String: String] = [:]
    private var loadedCache = false

    // MARK: - Index

    /// Lists every transcript under ~/.claude/projects without parsing any of them.
    func index() -> [TranscriptFile] {
        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(
            at: projectsRoot, includingPropertiesForKeys: nil) else { return [] }

        var files: [TranscriptFile] = []
        for dir in projectDirs {
            guard let entries = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { continue }
            for entry in entries where entry.pathExtension == "jsonl" {
                let values = try? entry.resourceValues(
                    forKeys: [.fileSizeKey, .contentModificationDateKey])
                files.append(TranscriptFile(
                    path: entry.path,
                    sessionID: entry.deletingPathExtension().lastPathComponent,
                    projectSlug: dir.lastPathComponent,
                    size: values?.fileSize ?? 0,
                    modified: values?.contentModificationDate ?? .distantPast
                ))
            }
        }
        return files
    }

    // MARK: - Digests

    /// Returns a digest, parsing only when the file changed since we last saw it.
    func digest(for file: TranscriptFile) -> TranscriptDigest {
        loadCacheIfNeeded()

        if let cached = digests[file.path], cached.fingerprint == file.fingerprint {
            return resolvingTitles(cached.digest)
        }

        var parsed = TranscriptParser.digest(path: file.path, sessionID: file.sessionID)

        // Feed any titles this transcript revealed back into the shared pool.
        for ref in parsed.notionRefs {
            if let title = ref.title, !title.isEmpty {
                notionTitles[ref.pageID] = title
            }
        }

        // An empty transcript still has a useful last-activity from the filesystem.
        if parsed.lastActivity == nil { parsed.lastActivity = file.modified }

        digests[file.path] = (file.fingerprint, parsed)
        return resolvingTitles(parsed)
    }

    /// Fills in card titles this transcript never spelled out itself.
    private func resolvingTitles(_ digest: TranscriptDigest) -> TranscriptDigest {
        guard !digest.notionRefs.isEmpty else { return digest }
        var copy = digest
        copy.notionRefs = digest.notionRefs.map { ref in
            guard ref.title == nil || ref.title!.isEmpty,
                  let pooled = notionTitles[ref.pageID] else { return ref }
            var updated = ref
            updated.title = pooled
            return updated
        }
        return copy
    }

    /// Cheap pre-pass: harvests slugged Notion URLs from every transcript so
    /// titles are known before the owning transcript is fully parsed.
    ///
    /// Only worth doing once — the resulting title pool is persisted, so later
    /// launches skip re-reading the whole corpus and just scan what is new.
    func warmNotionTitles(from files: [TranscriptFile], limit: Int = 400) {
        loadCacheIfNeeded()

        // With a populated pool from a previous run, restrict the scan to
        // transcripts we have never parsed rather than all of them.
        let pending: [TranscriptFile]
        if notionTitles.isEmpty {
            pending = files
        } else {
            pending = files.filter { digests[$0.path]?.fingerprint != $0.fingerprint }
        }
        guard !pending.isEmpty else { return }

        for file in pending.prefix(limit) {
            guard let reader = LineReader(path: file.path) else { continue }
            var found: [String: NotionRef] = [:]
            while let line = reader.next() {
                // No trailing slash in the probe: JSON-escaped URLs render as
                // "notion.so\/id", which a "notion.so/" check would miss.
                guard line.contains("notion.so") || line.contains("notion.com") else { continue }
                autoreleasepool {
                    if let text = String(data: line, encoding: .utf8) {
                        TranscriptParser.scanNotionURLs(in: text, into: &found, at: nil)
                    }
                }
            }
            for (id, ref) in found {
                if let title = ref.title, !title.isEmpty, notionTitles[id] == nil {
                    notionTitles[id] = title
                }
            }
        }
    }

    // MARK: - Cache persistence

    /// Bump when the digest shape changes, so stale entries are discarded
    /// instead of being trusted.
    private static let cacheSchemaVersion = 2

    private struct CacheFile: Codable {
        var version: Int?
        var digests: [String: CacheEntry]
        var notionTitles: [String: String]
    }
    private struct CacheEntry: Codable {
        var fingerprint: String
        var digest: TranscriptDigest
    }

    private var cacheURL: URL {
        cacheRoot.appendingPathComponent("digests.json")
    }

    private func loadCacheIfNeeded() {
        guard !loadedCache else { return }
        loadedCache = true
        guard let data = try? Data(contentsOf: cacheURL),
              let file = try? JSONDecoder().decode(CacheFile.self, from: data) else { return }
        guard file.version == Self.cacheSchemaVersion else {
            // Older layout: keep the pooled titles, re-parse the digests.
            notionTitles.merge(file.notionTitles) { current, _ in current }
            return
        }
        for (path, entry) in file.digests {
            digests[path] = (entry.fingerprint, entry.digest)
        }
        notionTitles.merge(file.notionTitles) { current, _ in current }
    }

    func persistCache() {
        let payload = CacheFile(
            version: Self.cacheSchemaVersion,
            digests: digests.mapValues { CacheEntry(fingerprint: $0.fingerprint, digest: $0.digest) },
            notionTitles: notionTitles
        )
        try? FileManager.default.createDirectory(
            at: cacheRoot, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }
}

// MARK: - Process → session correlation

/// Works out which transcript each running process is writing to.
///
/// Claude Code does not advertise its session id in the process table, but it
/// creates a per-session scratchpad directory at startup. That directory's
/// birth time matches the process start time to within a second, which makes it
/// a dependable join key. Verified against live instances during development.
enum SessionResolver {

    /// How far apart a process start and a session directory birth may be and
    /// still be considered the same session.
    static let birthTolerance: TimeInterval = 90

    struct Match: Sendable {
        var pid: Int32
        var sessionID: String
        var confidence: Confidence

        enum Confidence: Sendable, Comparable {
            case fallback      // newest transcript in the directory
            case birthTime     // scratchpad or session-env birth ≈ process start
            case explicit      // --resume gave us the id outright
        }
    }

    /// Assigns at most one session to each process, preferring stronger evidence
    /// and never handing the same session to two processes.
    static func resolve(processes: [ClaudeProcess], transcripts: [TranscriptFile]) -> [Int32: Match] {
        var candidates: [Match] = []

        let bySlug = Dictionary(grouping: transcripts, by: \.projectSlug)
        let knownSessions = Set(transcripts.map(\.sessionID))

        for process in processes {
            // 1. Explicit --resume wins outright.
            if let id = process.resumedSessionID, knownSessions.contains(id) {
                candidates.append(Match(pid: process.pid, sessionID: id, confidence: .explicit))
                continue
            }

            guard let cwd = process.cwd else { continue }
            let slug = ClaudePaths.slug(for: cwd)
            let inProject = bySlug[slug] ?? []
            guard !inProject.isEmpty else { continue }

            // 2. Directory birth time closest to the process start.
            if let id = birthTimeMatch(process: process, slug: slug, candidates: inProject) {
                candidates.append(Match(pid: process.pid, sessionID: id, confidence: .birthTime))
                continue
            }

            // 3. Fall back to the most recently written transcript in that directory.
            if let newest = inProject.max(by: { $0.modified < $1.modified }) {
                candidates.append(Match(pid: process.pid, sessionID: newest.sessionID,
                                        confidence: .fallback))
            }
        }

        // Strongest evidence first, so a confident claim beats a weak one.
        candidates.sort { $0.confidence > $1.confidence }

        var assigned: [Int32: Match] = [:]
        var claimed = Set<String>()
        for match in candidates {
            guard assigned[match.pid] == nil, !claimed.contains(match.sessionID) else { continue }
            assigned[match.pid] = match
            claimed.insert(match.sessionID)
        }
        return assigned
    }

    /// Looks for a session directory born at the same moment the process started.
    private static func birthTimeMatch(process: ClaudeProcess, slug: String,
                                       candidates: [TranscriptFile]) -> String? {
        let ids = Set(candidates.map(\.sessionID))
        var best: (id: String, delta: TimeInterval)?

        func consider(_ directory: URL) {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.creationDateKey]) else { return }
            for entry in entries {
                let id = entry.lastPathComponent
                guard ids.contains(id),
                      let birth = try? entry.resourceValues(forKeys: [.creationDateKey]).creationDate
                else { continue }
                let delta = abs(birth.timeIntervalSince(process.startedAt))
                guard delta <= birthTolerance else { continue }
                if best == nil || delta < best!.delta { best = (id, delta) }
            }
        }

        consider(ClaudePaths.scratchRoot.appendingPathComponent(slug))
        if best == nil { consider(ClaudePaths.sessionEnv) }

        return best?.id
    }
}

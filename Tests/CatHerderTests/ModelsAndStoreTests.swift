import Foundation
import Testing
@testable import CatHerder

@Suite("MonitoredSession")
struct MonitoredSessionTests {

    private func session(digest: TranscriptDigest,
                         process: ClaudeProcess? = nil,
                         git: GitInfo = .none) -> MonitoredSession {
        MonitoredSession(sessionID: digest.sessionID, digest: digest,
                         process: process, git: git, status: .ended)
    }

    @Test("prefers the generated title for its headline")
    func headlineFromTitle() {
        let digest = TranscriptDigest.stub(aiTitle: "Remove legacy uploader", openingPrompt: "please remove")
        #expect(session(digest: digest).headline == "Remove legacy uploader")
    }

    @Test("falls back to the opening prompt, then the session id")
    func headlineFallbacks() {
        let prompted = TranscriptDigest.stub(aiTitle: nil, openingPrompt: "do the thing")
        #expect(session(digest: prompted).headline == "do the thing")

        let bare = TranscriptDigest.stub(sessionID: "abcdef123456", aiTitle: nil, openingPrompt: nil)
        #expect(session(digest: bare).headline == "Session abcdef12")
    }

    @Test("truncates a long opening prompt for the headline")
    func headlineTruncation() {
        let long = String(repeating: "word ", count: 60)
        let digest = TranscriptDigest.stub(aiTitle: nil, openingPrompt: long)
        #expect(session(digest: digest).headline.hasSuffix("…"))
        #expect(session(digest: digest).headline.count <= 91)
    }

    @Test("uses the live working directory when a process is attached")
    func cwdPrefersProcess() {
        var digest = TranscriptDigest.stub()
        digest.cwd = "/old/path"
        let process = ClaudeProcess.stub(cwd: "/live/path")

        #expect(session(digest: digest, process: process).cwd == "/live/path")
        #expect(session(digest: digest).cwd == "/old/path")
        #expect(session(digest: digest, process: process).directoryName == "path")
    }

    @Test("reports process uptime while live and transcript span once ended")
    func duration() {
        // Fixed instants: deriving both from Date() leaves sub-microsecond
        // drift that makes an equality check flaky.
        var digest = TranscriptDigest.stub()
        digest.firstActivity = Date(timeIntervalSince1970: 1_000_000)
        digest.lastActivity = Date(timeIntervalSince1970: 1_000_300)

        #expect(session(digest: digest).duration == 300)

        let process = ClaudeProcess.stub(startedAt: Date().addingTimeInterval(-60))
        let live = session(digest: digest, process: process)
        #expect(live.isLive)
        #expect((live.duration ?? 0) >= 59)
    }
}

@Suite("Notion card selection")
struct NotionSelectionTests {

    private func session(refs: [NotionRef], title: String? = nil) -> MonitoredSession {
        let digest = TranscriptDigest.stub(aiTitle: title, notionRefs: refs)
        return MonitoredSession(sessionID: "S", digest: digest, process: nil,
                                git: .none, status: .ended)
    }

    private func ref(_ id: String, _ title: String?, _ source: NotionRefSource,
                     touches: Int = 1, seen: Date = .now) -> NotionRef {
        NotionRef(pageID: id, title: title, lastSeen: seen, source: source, touches: touches)
    }

    /// Regression: a link that merely appeared in output is not "the card".
    @Test("excludes mentions and slug-only links")
    func excludesWeakEvidence() {
        let session = session(refs: [
            ref("a", "Mentioned card", .mention, touches: 0),
            ref("b", "Linked card", .slugURL, touches: 0),
        ])
        #expect(session.workedNotionRefs.isEmpty)
        #expect(session.primaryNotionRef == nil)
    }

    @Test("keeps cards the session actually touched")
    func keepsWorkedCards() {
        let session = session(refs: [
            ref("a", "Mentioned", .mention, touches: 0),
            ref("b", "Worked", .toolCall, touches: 2),
        ])
        #expect(session.workedNotionRefs.map(\.pageID) == ["b"])
    }

    @Test("ranks by how often a card was touched")
    func ranksByTouches() {
        let session = session(refs: [
            ref("a", "Rarely touched", .toolCall, touches: 1),
            ref("b", "Often touched", .toolCall, touches: 9),
        ])
        #expect(session.primaryNotionRef?.pageID == "b")
    }

    /// A session that updates several cards should still surface the one it is
    /// actually about, which its own title names.
    @Test("a title matching the session subject outranks raw touch count")
    func subjectAffinityWins() {
        let session = session(refs: [
            ref("a", "API Client - Add request timeout to the token exchange", .confirmed, touches: 13),
            ref("b", "Reports App - Add date filtering to the monthly report admin",
                .confirmed, touches: 11),
        ], title: "Create User Scan Monthly Report admin API")

        #expect(session.primaryNotionRef?.pageID == "b")
    }

    @Test("falls back to recency when nothing else separates two cards")
    func recencyTiebreak() {
        let older = Date().addingTimeInterval(-3600)
        let session = session(refs: [
            ref("a", "One", .toolCall, touches: 3, seen: older),
            ref("b", "Two", .toolCall, touches: 3, seen: Date()),
        ])
        #expect(session.primaryNotionRef?.pageID == "b")
    }

    @Test("a single worked card is returned untouched by ranking")
    func singleCard() {
        let session = session(refs: [ref("a", "Only card", .toolCall, touches: 1)])
        #expect(session.primaryNotionRef?.pageID == "a")
    }
}

@Suite("Formatting")
struct FormattingTests {

    @Test("durations read compactly", arguments: [
        (0.0, "0s"), (45.0, "45s"), (90.0, "1m"), (3_600.0, "1h"),
        (5_400.0, "1h 30m"), (86_400.0, "1d"), (180_000.0, "2d 2h"),
    ])
    func durations(_ interval: TimeInterval, _ expected: String) {
        #expect(Fmt.duration(interval) == expected)
    }

    @Test("durations spell out in full form")
    func fullDurations() {
        #expect(Fmt.duration(5_400, style: .full) == "1 hour 30 min")
        #expect(Fmt.duration(30, style: .full) == "30 sec")
        #expect(Fmt.duration(172_800, style: .full) == "2 days")
    }

    @Test("absent or negative durations show a dash")
    func missingDurations() {
        #expect(Fmt.duration(nil) == "—")
        #expect(Fmt.duration(-5) == "—")
        #expect(Fmt.duration(.infinity) == "—")
    }

    @Test("relative times read naturally")
    func relative() {
        #expect(Fmt.relative(nil) == "—")
        #expect(Fmt.relative(Date()) == "just now")
        #expect(Fmt.relative(Date().addingTimeInterval(-120)) == "2m ago")
        #expect(Fmt.relative(Date().addingTimeInterval(-7_200)) == "2h ago")
    }

    @Test("home-relative paths are abbreviated")
    func paths() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(Fmt.tildePath("\(home)/Source/repo") == "~/Source/repo")
        #expect(Fmt.tildePath("/opt/elsewhere") == "/opt/elsewhere")
        #expect(Fmt.tildePath(nil) == "—")
    }

    @Test("token counts are abbreviated", arguments: [
        (0, "0"), (999, "999"), (1_500, "1.5k"), (250_000, "250.0k"), (1_400_000, "1.4M"),
    ])
    func tokens(_ count: Int, _ expected: String) {
        #expect(Fmt.tokens(count) == expected)
    }

    @Test("model identifiers are shortened", arguments: [
        ("claude-opus-5", "Opus 5"),
        ("claude-sonnet-5", "Sonnet 5"),
        ("us.anthropic.claude-opus-5", "Opus 5"),
        ("claude-haiku-4-5-20251001", "Haiku 4"),
    ])
    func models(_ raw: String, _ expected: String) {
        #expect(Fmt.model(raw) == expected)
    }

    @Test("an absent model shows a dash")
    func missingModel() {
        #expect(Fmt.model(nil) == "—")
    }

    @Test("first line truncation respects the limit")
    func firstLine() {
        #expect("one\ntwo\nthree".firstLine(max: 40) == "one")
        #expect("  padded  ".firstLine(max: 40) == "padded")
        let long = String(repeating: "x", count: 100)
        #expect(long.firstLine(max: 10) == String(repeating: "x", count: 10) + "…")
    }
}

@Suite("Session store")
struct SessionStoreTests {

    /// Builds a fixture ~/.claude/projects tree.
    private func makeProjects(_ temp: TempDirectory) -> URL {
        let projects = temp.makeDirectory("projects")
        let project = projects.appendingPathComponent("-tmp-proj", isDirectory: true)
        try? FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        let records = [
            Rec.userPrompt("hello", at: "2026-08-01T10:00:00.000Z"),
            Rec.assistant(at: "2026-08-01T10:00:30.000Z", stopReason: "end_turn"),
            Rec.aiTitle("Fixture session"),
        ].joined(separator: "\n")
        try? records.write(to: project.appendingPathComponent("sess-1.jsonl"),
                           atomically: true, encoding: .utf8)
        // A non-transcript file that must be ignored.
        try? "ignore me".write(to: project.appendingPathComponent("notes.txt"),
                               atomically: true, encoding: .utf8)
        return projects
    }

    @Test("indexes transcripts and ignores other files")
    func index() async throws {
        let temp = TempDirectory()
        let store = SessionStore(projectsRoot: makeProjects(temp),
                                 cacheRoot: temp.makeDirectory("cache"))

        let files = await store.index()
        #expect(files.count == 1)
        let file = try #require(files.first)
        #expect(file.sessionID == "sess-1")
        #expect(file.projectSlug == "-tmp-proj")
        #expect(file.size > 0)
    }

    @Test("returns an empty index when the projects directory is absent")
    func missingProjects() async {
        let temp = TempDirectory()
        let store = SessionStore(projectsRoot: temp.url.appendingPathComponent("nope"),
                                 cacheRoot: temp.makeDirectory("cache"))
        #expect(await store.index().isEmpty)
    }

    @Test("parses a digest and serves it from cache afterwards")
    func digestCaching() async throws {
        let temp = TempDirectory()
        let store = SessionStore(projectsRoot: makeProjects(temp),
                                 cacheRoot: temp.makeDirectory("cache"))

        let file = try #require(await store.index().first)
        let first = await store.digest(for: file)
        #expect(first.aiTitle == "Fixture session")

        // Same fingerprint → same digest, without re-reading the file.
        let second = await store.digest(for: file)
        #expect(second == first)
    }

    @Test("a changed transcript is re-parsed")
    func reparsesOnChange() async throws {
        let temp = TempDirectory()
        let projects = makeProjects(temp)
        let store = SessionStore(projectsRoot: projects, cacheRoot: temp.makeDirectory("cache"))

        let original = try #require(await store.index().first)
        _ = await store.digest(for: original)

        // Append a new title, so size and mtime both change.
        let path = projects.appendingPathComponent("-tmp-proj/sess-1.jsonl")
        let updated = (try String(contentsOf: path, encoding: .utf8)) + "\n"
            + Rec.aiTitle("Renamed session") + "\n"
        try updated.write(to: path, atomically: true, encoding: .utf8)

        let refreshed = try #require(await store.index().first)
        #expect(refreshed.fingerprint != original.fingerprint)
        #expect(await store.digest(for: refreshed).aiTitle == "Renamed session")
    }

    @Test("persists digests across instances")
    func cachePersistence() async throws {
        let temp = TempDirectory()
        let projects = makeProjects(temp)
        let cache = temp.makeDirectory("cache")

        let first = SessionStore(projectsRoot: projects, cacheRoot: cache)
        let file = try #require(await first.index().first)
        _ = await first.digest(for: file)
        await first.persistCache()

        #expect(FileManager.default.fileExists(
            atPath: cache.appendingPathComponent("digests.json").path))

        // A fresh store reads the persisted digest back.
        let second = SessionStore(projectsRoot: projects, cacheRoot: cache)
        #expect(await second.digest(for: file).aiTitle == "Fixture session")
    }

    /// A title seen in one transcript should name a card referenced only by id
    /// in another.
    @Test("pools Notion titles across transcripts")
    func pooledTitles() async throws {
        let temp = TempDirectory()
        let projects = temp.makeDirectory("projects")
        let project = projects.appendingPathComponent("-tmp-proj", isDirectory: true)
        try? FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        let pageID = "3b5ba7700d1e809e8b3fdf8150fc2882"

        // One session names the card via a slugged URL.
        try (Rec.toolResult("https://www.notion.so/XY-Remove-legacy-uploader-\(pageID)",
                            toolUseID: "t1", at: "2026-08-01T10:00:00.000Z") + "\n")
            .write(to: project.appendingPathComponent("namer.jsonl"),
                   atomically: true, encoding: .utf8)

        // Another only ever passes the bare id to a tool.
        try (Rec.assistant(tools: [Rec.tool("mcp__plugin_Notion_notion__notion-fetch",
                                            input: ["id": pageID])],
                           at: "2026-08-02T10:00:00.000Z") + "\n")
            .write(to: project.appendingPathComponent("user.jsonl"),
                   atomically: true, encoding: .utf8)

        let store = SessionStore(projectsRoot: projects, cacheRoot: temp.makeDirectory("cache"))
        let files = await store.index()
        await store.warmNotionTitles(from: files)

        let bare = try #require(files.first { $0.sessionID == "user" })
        let digest = await store.digest(for: bare)
        #expect(digest.notionRefs.first?.title == "XY - Remove legacy uploader")
    }
}

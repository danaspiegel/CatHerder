import Foundation
import Testing
@testable import CatHerder

@Suite("Session status policy")
struct SessionStatusPolicyTests {

    /// The chosen policy biases toward Working; these pin that behaviour down.

    @Test("recent transcript activity means working")
    func recentActivity() {
        let digest = TranscriptDigest.stub(lastActivity: Date(), endsAwaitingUser: true)
        #expect(SessionStatusPolicy.classify(digest: digest, process: .stub()) == .working)
    }

    @Test("real CPU use means working even when the transcript is old")
    func cpuBusy() {
        let digest = TranscriptDigest.stub(
            lastActivity: Date().addingTimeInterval(-86_400), endsAwaitingUser: true)
        let process = ClaudeProcess.stub(cpu: SessionStatusPolicy.busyCPUPercent + 1)
        #expect(SessionStatusPolicy.classify(digest: digest, process: process) == .working)
    }

    /// A long build writes nothing for minutes; treating that as idle would be
    /// the more costly mistake.
    @Test("a transcript that stops mid-turn stays working however long it is quiet")
    func midTurnStaysWorking() {
        let digest = TranscriptDigest.stub(
            lastActivity: Date().addingTimeInterval(-6 * 3600), endsAwaitingUser: false)
        #expect(SessionStatusPolicy.classify(digest: digest, process: .stub()) == .working)
    }

    @Test("Claude ending its turn past the grace window means it needs you")
    func awaitingInput() {
        let past = Date().addingTimeInterval(-SessionStatusPolicy.workingGrace - 60)
        let digest = TranscriptDigest.stub(lastActivity: past, endsAwaitingUser: true)
        #expect(SessionStatusPolicy.classify(digest: digest, process: .stub()) == .awaitingInput)
    }

    @Test("inside the grace window it still reads as working")
    func withinGrace() {
        let recent = Date().addingTimeInterval(-SessionStatusPolicy.workingGrace + 60)
        let digest = TranscriptDigest.stub(lastActivity: recent, endsAwaitingUser: true)
        #expect(SessionStatusPolicy.classify(digest: digest, process: .stub()) == .working)
    }

    @Test("a freshly launched instance with no transcript is working")
    func justLaunched() {
        let digest = TranscriptDigest.stub(lastActivity: nil)
        let process = ClaudeProcess.stub(startedAt: Date())
        #expect(SessionStatusPolicy.classify(digest: digest, process: process) == .working)
    }

    /// Opened a terminal, ran claude, never typed anything.
    @Test("an instance that never produced a transcript eventually reads idle")
    func neverUsed() {
        let digest = TranscriptDigest.stub(lastActivity: nil)
        let process = ClaudeProcess.stub(
            startedAt: Date().addingTimeInterval(-SessionStatusPolicy.unusedAfter - 60))
        #expect(SessionStatusPolicy.classify(digest: digest, process: process) == .idle)
    }

    @Test("every status has a label and a symbol")
    func presentation() {
        for status in SessionStatus.allCases {
            #expect(!status.label.isEmpty)
            #expect(!status.symbol.isEmpty)
        }
    }
}

@Suite("Process to session resolution")
struct SessionResolverTests {

    private func transcript(_ id: String, project: String = "-tmp-proj",
                            modified: Date = Date()) -> TranscriptFile {
        TranscriptFile(path: "/tmp/\(id).jsonl", sessionID: id,
                       projectSlug: project, size: 10, modified: modified)
    }

    @Test("an explicit --resume wins outright")
    func explicitResume() throws {
        let files = [transcript("aaa"), transcript("bbb")]
        let process = ClaudeProcess.stub(pid: 1, cwd: "/tmp/proj", resumed: "bbb")

        let matches = SessionResolver.resolve(processes: [process], transcripts: files)
        let match = try #require(matches[1])
        #expect(match.sessionID == "bbb")
        #expect(match.confidence == .explicit)
    }

    @Test("an unknown resume id falls through to other evidence")
    func unknownResumeID() {
        let files = [transcript("aaa")]
        let process = ClaudeProcess.stub(pid: 1, cwd: "/tmp/proj", resumed: "does-not-exist")

        let matches = SessionResolver.resolve(processes: [process], transcripts: files)
        // Slug for /tmp/proj is "-tmp-proj", so the fallback still applies.
        #expect(matches[1]?.sessionID == "aaa")
        #expect(matches[1]?.confidence == .fallback)
    }

    @Test("falls back to the most recently written transcript in the directory")
    func newestFallback() throws {
        let older = transcript("old", modified: Date().addingTimeInterval(-3600))
        let newer = transcript("new", modified: Date())
        let process = ClaudeProcess.stub(pid: 1, cwd: "/tmp/proj")

        let matches = SessionResolver.resolve(processes: [process], transcripts: [older, newer])
        #expect(try #require(matches[1]).sessionID == "new")
    }

    @Test("ignores transcripts from another directory")
    func differentProject() {
        let elsewhere = transcript("other", project: "-tmp-somewhere-else")
        let process = ClaudeProcess.stub(pid: 1, cwd: "/tmp/proj")

        #expect(SessionResolver.resolve(processes: [process], transcripts: [elsewhere]).isEmpty)
    }

    /// Two instances in one directory must not both claim the same transcript.
    @Test("never assigns one session to two processes")
    func noDoubleClaim() {
        let files = [transcript("aaa"), transcript("bbb")]
        let processes = [
            ClaudeProcess.stub(pid: 1, cwd: "/tmp/proj"),
            ClaudeProcess.stub(pid: 2, cwd: "/tmp/proj"),
        ]
        let matches = SessionResolver.resolve(processes: processes, transcripts: files)
        let claimed = matches.values.map(\.sessionID)

        #expect(Set(claimed).count == claimed.count)
    }

    @Test("stronger evidence beats a competing weak claim")
    func confidenceOrdering() throws {
        // Both processes are in the same directory; only one names its session.
        // Fixed mtimes: deriving them from Date() makes which transcript counts
        // as "newest" depend on clock resolution.
        let files = [
            transcript("aaa", modified: Date(timeIntervalSince1970: 1_000)),
            transcript("bbb", modified: Date(timeIntervalSince1970: 2_000)),
        ]
        let explicit = ClaudeProcess.stub(pid: 1, cwd: "/tmp/proj", resumed: "bbb")
        let guessing = ClaudeProcess.stub(pid: 2, cwd: "/tmp/proj")

        let matches = SessionResolver.resolve(processes: [guessing, explicit], transcripts: files)
        #expect(try #require(matches[1]).sessionID == "bbb")   // explicit keeps its claim

        // The guesser's one candidate was the newest transcript, which the
        // explicit claim took. Each process produces a single candidate, so it
        // is left unresolved rather than assigned a session it may not own —
        // the app then shows it as a running instance with no transcript yet.
        #expect(matches[2] == nil)
    }

    @Test("a process without a working directory resolves to nothing")
    func noWorkingDirectory() {
        let process = ClaudeProcess.stub(pid: 1, cwd: nil)
        #expect(SessionResolver.resolve(
            processes: [process], transcripts: [transcript("aaa")]).isEmpty)
    }

    /// The strongest signal in practice: a scratchpad directory created within a
    /// second of the process starting.
    @Test("matches a session directory born alongside the process")
    func birthTimeMatch() throws {
        let temp = TempDirectory()
        let slug = ClaudePaths.slug(for: temp.url.path)
        let scratchRoot = ClaudePaths.scratchRoot.appendingPathComponent(slug)
        try? FileManager.default.createDirectory(at: scratchRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratchRoot) }

        // Created now, so its birth time is within tolerance of a process
        // started now — which is exactly the real-world signal.
        let sessionID = "birth-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(
            at: scratchRoot.appendingPathComponent(sessionID), withIntermediateDirectories: true)

        let files = [
            TranscriptFile(path: "/tmp/\(sessionID).jsonl", sessionID: sessionID,
                           projectSlug: slug, size: 1,
                           modified: Date().addingTimeInterval(-9999)),
            // A far more recently modified decoy the fallback would prefer.
            TranscriptFile(path: "/tmp/decoy.jsonl", sessionID: "decoy",
                           projectSlug: slug, size: 1, modified: Date()),
        ]
        let process = ClaudeProcess.stub(pid: 1, startedAt: Date(), cwd: temp.url.path)

        let match = try #require(SessionResolver.resolve(
            processes: [process], transcripts: files)[1])
        #expect(match.sessionID == sessionID)
        #expect(match.confidence == .birthTime)
    }
}

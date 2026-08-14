import Foundation
import Testing
@testable import CatHerder

// MARK: - Timestamps

@Suite("ISO8601 parsing")
struct ISO8601Tests {

    /// The hand-rolled parser has to agree with Foundation's, which is the
    /// reference it replaced for speed.
    @Test("agrees with ISO8601DateFormatter", arguments: [
        "2026-07-27T16:41:32.465Z",
        "2026-01-01T00:00:00.000Z",
        "2024-02-29T23:59:59.999Z",   // leap day
        "2000-02-29T12:00:00.000Z",   // century leap year
        "1970-01-01T00:00:00.000Z",   // epoch
        "2026-12-31T23:00:00Z",       // no fractional seconds
    ])
    func matchesFoundation(_ input: String) {
        let reference = ISO8601DateFormatter()
        reference.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]

        let expected = reference.date(from: input) ?? plain.date(from: input)
        let actual = ISO8601.date(from: input)

        #expect(actual != nil)
        // Sub-second precision is deliberately discarded.
        #expect(abs(actual!.timeIntervalSince(expected!)) < 1.0)
    }

    @Test("rejects malformed input", arguments: ["", "not-a-date", "2026", "2026-13"])
    func rejectsGarbage(_ input: String) {
        #expect(ISO8601.date(from: input) == nil)
    }

    @Test("rejects out-of-range month and day")
    func rejectsImpossibleDates() {
        #expect(ISO8601.date(from: "2026-13-01T00:00:00Z") == nil)
        #expect(ISO8601.date(from: "2026-01-00T00:00:00Z") == nil)
    }

    @Test("ordering is preserved across a year boundary")
    func ordering() throws {
        let earlier = try #require(ISO8601.date(from: "2025-12-31T23:59:59Z"))
        let later = try #require(ISO8601.date(from: "2026-01-01T00:00:00Z"))
        #expect(later > earlier)
        #expect(later.timeIntervalSince(earlier) == 1)
    }
}

// MARK: - Line reading

@Suite("LineReader")
struct LineReaderTests {

    @Test("splits lines that straddle chunk boundaries")
    func chunkBoundaries() throws {
        let temp = TempDirectory()
        // Lines much longer than the chunk size force refills mid-line.
        let lines = (0..<50).map { "line-\($0)-" + String(repeating: "x", count: 500) }
        let file = temp.write(lines.joined(separator: "\n"), to: "big.txt")

        let reader = try #require(LineReader(path: file.path, chunkSize: 64))
        var read: [String] = []
        while let data = reader.next() {
            read.append(String(data: data, encoding: .utf8)!)
        }
        #expect(read == lines)
    }

    @Test("handles a missing trailing newline")
    func noTrailingNewline() throws {
        let temp = TempDirectory()
        let file = temp.write("a\nb\nc", to: "x.txt")
        let reader = try #require(LineReader(path: file.path, chunkSize: 2))
        var read: [String] = []
        while let data = reader.next() { read.append(String(data: data, encoding: .utf8)!) }
        #expect(read == ["a", "b", "c"])
    }

    @Test("preserves empty lines")
    func emptyLines() throws {
        let temp = TempDirectory()
        let file = temp.write("a\n\nb\n", to: "x.txt")
        let reader = try #require(LineReader(path: file.path, chunkSize: 4))
        var read: [String] = []
        while let data = reader.next() { read.append(String(data: data, encoding: .utf8)!) }
        #expect(read == ["a", "", "b"])
    }

    @Test("returns nil for a missing file")
    func missingFile() {
        #expect(LineReader(path: "/nonexistent/nope.jsonl") == nil)
    }
}

// MARK: - Byte search

@Suite("Data.contains")
struct DataContainsTests {

    @Test func findsNeedleAnywhere() {
        let haystack = Data("the quick notion.so/abc fox".utf8)
        #expect(haystack.contains("notion.so/"))
        #expect(haystack.contains("the"))
        #expect(haystack.contains("fox"))
        #expect(!haystack.contains("airtable"))
    }

    @Test func handlesEdgeCases() {
        #expect(!Data().contains("x"))
        #expect(!Data("ab".utf8).contains("abc"))   // needle longer than haystack
        // A partial match that restarts must still find the real one.
        #expect(Data("aab".utf8).contains("ab"))
    }
}

// MARK: - Digest extraction

@Suite("TranscriptParser.digest")
struct DigestTests {

    /// A representative session: two prompts, edits, a PR, a title.
    private func makeTranscript(in temp: TempDirectory) -> String {
        temp.writeTranscript([
            Rec.mode(),
            Rec.userPrompt("build the thing", at: "2026-08-01T10:00:00.000Z"),
            Rec.assistant(tools: [Rec.tool("Edit", input: ["file_path": "/tmp/proj/a.swift"])],
                          at: "2026-08-01T10:00:30.000Z", outputTokens: 100),
            Rec.assistant(tools: [Rec.tool("Bash", input: ["command": "ls"])],
                          at: "2026-08-01T10:01:00.000Z", outputTokens: 50),
            Rec.aiTitle("Build the thing"),
            Rec.prLink(number: 42, repository: "org/repo"),
            Rec.userPrompt("now ship it", at: "2026-08-01T10:02:00.000Z"),
            Rec.assistant(tools: [], at: "2026-08-01T10:02:30.000Z",
                          stopReason: "end_turn", outputTokens: 25),
        ])
    }

    @Test("extracts session context")
    func context() {
        let temp = TempDirectory()
        let digest = TranscriptParser.digest(path: makeTranscript(in: temp), sessionID: "S")

        #expect(digest.sessionID == "S")
        #expect(digest.cwd == "/tmp/proj")
        #expect(digest.gitBranchAtEnd == "main")
        #expect(digest.aiTitle == "Build the thing")
        #expect(digest.lastModel == "claude-opus-5")
        #expect(digest.permissionMode == "default")
    }

    @Test("counts turns, tokens and tools")
    func counts() {
        let temp = TempDirectory()
        let digest = TranscriptParser.digest(path: makeTranscript(in: temp), sessionID: "S")

        #expect(digest.userMessageCount == 2)
        #expect(digest.assistantMessageCount == 3)
        #expect(digest.outputTokens == 175)
        #expect(digest.toolCounts["Edit"] == 1)
        #expect(digest.toolCounts["Bash"] == 1)
    }

    @Test("captures prompts newest-first with the opening prompt kept")
    func prompts() {
        let temp = TempDirectory()
        let digest = TranscriptParser.digest(path: makeTranscript(in: temp), sessionID: "S")

        #expect(digest.recentPrompts.first == "now ship it")
        #expect(digest.recentPrompts.count == 2)
        #expect(digest.openingPrompt == "build the thing")
    }

    @Test("records timestamps and pull requests")
    func timestampsAndPRs() throws {
        let temp = TempDirectory()
        let digest = TranscriptParser.digest(path: makeTranscript(in: temp), sessionID: "S")

        #expect(digest.firstActivity == ISO8601.date(from: "2026-08-01T10:00:00Z"))
        #expect(digest.lastActivity == ISO8601.date(from: "2026-08-01T10:02:30Z"))
        #expect(digest.span == 150)

        let pr = try #require(digest.pullRequests.first)
        #expect(pr.number == 42)
        #expect(pr.repository == "org/repo")
        #expect(digest.pullRequests.count == 1)
    }

    @Test("ends awaiting the user after a closing end_turn")
    func awaitingUser() {
        let temp = TempDirectory()
        let digest = TranscriptParser.digest(path: makeTranscript(in: temp), sessionID: "S")
        #expect(digest.endsAwaitingUser)
    }

    @Test("does not await the user when the transcript stops mid-tool-call")
    func midTurn() {
        let temp = TempDirectory()
        let path = temp.writeTranscript([
            Rec.userPrompt("go", at: "2026-08-01T10:00:00.000Z"),
            Rec.assistant(tools: [Rec.tool("Bash", input: ["command": "sleep 600"])],
                          at: "2026-08-01T10:00:05.000Z", stopReason: "tool_use"),
        ])
        #expect(!TranscriptParser.digest(path: path, sessionID: "S").endsAwaitingUser)
    }

    /// Working time should ignore the hours a session sat idle overnight.
    @Test("active time excludes gaps longer than the idle threshold")
    func activeTimeExcludesGaps() {
        let temp = TempDirectory()
        let path = temp.writeTranscript([
            Rec.userPrompt("a", at: "2026-08-01T10:00:00.000Z"),
            Rec.assistant(at: "2026-08-01T10:01:00.000Z"),          // +60s counted
            Rec.userPrompt("b", at: "2026-08-01T14:00:00.000Z"),    // 4h gap ignored
            Rec.assistant(at: "2026-08-01T14:00:30.000Z"),          // +30s counted
        ])
        let digest = TranscriptParser.digest(path: path, sessionID: "S")

        #expect(digest.activeSeconds == 90)
        #expect(digest.span == 14_430)   // full wall-clock span is much larger
    }

    @Test("ignores sidechain and meta messages when collecting prompts")
    func filtersNonHumanPrompts() {
        let temp = TempDirectory()
        let path = temp.writeTranscript([
            Rec.userPrompt("real prompt", at: "2026-08-01T10:00:00.000Z"),
            Rec.userPrompt("subagent instruction", at: "2026-08-01T10:00:10.000Z", sidechain: true),
            Rec.userPrompt("meta note", at: "2026-08-01T10:00:20.000Z", meta: true),
        ])
        let digest = TranscriptParser.digest(path: path, sessionID: "S")

        #expect(digest.recentPrompts == ["real prompt"])
        #expect(digest.userMessageCount == 2)   // meta counts as a turn, sidechain does not
    }

    @Test("counts subagents launched")
    func agents() {
        let temp = TempDirectory()
        let path = temp.writeTranscript([
            Rec.assistant(tools: [Rec.tool("Agent", input: ["prompt": "go"])],
                          at: "2026-08-01T10:00:00.000Z"),
            Rec.assistant(tools: [Rec.tool("Task", input: ["prompt": "go"])],
                          at: "2026-08-01T10:00:10.000Z"),
            Rec.assistant(tools: [Rec.tool("Bash", input: ["command": "ls"])],
                          at: "2026-08-01T10:00:20.000Z"),
        ])
        #expect(TranscriptParser.digest(path: path, sessionID: "S").agentsLaunched == 2)
    }

    /// A file edited repeatedly should appear once, at its most recent position.
    @Test("deduplicates edited files, most recent first")
    func editedFileDeduplication() {
        let temp = TempDirectory()
        let path = temp.writeTranscript([
            Rec.assistant(tools: [Rec.tool("Edit", input: ["file_path": "/p/a.swift"])],
                          at: "2026-08-01T10:00:00.000Z"),
            Rec.assistant(tools: [Rec.tool("Write", input: ["file_path": "/p/b.swift"])],
                          at: "2026-08-01T10:00:10.000Z"),
            Rec.assistant(tools: [Rec.tool("Edit", input: ["file_path": "/p/a.swift"])],
                          at: "2026-08-01T10:00:20.000Z"),
        ])
        let digest = TranscriptParser.digest(path: path, sessionID: "S")

        #expect(digest.editedFiles == ["/p/a.swift", "/p/b.swift"])
    }

    @Test("caps retained edited files")
    func editedFileLimit() {
        let temp = TempDirectory()
        let records = (0..<60).map { index in
            Rec.assistant(tools: [Rec.tool("Edit", input: ["file_path": "/p/f\(index).swift"])],
                          at: "2026-08-01T10:00:00.000Z")
        }
        let digest = TranscriptParser.digest(path: temp.writeTranscript(records), sessionID: "S")

        #expect(digest.editedFiles.count == TranscriptParser.editedFileLimit)
        // The most recent edit survives; the oldest is dropped.
        #expect(digest.editedFiles.first == "/p/f59.swift")
        #expect(!digest.editedFiles.contains("/p/f0.swift"))
    }

    @Test("truncates long prompts so the cache stays small")
    func promptTruncation() {
        let temp = TempDirectory()
        let long = String(repeating: "y", count: 900)
        let path = temp.writeTranscript([Rec.userPrompt(long, at: "2026-08-01T10:00:00.000Z")])
        let digest = TranscriptParser.digest(path: path, sessionID: "S")

        #expect(digest.recentPrompts[0].count == TranscriptParser.promptExcerptLimit + 1) // + ellipsis
        #expect(digest.openingPrompt?.count == TranscriptParser.promptExcerptLimit)
    }

    @Test("collects skills and MCP servers")
    func attribution() {
        let temp = TempDirectory()
        let path = temp.writeTranscript([
            Rec.assistant(at: "2026-08-01T10:00:00.000Z", skill: "code-review",
                          mcpServer: "plugin:Notion:notion"),
            Rec.assistant(at: "2026-08-01T10:00:10.000Z", skill: "code-review"),
        ])
        let digest = TranscriptParser.digest(path: path, sessionID: "S")

        #expect(digest.skillsUsed == ["code-review"])
        #expect(digest.mcpServers == ["plugin:Notion:notion"])
    }

    @Test("survives malformed lines")
    func malformedLines() {
        let temp = TempDirectory()
        let path = temp.writeTranscript([
            "{ not json",
            "",
            Rec.userPrompt("still parsed", at: "2026-08-01T10:00:00.000Z"),
        ])
        let digest = TranscriptParser.digest(path: path, sessionID: "S")

        #expect(digest.recentPrompts == ["still parsed"])
    }

    @Test("returns an empty digest for a missing file")
    func missingFile() {
        let digest = TranscriptParser.digest(path: "/nonexistent/x.jsonl", sessionID: "S")
        #expect(digest.userMessageCount == 0)
        #expect(digest.lastActivity == nil)
    }
}

// MARK: - Tool names

@Suite("Tool name shortening")
struct ToolNameTests {

    @Test(arguments: [
        ("mcp__plugin_Notion_notion__notion-fetch", "notion-fetch"),
        ("mcp__claude-in-chrome__navigate", "navigate"),
        ("Bash", "Bash"),
        ("Edit", "Edit"),
    ])
    func shortens(_ raw: String, _ expected: String) {
        #expect(TranscriptParser.shortToolName(raw) == expected)
    }
}

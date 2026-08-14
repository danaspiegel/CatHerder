import Foundation

// MARK: - Status

/// How a session currently stands. Live sessions get `working`/`awaitingInput`/`idle`;
/// transcripts with no backing process are `ended`.
enum SessionStatus: String, Sendable, CaseIterable {
    case working        // actively producing output right now
    case awaitingInput  // process alive, last turn ended with Claude waiting on you
    case idle           // process alive but quiet for a while
    case ended          // no process; historical

    var label: String {
        switch self {
        case .working: "Working"
        case .awaitingInput: "Needs you"
        case .idle: "Idle"
        case .ended: "Ended"
        }
    }

    var symbol: String {
        switch self {
        case .working: "play.circle.fill"
        case .awaitingInput: "exclamationmark.bubble.fill"
        case .idle: "pause.circle.fill"
        case .ended: "checkmark.circle"
        }
    }
}

// MARK: - Notion

/// How strongly a Notion reference indicates the session is actually working
/// on that card. A page id passed to `notion-update-page` means real work; a
/// notion.so link that merely appeared in some command output does not.
enum NotionRefSource: Int, Sendable, Codable, Comparable {
    /// A URL that happened to appear in text, tool output, or a search result.
    case mention = 0
    /// A slugged URL, which at least names the page.
    case slugURL = 1
    /// Passed to a Notion tool call — the session actively touched this page.
    case toolCall = 2
    /// Fetched or updated, with the title confirmed by the tool's own response.
    case confirmed = 3

    static func < (lhs: NotionRefSource, rhs: NotionRefSource) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct NotionRef: Sendable, Hashable, Identifiable, Codable {
    /// 32-char dashless Notion page id.
    var pageID: String
    /// Human title, when we could recover one from a slugged URL or a tool response.
    var title: String?
    /// When this card was last touched in the transcript.
    var lastSeen: Date
    /// Strongest evidence seen for this reference.
    var source: NotionRefSource = .mention
    /// How many times the session interacted with this card. The card a session
    /// is *about* is normally the one it returns to, not merely the last one
    /// it touched on the way out.
    var touches: Int = 1

    var id: String { pageID }

    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        return "Notion card \(pageID.prefix(8))"
    }

    var url: URL? {
        URL(string: "https://www.notion.so/\(pageID)")
    }
}

// MARK: - Pull requests

struct PullRequestRef: Sendable, Hashable, Identifiable, Codable {
    var number: Int
    var repository: String
    var url: String
    var lastSeen: Date

    var id: String { "\(repository)#\(number)" }
    var display: String { "\(repository)#\(number)" }
}

// MARK: - Git

struct GitInfo: Sendable, Hashable, Codable {
    /// Repository root directory name, e.g. "acme-web".
    var repoName: String?
    /// Absolute path of the repository root.
    var repoRoot: String?
    /// Current branch, or nil when detached / not a repo.
    var branch: String?
    /// True when the working directory is a linked worktree rather than the main checkout.
    var isWorktree: Bool = false

    var isRepo: Bool { repoRoot != nil }

    static let none = GitInfo()
}

// MARK: - Transcript digest

/// Everything we mine out of one session transcript. Cached by (path, size, mtime).
struct TranscriptDigest: Sendable, Hashable, Codable {
    var sessionID: String
    var path: String

    var cwd: String?
    var gitBranchAtEnd: String?

    var firstActivity: Date?
    var lastActivity: Date?

    /// Claude Code's own generated one-liner for the session.
    var aiTitle: String?
    /// The name the user gave the session with `/rename`, if any.
    var customName: String?
    /// Most recent human prompts, newest first.
    var recentPrompts: [String] = []
    /// The very first human prompt — usually the clearest statement of intent.
    var openingPrompt: String?

    var notionRefs: [NotionRef] = []
    var pullRequests: [PullRequestRef] = []

    /// Files created or modified, most recent first.
    var editedFiles: [String] = []
    /// Tool-use counts, e.g. ["Bash": 42, "Edit": 17].
    var toolCounts: [String: Int] = [:]
    var skillsUsed: [String] = []
    var mcpServers: [String] = []

    var userMessageCount: Int = 0
    var assistantMessageCount: Int = 0
    /// Number of subagents launched (Agent/Task tool calls).
    var agentsLaunched: Int = 0
    var outputTokens: Int = 0
    var lastModel: String?
    var permissionMode: String?

    /// Timestamps of every record, used to compute genuine working time.
    var activeSeconds: TimeInterval = 0

    /// Whether the last substantive record was Claude finishing its turn (so you are up next).
    var endsAwaitingUser: Bool = false

    /// Wall-clock span from first to last activity.
    var span: TimeInterval? {
        guard let f = firstActivity, let l = lastActivity else { return nil }
        return max(0, l.timeIntervalSince(f))
    }

    static func empty(sessionID: String, path: String) -> TranscriptDigest {
        TranscriptDigest(sessionID: sessionID, path: path)
    }
}

// MARK: - Terminal

struct TerminalRef: Sendable, Hashable, Codable {
    /// e.g. "/dev/ttys015"
    var tty: String?
    /// TERM_PROGRAM, e.g. "Apple_Terminal", "iTerm.app", "ghostty"
    var program: String?
    /// TERM_SESSION_ID, when the emulator exports one.
    var sessionID: String?

    var canActivateTab: Bool {
        guard tty != nil, let program else { return false }
        return TerminalActivator.Emulator(termProgram: program)?.supportsTTYLookup ?? false
    }

    var displayName: String {
        guard let program else { return "Unknown terminal" }
        return TerminalActivator.Emulator(termProgram: program)?.displayName ?? program
    }
}

// MARK: - Live process

struct ClaudeProcess: Sendable, Hashable, Identifiable {
    var pid: Int32
    var parentPID: Int32
    var startedAt: Date
    var cwd: String?
    var command: String
    var terminal: TerminalRef
    /// Session id parsed straight out of `--resume <id>`, when present.
    var resumedSessionID: String?
    /// CPU percentage, a useful hint that the instance is mid-thought.
    var cpuPercent: Double = 0

    var id: Int32 { pid }

    var uptime: TimeInterval { Date().timeIntervalSince(startedAt) }
}

// MARK: - The unified row the UI binds to

struct MonitoredSession: Sendable, Identifiable {
    var sessionID: String
    var digest: TranscriptDigest
    var process: ClaudeProcess?
    var git: GitInfo
    var status: SessionStatus

    var id: String { sessionID }

    var isLive: Bool { process != nil }

    var cwd: String? { process?.cwd ?? digest.cwd }

    var directoryName: String {
        guard let cwd else { return "unknown" }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }

    var lastActivity: Date? { digest.lastActivity }

    /// For live sessions this is process uptime; for history it is the transcript span.
    var duration: TimeInterval? {
        if let process { return process.uptime }
        return digest.span
    }

    /// Cards the session actually opened or edited, best candidate first. Links
    /// that merely appeared in output are excluded — otherwise any session that
    /// happened to print a Notion URL would look like it was working a card.
    ///
    /// A busy session often touches several cards (updating a status here,
    /// linking a PR there), so ranking blends how often a card was touched with
    /// how well its title matches what the session is actually about.
    var workedNotionRefs: [NotionRef] {
        let worked = digest.notionRefs.filter { $0.source >= .toolCall }
        guard worked.count > 1 else { return worked }

        let subjectParts: [String] = [digest.aiTitle, digest.openingPrompt].compactMap { $0 }
        let subject: Set<String> = Self.significantWords(in: subjectParts.joined(separator: " "))

        var scored: [(ref: NotionRef, score: Double)] = []
        scored.reserveCapacity(worked.count)
        for ref in worked {
            scored.append((ref, Self.score(ref, against: subject)))
        }
        scored.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.ref.lastSeen > rhs.ref.lastSeen
        }
        return scored.map(\.ref)
    }

    /// Touch count, plus a bonus when the card's title echoes the session subject.
    private static func score(_ ref: NotionRef, against subject: Set<String>) -> Double {
        var score = Double(ref.touches)
        if ref.source == .confirmed { score += 0.5 }
        guard !subject.isEmpty, let title = ref.title else { return score }
        let overlap = significantWords(in: title).intersection(subject).count
        // Two or more shared distinctive words is a strong signal that this is
        // the card the session was opened to work on.
        score += Double(overlap) * 3
        return score
    }

    /// Lowercased words long enough to carry meaning, minus common filler.
    private static func significantWords(in text: String) -> Set<String> {
        let stop: Set<String> = [
            "the", "and", "for", "with", "that", "this", "from", "into", "create",
            "update", "should", "shouldn", "able", "more", "than", "their", "add",
            "notion", "card", "branch", "make", "using", "when", "have", "what"
        ]
        let words = text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 4 && !stop.contains($0) }
        return Set(words)
    }

    /// The card this session is most likely working on.
    var primaryNotionRef: NotionRef? { workedNotionRefs.first }

    /// The `/rename` name, or nil when the session was never named.
    var name: String? {
        guard let name = digest.customName, !name.isEmpty else { return nil }
        return name
    }

    var headline: String {
        if let t = digest.aiTitle, !t.isEmpty { return t }
        if let p = digest.openingPrompt, !p.isEmpty { return p.firstLine(max: 90) }
        return "Session \(sessionID.prefix(8))"
    }
}

// MARK: - Small helpers

extension String {
    func firstLine(max limit: Int) -> String {
        let line = split(separator: "\n").first.map(String.init) ?? self
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= limit { return trimmed }
        return String(trimmed.prefix(limit)) + "…"
    }
}

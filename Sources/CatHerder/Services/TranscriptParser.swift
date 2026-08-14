import Foundation

/// Streams a session transcript (JSONL) and mines a digest out of it.
///
/// Transcripts reach tens of megabytes, so the file is read in chunks and each
/// line is parsed independently. Nothing is held in memory beyond the digest
/// being built and the current chunk.
enum TranscriptParser {

    /// Gaps longer than this are treated as "you walked away", not working time.
    static let idleGapThreshold: TimeInterval = 5 * 60

    /// How many recent prompts to retain for the recap.
    static let promptHistoryLimit = 6

    /// Cap on retained edited-file paths.
    static let editedFileLimit = 40

    /// Prompts are stored only to be summarized, so keep a readable excerpt
    /// rather than the whole thing — full text would bloat the on-disk cache.
    static let promptExcerptLimit = 400

    static func digest(path: String, sessionID: String) -> TranscriptDigest {
        var d = TranscriptDigest.empty(sessionID: sessionID, path: path)

        // Ordered newest-last accumulators.
        var prompts: [String] = []
        var edited: [String] = []
        var notion: [String: NotionRef] = [:]
        var prs: [String: PullRequestRef] = [:]
        var skills = Set<String>()
        var mcp = Set<String>()
        var previousStamp: Date?
        var lastStopReason: String?
        var lastRecordWasUserTurn = false
        /// Title from a create-pages call, adopted by the next page id we see.
        var pendingNotionTitle: String?

        guard let reader = LineReader(path: path) else { return d }

        while let line = reader.next() {
            guard !line.isEmpty else { continue }

            // JSONSerialization hands back autoreleased Foundation objects. Across
            // hundreds of thousands of records those accumulate until the whole
            // corpus is resident, so each line gets its own pool.
            autoreleasepool {
                consume(line: line, into: &d, prompts: &prompts, edited: &edited,
                        notion: &notion, prs: &prs, skills: &skills, mcp: &mcp,
                        previousStamp: &previousStamp, lastStopReason: &lastStopReason,
                        lastRecordWasUserTurn: &lastRecordWasUserTurn,
                        pendingNotionTitle: &pendingNotionTitle)
            }
        }

        d.recentPrompts = prompts.suffix(promptHistoryLimit).reversed().map { prompt in
            prompt.count > promptExcerptLimit
                ? String(prompt.prefix(promptExcerptLimit)) + "…"
                : prompt
        }
        d.editedFiles = Array(edited.reversed())
        d.notionRefs = Array(notion.values)
        d.pullRequests = Array(prs.values)
        d.skillsUsed = skills.sorted()
        d.mcpServers = mcp.sorted()
        // Claude ended its turn and nothing followed → the ball is in your court.
        d.endsAwaitingUser = (lastStopReason == "end_turn") && !lastRecordWasUserTurn

        return d
    }

    // swiftlint:disable:next function_parameter_count
    /// Folds a single transcript record into the digest under construction.
    private static func consume(
        line: Data,
        into d: inout TranscriptDigest,
        prompts: inout [String],
        edited: inout [String],
        notion: inout [String: NotionRef],
        prs: inout [String: PullRequestRef],
        skills: inout Set<String>,
        mcp: inout Set<String>,
        previousStamp: inout Date?,
        lastStopReason: inout String?,
        lastRecordWasUserTurn: inout Bool,
        pendingNotionTitle: inout String?
    ) {
            // Cheap pre-filter: most lines are large assistant messages, and we
            // only need the Notion scan when the line actually mentions one.
            let hasNotion = line.contains("notion")

            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                return
            }

            let type = object["type"] as? String

            // ---- Timestamps -------------------------------------------------
            if let stamp = (object["timestamp"] as? String).flatMap(ISO8601.date(from:)) {
                if d.firstActivity == nil { d.firstActivity = stamp }
                d.lastActivity = stamp
                if let prev = previousStamp {
                    let gap = stamp.timeIntervalSince(prev)
                    if gap > 0 && gap <= idleGapThreshold { d.activeSeconds += gap }
                }
                previousStamp = stamp
            }

            // ---- Context carried on every message ---------------------------
            if let cwd = object["cwd"] as? String { d.cwd = cwd }
            if let branch = object["gitBranch"] as? String, !branch.isEmpty {
                d.gitBranchAtEnd = branch
            }
            if let mode = object["permissionMode"] as? String { d.permissionMode = mode }

            // ---- Attribution ------------------------------------------------
            if let skill = object["attributionSkill"] as? String { skills.insert(skill) }
            if let server = object["attributionMcpServer"] as? String { mcp.insert(server) }

            // ---- Claude Code's own metadata records -------------------------
            switch type {
            case "ai-title":
                if let title = object["aiTitle"] as? String, !title.isEmpty { d.aiTitle = title }
                return
            case "pr-link":
                if let url = object["prUrl"] as? String,
                   let number = object["prNumber"] as? Int {
                    let repo = object["prRepository"] as? String ?? ""
                    let ref = PullRequestRef(number: number, repository: repo, url: url,
                                             lastSeen: d.lastActivity ?? .distantPast)
                    prs[ref.id] = ref
                }
                return
            case "summary", "mode", "permission-mode", "file-history-snapshot",
                 "file-history-delta", "queue-operation", "last-prompt":
                return
            default:
                break
            }

            // Sidechain records belong to subagents; count them but do not let
            // their prompts pollute the human prompt history.
            let isSidechain = object["isSidechain"] as? Bool ?? false

            guard let message = object["message"] as? [String: Any] else { return }

            switch type {
            case "user":
                if !isSidechain {
                    d.userMessageCount += 1
                    lastRecordWasUserTurn = true
                    if let text = message["content"] as? String {
                        let isHumanTyped = (object["promptSource"] as? String) != nil
                            || (object["origin"] as? [String: Any])?["kind"] as? String == "human"
                        let meta = object["isMeta"] as? Bool ?? false
                        if isHumanTyped && !meta && !text.hasPrefix("<") {
                            prompts.append(text)
                            if d.openingPrompt == nil {
                                d.openingPrompt = String(text.prefix(promptExcerptLimit))
                            }
                        }
                    }
                }
                // Tool results arrive as user records with array content.
                // Only a genuine Notion tool response counts as the session
                // working a card. A `grep` that happens to print a notion.so
                // link is just a mention, and is picked up by the text scan below.
                let mcpTool = (object["attributionMcpTool"] as? String ?? "").lowercased()
                if hasNotion, mcpTool.contains("notion"),
                   let blocks = message["content"] as? [[String: Any]] {
                    for block in blocks where block["type"] as? String == "tool_result" {
                        scanNotion(in: block["content"], into: &notion,
                                   at: d.lastActivity, pendingTitle: &pendingNotionTitle)
                    }
                }

            case "assistant":
                d.assistantMessageCount += 1
                lastRecordWasUserTurn = false
                if let model = message["model"] as? String { d.lastModel = model }
                lastStopReason = message["stop_reason"] as? String

                if let usage = message["usage"] as? [String: Any],
                   let out = usage["output_tokens"] as? Int {
                    d.outputTokens += out
                }

                guard let blocks = message["content"] as? [[String: Any]] else { break }
                for block in blocks where block["type"] as? String == "tool_use" {
                    guard let rawName = block["name"] as? String else { continue }
                    let name = shortToolName(rawName)
                    d.toolCounts[name, default: 0] += 1

                    if name == "Agent" || name == "Task" { d.agentsLaunched += 1 }

                    let input = block["input"] as? [String: Any]

                    if ["Edit", "Write", "MultiEdit", "NotebookEdit"].contains(name),
                       let file = input?["file_path"] as? String {
                        // Move-to-front on re-edit: a file touched five times
                        // should appear once, at its most recent position.
                        if let existing = edited.firstIndex(of: file) {
                            edited.remove(at: existing)
                        }
                        edited.append(file)
                        if edited.count > editedFileLimit { edited.removeFirst() }
                    }

                    if rawName.lowercased().contains("notion"), let input {
                        scanNotionToolInput(name: rawName, input: input, into: &notion,
                                            at: d.lastActivity, pendingTitle: &pendingNotionTitle)
                    }
                }

            default:
                break
            }

            // Free-text notion URLs can appear anywhere (assistant prose, bash output).
            if hasNotion, let text = String(data: line, encoding: .utf8) {
                scanNotionURLs(in: text, into: &notion, at: d.lastActivity)
            }
    }

    // MARK: - Tool names

    /// `mcp__plugin_Notion_notion__notion-fetch` → `notion-fetch`
    static func shortToolName(_ raw: String) -> String {
        if raw.hasPrefix("mcp__"), let last = raw.components(separatedBy: "__").last {
            return last
        }
        return raw
    }

    // MARK: - Notion mining

    // The `\\?` before each slash tolerates JSON-escaped URLs: some producers
    // write "notion.so\/id" rather than "notion.so/id", and the scan runs over
    // raw transcript lines rather than decoded strings.

    /// notion.so/Some-Slug-<32hex>
    private static let slugPattern = try? NSRegularExpression(
        pattern: "notion\\.(?:so|com)\\\\?/([A-Za-z0-9%()\\-]{2,120}?)-([0-9a-f]{32})", options: [])
    /// notion.so/<32hex> and app.notion.com/p/<32hex>
    private static let barePattern = try? NSRegularExpression(
        pattern: "notion\\.(?:so|com)\\\\?/(?:p\\\\?/)?([0-9a-f]{32})", options: [])
    /// The `{"title":"…","url":"https://app.notion.com/p/<id>"}` envelope that
    /// notion-fetch and notion-update-page return — the authoritative title.
    private static let titledPagePattern = try? NSRegularExpression(
        pattern: "\"title\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.){1,400})\"\\s*,\\s*\"url\"\\s*:\\s*\"[^\"]*?notion\\.(?:so|com)\\\\?/(?:p\\\\?/)?([0-9a-f]{32})",
        options: [])

    /// Pulls page ids (and titles, when the URL carries a slug) out of raw text.
    static func scanNotionURLs(in text: String, into map: inout [String: NotionRef],
                               at date: Date?, source: NotionRefSource = .mention) {
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)

        // Confirmed title/url pairs win over anything guessed from a slug.
        titledPagePattern?.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match, match.numberOfRanges == 3 else { return }
            let rawTitle = ns.substring(with: match.range(at: 1))
            let id = ns.substring(with: match.range(at: 2))
            upsert(id: id, title: unescapeJSON(rawTitle), date: date,
                   source: .confirmed, into: &map)
        }

        slugPattern?.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match, match.numberOfRanges == 3 else { return }
            let slug = ns.substring(with: match.range(at: 1))
            let id = ns.substring(with: match.range(at: 2))
            upsert(id: id, title: titleFromSlug(slug), date: date,
                   source: max(source, .slugURL), into: &map)
        }

        barePattern?.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match, match.numberOfRanges == 2 else { return }
            let id = ns.substring(with: match.range(at: 1))
            upsert(id: id, title: nil, date: date, source: source, into: &map)
        }
    }

    /// Mines a Notion tool's response.
    ///
    /// The payload is a JSON document embedded as a *string* inside the record,
    /// so it must be unwrapped rather than re-serialized — re-encoding would
    /// escape the quotes again and the title pattern would never match.
    private static func scanNotion(in content: Any?, into map: inout [String: NotionRef],
                                  at date: Date?, pendingTitle: inout String?) {
        for text in plainTextPayloads(of: content) {
            // Prefer a properly decoded title/url pair when the payload is JSON.
            if let data = text.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let title = object["title"] as? String,
               let url = object["url"] as? String,
               let id = notionID(inURL: url), !title.isEmpty {
                upsert(id: id, title: title, date: date, source: .confirmed, into: &map)
            }
            // A Notion tool responded, so anything else named here was touched too.
            scanNotionURLs(in: text, into: &map, at: date, source: .toolCall)
        }
    }

    /// Flattens a tool_result `content` into the plain text strings it carries.
    private static func plainTextPayloads(of content: Any?) -> [String] {
        switch content {
        case let string as String:
            return [string]
        case let blocks as [[String: Any]]:
            return blocks.compactMap { $0["text"] as? String }
        case let blocks as [Any]:
            return blocks.compactMap { ($0 as? [String: Any])?["text"] as? String }
        default:
            return []
        }
    }

    /// Extracts a 32-hex page id from any Notion URL shape.
    private static func notionID(inURL url: String) -> String? {
        guard url.contains("notion.") else { return nil }
        var run = ""
        for character in url.lowercased() {
            if character.isHexDigit {
                run.append(character)
                if run.count == 32 { return run }
            } else if character == "-" {
                continue  // dashed uuids
            } else {
                run = ""
            }
        }
        return nil
    }

    private static func scanNotionToolInput(name: String, input: [String: Any],
                                           into map: inout [String: NotionRef],
                                           at date: Date?, pendingTitle: inout String?) {
        // notion-create-pages carries the human title before an id exists.
        if let pages = input["pages"] as? [[String: Any]] {
            for page in pages {
                if let props = page["properties"] as? [String: Any],
                   let title = props["Name"] as? String, !title.isEmpty {
                    pendingTitle = title
                }
            }
        }
        if let props = input["properties"] as? [String: Any],
           let title = props["Name"] as? String, !title.isEmpty {
            pendingTitle = title
        }

        // `data_source_id` names a database, not a card, so it is deliberately
        // excluded — otherwise every session looks like it is "working on"
        // whichever Notion database it queried.
        for key in ["id", "page_id", "pageId"] {
            guard let raw = input[key] as? String else { continue }
            guard let id = normalizeNotionID(raw) else { continue }
            let adopted = pendingTitle
            upsert(id: id, title: adopted, date: date, source: .toolCall, into: &map)
            if adopted != nil { pendingTitle = nil }
        }
    }

    /// Minimal JSON string unescaping for titles lifted out of raw text.
    private static func unescapeJSON(_ raw: String) -> String {
        var out = raw
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\n", with: " ")
            .replacingOccurrences(of: "\\t", with: " ")
            .replacingOccurrences(of: "\\/", with: "/")
            .replacingOccurrences(of: "\\\\", with: "\\")
        // Decode any \uXXXX escapes (curly quotes are common in card titles).
        if out.contains("\\u"), let data = "\"\(raw)\"".data(using: .utf8),
           let decoded = try? JSONSerialization.jsonObject(
                with: data, options: [.fragmentsAllowed]) as? String {
            out = decoded
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Accepts dashed or dashless ids, returns a 32-char lowercase hex id.
    static func normalizeNotionID(_ raw: String) -> String? {
        let stripped = raw
            .replacingOccurrences(of: "collection://", with: "")
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        guard stripped.count == 32,
              stripped.allSatisfy({ $0.isHexDigit }) else { return nil }
        return stripped
    }

    /// "Widget-App-Memory-leak-issues" → "Widget App - Memory leak issues"
    static func titleFromSlug(_ slug: String) -> String? {
        guard let decoded = slug.replacingOccurrences(of: "+", with: " ")
            .removingPercentEncoding ?? slug as String? else { return nil }
        let words = decoded.split(separator: "-").map(String.init)
        guard !words.isEmpty else { return nil }
        // Short project prefixes like "AB"/"XY" read better with a dash.
        var text = words.joined(separator: " ")
        if let first = words.first, first.count <= 8, first == first.uppercased(),
           words.count > 1 {
            text = first + " - " + words.dropFirst().joined(separator: " ")
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    private static func upsert(id: String, title: String?, date: Date?,
                               source: NotionRefSource,
                               into map: inout [String: NotionRef]) {
        let seen = date ?? .distantPast
        if var existing = map[id] {
            // A confirmed title replaces one guessed from a slug; otherwise keep
            // whatever we already have.
            if let title, !title.isEmpty,
               existing.title == nil || existing.title!.isEmpty || source > existing.source {
                existing.title = title
            }
            if seen > existing.lastSeen { existing.lastSeen = seen }
            if source > existing.source { existing.source = source }
            // Only deliberate interactions count as touches; incidental links
            // in output would otherwise inflate an unrelated card.
            if source >= .toolCall { existing.touches += 1 }
            map[id] = existing
        } else {
            map[id] = NotionRef(pageID: id, title: title, lastSeen: seen, source: source,
                                touches: source >= .toolCall ? 1 : 0)
        }
    }
}

// MARK: - ISO8601 parsing

/// Parses the `2026-07-27T16:41:32.465Z` timestamps found in transcripts.
///
/// Hand-rolled rather than using `ISO8601DateFormatter`: this runs once per
/// record across millions of lines, and the formatter is both slower and not
/// `Sendable`, which strict concurrency rightly objects to.
enum ISO8601 {

    static func date(from string: String) -> Date? {
        let utf8 = string.utf8
        guard utf8.count >= 19 else { return nil }
        var iterator = utf8.makeIterator()
        var digits: [Int] = []
        digits.reserveCapacity(20)

        // Collect the leading numeric fields in order, stopping at the fraction
        // or zone designator: YYYY MM DD hh mm ss
        var current = 0
        var hasDigit = false
        var fields: [Int] = []

        while let byte = iterator.next() {
            if byte >= 48, byte <= 57 {
                current = current * 10 + Int(byte - 48)
                hasDigit = true
            } else {
                if hasDigit { fields.append(current) }
                current = 0
                hasDigit = false
                // "." starts the fraction, "Z"/"+"/"-" the zone: we have enough.
                if byte == UInt8(ascii: ".") || byte == UInt8(ascii: "Z") { break }
                if fields.count >= 6 { break }
            }
            if fields.count >= 6 { break }
        }
        if hasDigit, fields.count < 6 { fields.append(current) }
        _ = digits

        guard fields.count >= 6 else { return nil }
        let (year, month, day, hour, minute, second) =
            (fields[0], fields[1], fields[2], fields[3], fields[4], fields[5])

        guard month >= 1, month <= 12, day >= 1, day <= 31 else { return nil }

        let days = daysFromCivil(year: year, month: month, day: day)
        let seconds = days * 86_400 + hour * 3_600 + minute * 60 + second
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    /// Howard Hinnant's days-from-civil: calendar date → days since 1970-01-01.
    /// Exact for all Gregorian dates, no timezone database involved (transcripts
    /// are always UTC).
    private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        var y = year
        y -= month <= 2 ? 1 : 0
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400                                   // [0, 399]
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy           // [0, 146096]
        return era * 146_097 + doe - 719_468
    }
}

// MARK: - Chunked line reader

/// Reads a file line by line in fixed-size chunks, so a multi-megabyte
/// transcript never lands in memory all at once.
final class LineReader {
    private let handle: FileHandle
    private var buffer = Data()
    /// Read position within `buffer`. Advancing an index rather than reslicing
    /// keeps the buffer from retaining the storage of every chunk read so far.
    private var cursor = 0
    private let chunkSize: Int
    private var atEOF = false
    private let newline = UInt8(ascii: "\n")

    init?(path: String, chunkSize: Int = 1 << 20) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        self.handle = handle
        self.chunkSize = chunkSize
    }

    deinit { try? handle.close() }

    func next() -> Data? {
        while true {
            if let index = buffer[cursor...].firstIndex(of: newline) {
                let line = Data(buffer[cursor..<index])
                cursor = index + 1
                compactIfNeeded()
                return line
            }
            if atEOF {
                guard cursor < buffer.count else { return nil }
                let line = Data(buffer[cursor...])
                cursor = buffer.count
                return line
            }
            // Drop consumed bytes before pulling more in, so a large file is
            // never fully resident.
            dropConsumed()
            let chunk = (try? handle.read(upToCount: chunkSize)) ?? nil
            if let chunk, !chunk.isEmpty {
                buffer.append(chunk)
            } else {
                atEOF = true
            }
        }
    }

    /// Reclaims the consumed prefix once it grows past a threshold.
    private func compactIfNeeded() {
        guard cursor > (1 << 19) else { return }
        dropConsumed()
    }

    private func dropConsumed() {
        guard cursor > 0 else { return }
        buffer = Data(buffer[cursor...])
        cursor = 0
    }
}

extension Data {
    /// Substring check on raw bytes — avoids building a String for lines we skip.
    func contains(_ needle: String) -> Bool {
        let bytes = Array(needle.utf8)
        guard !bytes.isEmpty, count >= bytes.count else { return false }
        return withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return false }
            let limit = count - bytes.count
            var i = 0
            while i <= limit {
                if base[i] == bytes[0] {
                    var j = 1
                    while j < bytes.count, base[i + j] == bytes[j] { j += 1 }
                    if j == bytes.count { return true }
                }
                i += 1
            }
            return false
        }
    }
}

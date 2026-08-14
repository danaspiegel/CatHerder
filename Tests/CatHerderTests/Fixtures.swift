import Foundation
@testable import CatHerder

/// A throwaway directory that cleans itself up.
final class TempDirectory {
    let url: URL

    init(_ name: String = UUID().uuidString) {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("catherder-tests-\(name)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    @discardableResult
    func makeDirectory(_ path: String) -> URL {
        let directory = url.appendingPathComponent(path, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @discardableResult
    func write(_ contents: String, to path: String) -> URL {
        let file = url.appendingPathComponent(path)
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? contents.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    /// Writes a transcript and returns its path.
    @discardableResult
    func writeTranscript(_ records: [String], sessionID: String = "S", project: String = "proj") -> String {
        write(records.joined(separator: "\n") + "\n",
              to: "\(project)/\(sessionID).jsonl").path
    }
}

// MARK: - Transcript record builders

/// Builds the JSONL records a real Claude Code transcript contains, so parser
/// tests exercise the same shapes the app sees in practice.
enum Rec {

    static func json(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }

    /// A human-typed prompt.
    static func userPrompt(_ text: String, at timestamp: String,
                           cwd: String = "/tmp/proj", branch: String = "main",
                           sidechain: Bool = false, meta: Bool = false) -> String {
        json([
            "type": "user",
            "isSidechain": sidechain,
            "isMeta": meta,
            "promptSource": "typed",
            "origin": ["kind": "human"],
            "message": ["role": "user", "content": text],
            "timestamp": timestamp,
            "cwd": cwd,
            "gitBranch": branch,
            "permissionMode": "default",
        ])
    }

    /// A tool result coming back to the model.
    static func toolResult(_ content: Any, toolUseID: String, at timestamp: String,
                           mcpTool: String? = nil) -> String {
        var object: [String: Any] = [
            "type": "user",
            "isSidechain": false,
            "message": ["role": "user", "content": [
                ["type": "tool_result", "tool_use_id": toolUseID, "content": content]
            ]],
            "timestamp": timestamp,
        ]
        if let mcpTool { object["attributionMcpTool"] = mcpTool }
        return json(object)
    }

    /// An assistant turn, optionally carrying tool calls.
    static func assistant(tools: [[String: Any]] = [], at timestamp: String,
                          stopReason: String = "tool_use", outputTokens: Int = 10,
                          model: String = "claude-opus-5",
                          cwd: String = "/tmp/proj", branch: String = "main",
                          skill: String? = nil, mcpServer: String? = nil) -> String {
        var blocks: [[String: Any]] = []
        for tool in tools {
            var block = tool
            block["type"] = "tool_use"
            blocks.append(block)
        }
        var object: [String: Any] = [
            "type": "assistant",
            "isSidechain": false,
            "message": [
                "model": model,
                "role": "assistant",
                "content": blocks,
                "stop_reason": stopReason,
                "usage": ["output_tokens": outputTokens],
            ],
            "timestamp": timestamp,
            "cwd": cwd,
            "gitBranch": branch,
        ]
        if let skill { object["attributionSkill"] = skill }
        if let mcpServer { object["attributionMcpServer"] = mcpServer }
        return json(object)
    }

    static func aiTitle(_ title: String) -> String {
        json(["type": "ai-title", "aiTitle": title, "sessionId": "S"])
    }

    static func prLink(number: Int, repository: String) -> String {
        json([
            "type": "pr-link",
            "prNumber": number,
            "prRepository": repository,
            "prUrl": "https://github.com/\(repository)/pull/\(number)",
        ])
    }

    static func mode() -> String {
        json(["type": "mode", "mode": "normal", "sessionId": "S"])
    }

    /// Convenience for a tool_use block.
    static func tool(_ name: String, input: [String: Any] = [:], id: String = "t1") -> [String: Any] {
        ["name": name, "id": id, "input": input]
    }
}

// MARK: - Process fixtures

extension ClaudeProcess {
    static func stub(pid: Int32 = 100,
                     startedAt: Date = Date(),
                     cwd: String? = "/tmp/proj",
                     command: String = "claude",
                     resumed: String? = nil,
                     cpu: Double = 0,
                     tty: String? = "/dev/ttys001",
                     program: String? = "Apple_Terminal") -> ClaudeProcess {
        ClaudeProcess(
            pid: pid, parentPID: 1, startedAt: startedAt, cwd: cwd, command: command,
            terminal: TerminalRef(tty: tty, program: program, sessionID: nil),
            resumedSessionID: resumed, cpuPercent: cpu
        )
    }
}

extension TranscriptDigest {
    static func stub(sessionID: String = "S",
                     lastActivity: Date? = Date(),
                     endsAwaitingUser: Bool = false,
                     aiTitle: String? = nil,
                     openingPrompt: String? = nil,
                     notionRefs: [NotionRef] = []) -> TranscriptDigest {
        var digest = TranscriptDigest.empty(sessionID: sessionID, path: "/tmp/\(sessionID).jsonl")
        digest.lastActivity = lastActivity
        digest.endsAwaitingUser = endsAwaitingUser
        digest.aiTitle = aiTitle
        digest.openingPrompt = openingPrompt
        digest.notionRefs = notionRefs
        return digest
    }
}

import Foundation

/// Finds the live `claude` CLI processes and everything we can learn about them
/// from the process table alone.
///
/// Three shell-outs per scan, each batched over all pids at once rather than
/// per-process: `ps` for the table, `lsof` for working directories, and one
/// `ps eww` per pid for the terminal environment (unavoidable — the environment
/// is only readable one process at a time).
enum ProcessScanner {

    /// Commands that are part of Claude Code's plumbing rather than an interactive session.
    private static let excludedFragments = [
        "daemon run", "bg-pty-host", "bg-spare", "chrome-native-host",
        "mcp serve", "--bg-spare", "CatHerder"
    ]

    static func scan() async -> [ClaudeProcess] {
        guard let table = await Shell.run("/bin/ps", ["-Ao", "pid=,ppid=,tty=,pcpu=,command="]) else {
            return []
        }

        var candidates: [(pid: Int32, ppid: Int32, tty: String, cpu: Double, command: String)] = []

        for line in table.split(separator: "\n") {
            let text = String(line)
            // Fields: pid ppid tty pcpu command...  (command may contain spaces)
            let parts = text.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 5,
                  let pid = Int32(parts[0]),
                  let ppid = Int32(parts[1]) else { continue }
            let tty = String(parts[2])
            let cpu = Double(parts[3]) ?? 0
            // Rebuild the command by locating the 5th field in the original string.
            let command = Self.commandTail(of: text, skippingFields: 4)
            guard isInteractiveClaude(command) else { continue }
            candidates.append((pid, ppid, tty, cpu, command))
        }

        guard !candidates.isEmpty else { return [] }

        let pids = candidates.map(\.pid)
        async let cwds = workingDirectories(for: pids)
        async let starts = startTimes(for: pids)
        async let terminals = terminalEnvironments(for: pids)

        let (cwdMap, startMap, termMap) = await (cwds, starts, terminals)

        return candidates.compactMap { c in
            // Without a start time we cannot correlate to a session, so skip.
            guard let started = startMap[c.pid] else { return nil }
            var terminal = termMap[c.pid] ?? TerminalRef()
            if terminal.tty == nil, c.tty != "??" , !c.tty.isEmpty {
                terminal.tty = "/dev/\(c.tty)"
            }
            return ClaudeProcess(
                pid: c.pid,
                parentPID: c.ppid,
                startedAt: started,
                cwd: cwdMap[c.pid],
                command: c.command,
                terminal: terminal,
                resumedSessionID: resumedSessionID(from: c.command),
                cpuPercent: c.cpu
            )
        }
    }

    // MARK: - Filtering

    /// True for an interactive `claude` CLI session, false for daemons and helpers.
    static func isInteractiveClaude(_ command: String) -> Bool {
        // The executable is the first whitespace-delimited token.
        guard let exe = command.split(separator: " ").first else { return false }
        let name = URL(fileURLWithPath: String(exe)).lastPathComponent
        guard name == "claude" || name == "node" && command.contains("claude") else { return false }
        for fragment in excludedFragments where command.contains(fragment) { return false }
        // `claude agents` is the fleet launcher, not a session of its own.
        let args = command.split(separator: " ").dropFirst().map(String.init)
        if args.first == "agents" || args.first == "daemon" { return false }
        return true
    }

    static func resumedSessionID(from command: String) -> String? {
        let args = command.split(separator: " ").map(String.init)
        for (i, arg) in args.enumerated() where arg == "--resume" || arg == "-r" {
            if i + 1 < args.count, isUUID(args[i + 1]) { return args[i + 1] }
        }
        return nil
    }

    private static func isUUID(_ s: String) -> Bool { UUID(uuidString: s) != nil }

    /// Returns everything after the first `skippingFields` whitespace-delimited fields.
    private static func commandTail(of line: String, skippingFields: Int) -> String {
        var remaining = Substring(line).drop(while: { $0 == " " })
        for _ in 0..<skippingFields {
            remaining = remaining.drop(while: { $0 != " " }).drop(while: { $0 == " " })
        }
        return String(remaining)
    }

    // MARK: - Working directories

    private static func workingDirectories(for pids: [Int32]) async -> [Int32: String] {
        let list = pids.map(String.init).joined(separator: ",")
        guard let out = await Shell.run("/usr/sbin/lsof", ["-a", "-d", "cwd", "-Fpn", "-p", list]) else {
            return [:]
        }
        // Output is a stream of records: p<pid>, f<fd>, n<path>
        var result: [Int32: String] = [:]
        var current: Int32?
        for line in out.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p": current = Int32(value)
            case "n": if let c = current { result[c] = value }
            default: break
            }
        }
        return result
    }

    // MARK: - Start times

    /// `ps -o lstart=` yields "Thu Aug 13 15:59:25 2026" — the only field that
    /// gives an absolute start instant on macOS (there is no `etimes` keyword).
    private static func startTimes(for pids: [Int32]) async -> [Int32: Date] {
        let args = ["-o", "pid=,lstart="] + pids.flatMap { ["-p", String($0)] }
        guard let out = await Shell.run("/bin/ps", args) else { return [:] }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"

        var result: [Int32: Date] = [:]
        for line in out.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let space = trimmed.firstIndex(of: " "),
                  let pid = Int32(trimmed[trimmed.startIndex..<space]) else { continue }
            let stamp = trimmed[space...].trimmingCharacters(in: .whitespaces)
            if let date = formatter.date(from: stamp) { result[pid] = date }
        }
        return result
    }

    // MARK: - Terminal environment

    /// Reads TERM_PROGRAM / TERM_SESSION_ID out of each process's environment.
    /// `ps eww` only works for processes owned by the current user, which is
    /// exactly the set we care about.
    private static func terminalEnvironments(for pids: [Int32]) async -> [Int32: TerminalRef] {
        await withTaskGroup(of: (Int32, TerminalRef)?.self) { group in
            for pid in pids {
                group.addTask {
                    guard let out = await Shell.run("/bin/ps", ["eww", "-o", "command=", "-p", String(pid)]) else {
                        return nil
                    }
                    var ref = TerminalRef()
                    for token in out.split(separator: " ") {
                        guard let eq = token.firstIndex(of: "=") else { continue }
                        let key = String(token[token.startIndex..<eq])
                        let value = String(token[token.index(after: eq)...])
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        switch key {
                        case "TERM_PROGRAM": ref.program = value
                        case "TERM_SESSION_ID": ref.sessionID = value
                        case "ITERM_SESSION_ID": if ref.sessionID == nil { ref.sessionID = value }
                        default: break
                        }
                    }
                    return (pid, ref)
                }
            }
            var result: [Int32: TerminalRef] = [:]
            for await entry in group {
                if let (pid, ref) = entry { result[pid] = ref }
            }
            return result
        }
    }
}

// MARK: - Process helper

/// Minimal async wrapper around Process for the read-only commands we run.
enum Shell {
    static func run(_ launchPath: String, _ arguments: [String], timeout: TimeInterval = 10) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: launchPath)
                process.arguments = arguments
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: nil)
                    return
                }

                // Read before waiting so a large payload cannot fill the pipe buffer.
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: String(data: data, encoding: .utf8))
            }
        }
    }
}

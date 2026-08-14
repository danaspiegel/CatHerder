import Foundation

/// Reads repository identity and current branch straight off disk.
///
/// Deliberately avoids shelling out to `git`: a monitor that refreshes every
/// couple of seconds across a dozen directories should not spawn dozens of
/// processes. Everything needed lives in `.git/HEAD` and the directory name.
enum GitInspector {

    static func inspect(directory: String?) -> GitInfo {
        guard let directory, !directory.isEmpty else { return .none }
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory) else { return .none }

        guard let (gitDir, repoRoot, isWorktree) = locateGitDirectory(from: directory) else {
            return .none
        }

        var info = GitInfo(
            repoName: URL(fileURLWithPath: repoRoot).lastPathComponent,
            repoRoot: repoRoot,
            branch: nil,
            isWorktree: isWorktree
        )
        info.branch = readBranch(gitDir: gitDir)
        return info
    }

    /// Walks up from `directory` looking for `.git`. Handles both a real
    /// directory (normal checkout) and a file containing `gitdir: …`
    /// (linked worktree, which Claude Code creates for agents).
    private static func locateGitDirectory(from directory: String)
        -> (gitDir: String, repoRoot: String, isWorktree: Bool)? {
        let fm = FileManager.default
        var current = URL(fileURLWithPath: directory).standardizedFileURL

        while true {
            let dotGit = current.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) {
                if isDirectory.boolValue {
                    return (dotGit.path, current.path, false)
                }
                // A worktree: ".git" is a file pointing at the real git dir.
                if let contents = try? String(contentsOf: dotGit, encoding: .utf8),
                   let line = contents.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) {
                    let raw = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
                    let resolved = raw.hasPrefix("/")
                        ? raw
                        : current.appendingPathComponent(raw).standardizedFileURL.path
                    return (resolved, current.path, true)
                }
                return (dotGit.path, current.path, false)
            }
            let parent = current.deletingLastPathComponent().standardizedFileURL
            if parent.path == current.path || parent.path == "/" { return nil }
            current = parent
        }
    }

    /// `.git/HEAD` holds either `ref: refs/heads/<branch>` or a bare SHA
    /// when the checkout is detached.
    private static func readBranch(gitDir: String) -> String? {
        let head = URL(fileURLWithPath: gitDir).appendingPathComponent("HEAD")
        guard let contents = try? String(contentsOf: head, encoding: .utf8) else { return nil }
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("ref: refs/heads/") {
            return String(trimmed.dropFirst("ref: refs/heads/".count))
        }
        if trimmed.hasPrefix("ref: ") {
            return String(trimmed.dropFirst("ref: ".count))
        }
        // Detached HEAD — show a short SHA so the row is not blank.
        if trimmed.count >= 7, trimmed.allSatisfy({ $0.isHexDigit }) {
            return "detached @ " + trimmed.prefix(7)
        }
        return nil
    }
}

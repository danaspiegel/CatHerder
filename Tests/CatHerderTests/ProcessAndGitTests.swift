import Foundation
import Testing
@testable import CatHerder

@Suite("Process filtering")
struct ProcessScannerTests {

    /// Real command lines taken from a running fleet.
    @Test("keeps interactive sessions", arguments: [
        "claude",
        "claude --allow-dangerously-skip-permissions",
        "claude --resume 85cf5a36-e7bd-4f61-89b1-ed5511560245",
        "/opt/homebrew/bin/claude",
    ])
    func keepsSessions(_ command: String) {
        #expect(ProcessScanner.isInteractiveClaude(command))
    }

    @Test("drops plumbing and helpers", arguments: [
        "/opt/homebrew/bin/claude daemon run --origin transient",
        "claude bg-pty-host --bg-pty-host /tmp/cc-daemon-502/spare/d73e44d1.pty.sock 200 50",
        "claude bg-spare --bg-spare /tmp/cc-daemon-502/spare/d73e44d1.claim.sock",
        "/Applications/Claude.app/Contents/Helpers/chrome-native-host chrome-extension://abc/",
        "/opt/homebrew/bin/claude agents",
        "claude mcp serve",
        "/Applications/CatHerder.app/Contents/MacOS/CatHerder",
        "vim claude.swift",
        "grep claude foo.txt",
    ])
    func dropsNonSessions(_ command: String) {
        #expect(!ProcessScanner.isInteractiveClaude(command))
    }

    @Test("extracts an explicitly resumed session id")
    func resumeExtraction() {
        #expect(ProcessScanner.resumedSessionID(
            from: "claude --resume 85cf5a36-e7bd-4f61-89b1-ed5511560245")
            == "85cf5a36-e7bd-4f61-89b1-ed5511560245")
        #expect(ProcessScanner.resumedSessionID(
            from: "claude -r 85cf5a36-e7bd-4f61-89b1-ed5511560245")
            == "85cf5a36-e7bd-4f61-89b1-ed5511560245")
    }

    @Test("ignores a resume flag without a valid id")
    func resumeWithoutID() {
        #expect(ProcessScanner.resumedSessionID(from: "claude --resume") == nil)
        #expect(ProcessScanner.resumedSessionID(from: "claude --resume not-a-uuid") == nil)
        #expect(ProcessScanner.resumedSessionID(from: "claude") == nil)
    }
}

@Suite("Git inspection")
struct GitInspectorTests {

    @Test("reads the branch from a normal checkout")
    func normalCheckout() {
        let temp = TempDirectory()
        let repo = temp.makeDirectory("myrepo")
        temp.write("ref: refs/heads/feature/ABC-123\n", to: "myrepo/.git/HEAD")

        let info = GitInspector.inspect(directory: repo.path)
        #expect(info.isRepo)
        #expect(info.repoName == "myrepo")
        #expect(info.branch == "feature/ABC-123")
        #expect(!info.isWorktree)
    }

    @Test("walks up from a subdirectory to the repository root")
    func walksUp() {
        let temp = TempDirectory()
        temp.write("ref: refs/heads/main\n", to: "myrepo/.git/HEAD")
        let nested = temp.makeDirectory("myrepo/src/deep/nested")

        let info = GitInspector.inspect(directory: nested.path)
        #expect(info.repoName == "myrepo")
        #expect(info.branch == "main")
    }

    /// Claude Code creates linked worktrees for agents; those have a `.git`
    /// *file* pointing elsewhere rather than a directory.
    @Test("recognises a linked worktree")
    func worktree() {
        let temp = TempDirectory()
        let gitDir = temp.makeDirectory("main/.git/worktrees/wt1")
        try? "ref: refs/heads/agent-branch\n".write(
            to: gitDir.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)

        let worktree = temp.makeDirectory("wt1")
        temp.write("gitdir: \(gitDir.path)\n", to: "wt1/.git")

        let info = GitInspector.inspect(directory: worktree.path)
        #expect(info.isRepo)
        #expect(info.isWorktree)
        #expect(info.branch == "agent-branch")
    }

    @Test("reports a short sha for a detached HEAD")
    func detachedHead() {
        let temp = TempDirectory()
        let repo = temp.makeDirectory("detached")
        temp.write("a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0\n", to: "detached/.git/HEAD")

        let info = GitInspector.inspect(directory: repo.path)
        #expect(info.branch == "detached @ a1b2c3d")
    }

    @Test("reports no repository outside one")
    func notARepo() {
        let temp = TempDirectory()
        let plain = temp.makeDirectory("plain")
        let info = GitInspector.inspect(directory: plain.path)

        #expect(!info.isRepo)
        #expect(info.branch == nil)
        #expect(info.repoName == nil)
    }

    @Test("handles a missing or nil directory")
    func missingDirectory() {
        #expect(!GitInspector.inspect(directory: nil).isRepo)
        #expect(!GitInspector.inspect(directory: "").isRepo)
        #expect(!GitInspector.inspect(directory: "/nonexistent/path/xyz").isRepo)
    }
}

@Suite("Terminal capability")
struct TerminalActivatorTests {

    @Test("knows which emulators expose tabs by tty")
    func ttyLookup() {
        #expect(TerminalActivator.Emulator(termProgram: "Apple_Terminal")?.supportsTTYLookup == true)
        #expect(TerminalActivator.Emulator(termProgram: "iTerm.app")?.supportsTTYLookup == true)
        #expect(TerminalActivator.Emulator(termProgram: "ghostty")?.supportsTTYLookup == false)
        #expect(TerminalActivator.Emulator(termProgram: "vscode")?.supportsTTYLookup == false)
    }

    @Test("names emulators for display")
    func displayNames() {
        #expect(TerminalActivator.Emulator(termProgram: "Apple_Terminal")?.displayName == "Terminal")
        #expect(TerminalActivator.Emulator(termProgram: "iTerm.app")?.displayName == "iTerm2")
        #expect(TerminalActivator.Emulator(termProgram: "ghostty")?.displayName == "Ghostty")
        // Unknown emulators fall back to whatever TERM_PROGRAM said.
        #expect(TerminalActivator.Emulator(termProgram: "mystery")?.displayName == "mystery")
    }

    @Test("a tab can only be focused with both a tty and a known emulator")
    func canActivate() {
        #expect(TerminalRef(tty: "/dev/ttys001", program: "Apple_Terminal").canActivateTab)
        #expect(!TerminalRef(tty: nil, program: "Apple_Terminal").canActivateTab)
        #expect(!TerminalRef(tty: "/dev/ttys001", program: "ghostty").canActivateTab)
        #expect(!TerminalRef(tty: "/dev/ttys001", program: nil).canActivateTab)
    }

    @Test("results describe themselves")
    func results() {
        #expect(TerminalActivator.Result.focusedTab.isSuccess)
        #expect(TerminalActivator.Result.activatedAppOnly("Ghostty").isSuccess)
        #expect(!TerminalActivator.Result.noTerminalInfo.isSuccess)
        #expect(!TerminalActivator.Result.failed("boom").isSuccess)
        #expect(TerminalActivator.Result.failed("boom").message == "boom")
    }
}

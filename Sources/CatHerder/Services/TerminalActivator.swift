import AppKit
import Foundation

/// Brings the terminal tab hosting a given Claude instance to the front.
///
/// The tty device is the reliable join key: both Terminal.app and iTerm2 expose
/// a `tty` property on their tabs/sessions, so we can find the exact tab that a
/// pid is attached to rather than guessing by window title.
enum TerminalActivator {

    enum Emulator: Sendable {
        case appleTerminal
        case iTerm2
        case other(bundleID: String?, name: String)

        init?(termProgram: String) {
            switch termProgram.lowercased() {
            case "apple_terminal": self = .appleTerminal
            case "iterm.app": self = .iTerm2
            case let value where value.contains("vscode"):
                self = .other(bundleID: "com.microsoft.VSCode", name: "VS Code")
            case "ghostty":
                self = .other(bundleID: "com.mitchellh.ghostty", name: "Ghostty")
            case "wezterm":
                self = .other(bundleID: "com.github.wez.wezterm", name: "WezTerm")
            case "warpterminal", "warp":
                self = .other(bundleID: "dev.warp.Warp-Stable", name: "Warp")
            case "alacritty":
                self = .other(bundleID: "org.alacritty", name: "Alacritty")
            case "hyper":
                self = .other(bundleID: "co.zeit.hyper", name: "Hyper")
            case "tabby":
                self = .other(bundleID: "org.tabby", name: "Tabby")
            default:
                self = .other(bundleID: nil, name: termProgram)
            }
        }

        /// Only these two let AppleScript address an individual tab by tty.
        var supportsTTYLookup: Bool {
            switch self {
            case .appleTerminal, .iTerm2: true
            case .other: false
            }
        }

        var displayName: String {
            switch self {
            case .appleTerminal: "Terminal"
            case .iTerm2: "iTerm2"
            case .other(_, let name): name
            }
        }

        var bundleID: String? {
            switch self {
            case .appleTerminal: "com.apple.Terminal"
            case .iTerm2: "com.googlecode.iterm2"
            case .other(let id, _): id
            }
        }
    }

    enum Result: Sendable, Equatable {
        case focusedTab
        case activatedAppOnly(String)
        case noTerminalInfo
        case failed(String)

        var isSuccess: Bool {
            switch self {
            case .focusedTab, .activatedAppOnly: true
            case .noTerminalInfo, .failed: false
            }
        }

        var message: String {
            switch self {
            case .focusedTab:
                "Switched to the terminal tab."
            case .activatedAppOnly(let app):
                "Brought \(app) forward. It can't focus individual tabs from AppleScript, so pick the tab yourself."
            case .noTerminalInfo:
                "No terminal information for this instance."
            case .failed(let reason):
                reason
            }
        }
    }

    /// Focus the tab attached to `terminal.tty`.
    static func activate(terminal: TerminalRef) async -> Result {
        guard let tty = terminal.tty, let program = terminal.program,
              let emulator = Emulator(termProgram: program) else {
            return .noTerminalInfo
        }

        switch emulator {
        case .appleTerminal:
            return await runScript(appleTerminalScript(tty: tty), emulator: emulator)
        case .iTerm2:
            return await runScript(iTermScript(tty: tty), emulator: emulator)
        case .other(let bundleID, let name):
            // No tab addressing available — the best we can do is raise the app.
            if let bundleID, activateApplication(bundleID: bundleID) {
                return .activatedAppOnly(name)
            }
            return .failed("Don't know how to focus \(name).")
        }
    }

    // MARK: - Scripts

    private static func appleTerminalScript(tty: String) -> String {
        """
        tell application "Terminal"
            activate
            repeat with w from 1 to count of windows
                repeat with t from 1 to count of tabs of window w
                    if tty of tab t of window w is "\(tty)" then
                        set selected of tab t of window w to true
                        set index of window w to 1
                        return "ok"
                    end if
                end repeat
            end repeat
        end tell
        return "notfound"
        """
    }

    private static func iTermScript(tty: String) -> String {
        """
        tell application "iTerm2"
            activate
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is "\(tty)" then
                            select w
                            select t
                            select s
                            return "ok"
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return "notfound"
        """
    }

    // MARK: - Execution

    private static func runScript(_ source: String, emulator: Emulator) async -> Result {
        await withCheckedContinuation { continuation in
            // NSAppleScript is not thread-safe and must not run on the main
            // thread either, or a slow emulator would beachball the UI.
            DispatchQueue.global(qos: .userInitiated).async {
                var error: NSDictionary?
                let script = NSAppleScript(source: source)
                let output = script?.executeAndReturnError(&error)

                if let error {
                    let number = error[NSAppleScript.errorNumber] as? Int ?? 0
                    let text = error[NSAppleScript.errorMessage] as? String ?? "AppleScript failed"
                    // -1743: the user has not granted Automation permission yet.
                    if number == -1743 {
                        continuation.resume(returning: .failed(
                            "Automation permission denied. Allow CatHerder to control "
                            + "\(emulator.displayName) in System Settings › Privacy & Security › Automation."))
                    } else {
                        continuation.resume(returning: .failed(text))
                    }
                    return
                }

                if output?.stringValue == "ok" {
                    continuation.resume(returning: .focusedTab)
                } else {
                    continuation.resume(returning: .failed(
                        "That tab is gone from \(emulator.displayName) — the session may have moved."))
                }
            }
        }
    }

    private static func activateApplication(bundleID: String) -> Bool {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        guard let app = running.first else { return false }
        return app.activate(options: [.activateAllWindows])
    }
}

import AppKit
import CoreServices
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
        /// Automation is switched off for this app, so nothing was sent.
        case permissionDenied(String)
        case terminalNotRunning(String)
        case failed(String)

        var isSuccess: Bool {
            switch self {
            case .focusedTab, .activatedAppOnly: true
            case .noTerminalInfo, .permissionDenied, .terminalNotRunning, .failed: false
            }
        }

        /// True when the user has to change a setting before this can work.
        var needsAutomationSettings: Bool {
            if case .permissionDenied = self { return true }
            return false
        }

        var message: String {
            switch self {
            case .focusedTab:
                "Switched to the terminal tab."
            case .activatedAppOnly(let app):
                "Brought \(app) forward. It can't focus individual tabs from AppleScript, so pick the tab yourself."
            case .noTerminalInfo:
                "No terminal information for this instance."
            case .permissionDenied(let app):
                "Cat Herder isn't allowed to control \(app), so it can't switch tabs. "
                + "Enable it under Automation in Privacy & Security settings."
            case .terminalNotRunning(let app):
                "\(app) isn't running any more, so that tab is gone."
            case .failed(let reason):
                reason
            }
        }
    }

    // MARK: - Automation permission

    /// Whether this app may drive another via Apple Events.
    enum Permission: Sendable, Equatable {
        case granted
        /// Explicitly switched off in Privacy & Security settings.
        case denied
        /// Never asked, so sending an event would raise the consent prompt.
        case notYetAsked
        case targetNotRunning
        case unknown(OSStatus)
    }

    /// Asks the Apple Events machinery about permission *without sending an
    /// event*, which is what lets a denied attempt fail without dragging the
    /// terminal to the front first.
    static func permission(forBundleID bundleID: String,
                           askUserIfNeeded: Bool = false) -> Permission {
        var target = AEAddressDesc()
        let identifier = Array(bundleID.utf8)
        guard AECreateDesc(typeApplicationBundleID, identifier, identifier.count, &target) == noErr
        else { return .unknown(OSStatus(paramErr)) }
        defer { AEDisposeDesc(&target) }

        let status = AEDeterminePermissionToAutomateTarget(
            &target, typeWildCard, typeWildCard, askUserIfNeeded)

        switch status {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(errAEEventWouldRequireUserConsent): return .notYetAsked
        case OSStatus(procNotFound): return .targetNotRunning
        default: return .unknown(status)
        }
    }

    /// `AEDeterminePermissionToAutomateTarget` is synchronous, and blocks while
    /// the consent dialog is up, so it is kept off the main thread.
    private static func permissionOffMainThread(forBundleID bundleID: String,
                                               askUserIfNeeded: Bool) async -> Permission {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: permission(forBundleID: bundleID,
                                                          askUserIfNeeded: askUserIfNeeded))
            }
        }
    }

    /// Opens the pane where the grant lives.
    @MainActor
    static func openAutomationSettings() {
        let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
        if let url { NSWorkspace.shared.open(url) }
    }

    /// Focus the tab attached to `terminal.tty`.
    static func activate(terminal: TerminalRef) async -> Result {
        guard let tty = terminal.tty, let program = terminal.program,
              let emulator = Emulator(termProgram: program) else {
            return .noTerminalInfo
        }

        // Check before sending anything. macOS activates the target app as a
        // side effect of an Apple Event even when it goes on to refuse it, so
        // asking first is the only way a denial leaves the terminal alone.
        if let bundleID = emulator.bundleID, emulator.supportsTTYLookup {
            switch await permissionOffMainThread(forBundleID: bundleID, askUserIfNeeded: false) {
            case .granted:
                break
            case .notYetAsked:
                // Raise the consent prompt on its own, then act on the answer.
                // Asking blocks until the user replies, so it must not run on
                // the main actor or the window would freeze behind the dialog.
                if await permissionOffMainThread(forBundleID: bundleID,
                                                 askUserIfNeeded: true) != .granted {
                    return .permissionDenied(emulator.displayName)
                }
            case .denied:
                return .permissionDenied(emulator.displayName)
            case .targetNotRunning:
                return .terminalNotRunning(emulator.displayName)
            case .unknown:
                break   // fall through and let the script report the real error
            }
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
                    // Normally caught by the pre-flight check above; this
                    // covers a grant revoked between checking and sending.
                    if number == -1743 {
                        continuation.resume(returning: .permissionDenied(emulator.displayName))
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

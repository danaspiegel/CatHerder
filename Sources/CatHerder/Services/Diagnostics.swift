import AppKit
import Foundation

/// Command-line diagnostics, for questions that can only be answered from
/// inside the app's own identity.
///
///     Cat\ Herder.app/Contents/MacOS/CatHerder --check-automation
///
/// Automation permission is granted to the *responsible process*, which is not
/// always this app: launching it from a terminal can make the terminal
/// responsible, in which case the terminal's existing permission is used, no
/// prompt appears, and the app never shows up in Privacy & Security settings.
/// Launching from Finder or Spotlight makes the app responsible for itself.
enum Diagnostics {

    static func runIfRequested() {
        guard CommandLine.arguments.contains("--check-automation") else { return }

        let identifier = Bundle.main.bundleIdentifier ?? "(none)"
        print("bundle identifier: \(identifier)")
        print("executable:        \(Bundle.main.executablePath ?? "(none)")")

        for (name, bundleID) in [("Terminal", "com.apple.Terminal"),
                                 ("iTerm2", "com.googlecode.iterm2")] {
            let state = TerminalActivator.permission(forBundleID: bundleID)
            print("\(name.padding(toLength: 10, withPad: " ", startingAt: 0)) \(describe(state))")
        }

        print("""

        If a terminal launched this process, permission is attributed to that \
        terminal rather than to Cat Herder, so no prompt appears and Cat Herder \
        is absent from Privacy & Security › Automation. Launch it from Finder or \
        Spotlight to see its own state.
        """)
        exit(0)
    }

    private static func describe(_ permission: TerminalActivator.Permission) -> String {
        switch permission {
        case .granted: "granted"
        case .denied: "denied — switch it on in Privacy & Security › Automation"
        case .notYetAsked: "not yet asked — the next attempt will prompt"
        case .targetNotRunning: "that terminal is not running"
        case .unknown(let status): "unknown (OSStatus \(status))"
        }
    }
}

import AppKit
import SwiftUI

/// Development-only screenshot capture.
///
/// Renders the app's own window hierarchy to PNGs using `cacheDisplay`, which
/// draws through AppKit rather than reading the screen. That means it needs no
/// Screen Recording permission, captures AppKit-backed views (`Table`) exactly
/// as they appear, and works headlessly.
///
///     Claude\ Monitor.app/Contents/MacOS/CatHerder --snapshot <directory>
///
/// The app drives itself through each view, captures it, and exits.
@MainActor
final class SnapshotRunner {

    static let flag = "--snapshot"

    /// Output directory when the flag was passed, otherwise nil.
    static var requestedDirectory: URL? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: flag),
              index + 1 < arguments.count else { return nil }
        return URL(fileURLWithPath: arguments[index + 1])
    }

    static var isActive: Bool { requestedDirectory != nil }

    /// Set by the runner to push the UI into a particular state before capture.
    struct Scene: Equatable {
        var section: FleetSection
        var selectFirstRow: Bool
        var name: String
    }

    /// Observed by RootView so the runner can drive navigation.
    @Observable
    final class Stage {
        var scene: Scene?
    }

    static let stage = Stage()

    private let directory: URL
    private let monitor: FleetMonitor

    init(directory: URL, monitor: FleetMonitor) {
        self.directory = directory
        self.monitor = monitor
    }

    func run() async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Wait for live instances and a useful slice of history.
        await waitUntil(timeout: 90) { [monitor] in
            !monitor.live.isEmpty && monitor.history.count >= 20
        }

        let scenes: [Scene] = [
            Scene(section: .live, selectFirstRow: false, name: "01-live-sessions"),
            Scene(section: .live, selectFirstRow: true, name: "02-live-with-recap"),
            Scene(section: .history, selectFirstRow: true, name: "03-history-with-recap"),
        ]

        for scene in scenes {
            Self.stage.scene = scene
            // Two run-loop turns: one to apply the state, one to lay it out.
            await settle(frames: 8)
            capture(named: scene.name)
        }

        // The recap pane is SwiftUI over a material background. cacheDisplay
        // draws its content but not the material, leaving default-coloured text
        // black-on-black in light mode. Capturing again in dark mode makes that
        // same content legible — the text turns white while the unrendered
        // background stays dark. (ImageRenderer is not an option: it renders
        // neither ScrollView content nor Buttons.)
        NSApp.appearance = NSAppearance(named: .darkAqua)

        let darkScenes: [Scene] = [
            Scene(section: .live, selectFirstRow: true, name: "04-recap-live-dark"),
            Scene(section: .history, selectFirstRow: true, name: "05-recap-history-dark"),
        ]
        for scene in darkScenes {
            Self.stage.scene = scene
            await settle(frames: 8)
            capture(named: scene.name)
        }

        NSApp.appearance = NSAppearance(named: .aqua)
        await settle(frames: 4)

        // The inspector and menu bar popover live in view hierarchies that
        // cacheDisplay does not reach. Hosting the same SwiftUI views in a
        // throwaway opaque window gives an AppKit-backed hierarchy that does
        // capture — and unlike ImageRenderer, NSHostingView renders real
        // ScrollViews and Buttons.
        if let live = monitor.live.first {
            captureHosted(named: "07-recap-live", size: CGSize(width: 360, height: 940)) {
                SessionDetailView(session: live).environment(self.monitor)
            }
        }
        if let past = monitor.history.first(where: { !$0.digest.pullRequests.isEmpty })
            ?? monitor.history.first {
            captureHosted(named: "08-recap-history", size: CGSize(width: 360, height: 940)) {
                SessionDetailView(session: past).environment(self.monitor)
            }
        }
        captureHosted(named: "09-menu-bar", size: CGSize(width: 380, height: 480)) {
            MenuBarContent().environment(self.monitor)
        }

        NSApp.terminate(nil)
    }

    /// Renders a SwiftUI view through a temporary window and captures it.
    private func captureHosted<V: View>(named name: String, size: CGSize,
                                        @ViewBuilder content: () -> V) {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor

        let hosting = NSHostingView(rootView: AnyView(
            content().frame(width: size.width, height: size.height, alignment: .top)))
        hosting.frame = NSRect(origin: .zero, size: size)
        window.contentView = hosting

        // Off-screen but ordered in, so SwiftUI actually lays out and draws.
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderBack(nil)
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        capture(named: name, window: window)
        window.orderOut(nil)
    }

    // MARK: - Capture

    private func capture(named name: String, window: NSWindow? = nil) {
        guard let target = window ?? mainWindow(), let view = target.contentView else {
            FileHandle.standardError.write(Data("snapshot: no window for \(name)\n".utf8))
            return
        }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        rep.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        let url = directory.appendingPathComponent("\(name).png")
        try? data.write(to: url)
        FileHandle.standardError.write(Data("snapshot: wrote \(url.path)\n".utf8))
    }

    private func mainWindow() -> NSWindow? {
        NSApp.windows.first { $0.contentView != nil && $0.frame.width > 600 && $0.isVisible }
            ?? NSApp.windows.first { $0.contentView != nil && $0.frame.width > 600 }
    }

    /// The MenuBarExtra popover lives in its own small window.
    private func menuBarWindow() -> NSWindow? {
        NSApp.windows
            .filter { $0.contentView != nil && $0.frame.width <= 600 && $0.frame.height > 80 }
            .max { $0.frame.height < $1.frame.height }
    }

    // MARK: - Waiting

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !condition() {
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    private func settle(frames: Int) async {
        for _ in 0..<frames {
            try? await Task.sleep(for: .milliseconds(120))
        }
    }
}

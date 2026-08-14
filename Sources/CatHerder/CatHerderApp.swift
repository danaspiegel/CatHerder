import SwiftUI

enum AppWindow: String {
    case main = "fleet-monitor"
}

@main
struct CatHerderApp: App {
    /// One monitor instance shared by the window and the menu bar.
    @State private var monitor = FleetMonitor()

    init() {
        // Answers --check-automation and exits; a no-op otherwise.
        Diagnostics.runIfRequested()
    }

    /// Same key RootView reads, so the menu item and the view stay in step.
    @AppStorage("showsStatusBar") private var showsStatusBar = true

    var body: some Scene {
        Window("Cat Herder", id: AppWindow.main.rawValue) {
            RootView()
                .environment(monitor)
                .task {
                    monitor.start()
                    if let directory = SnapshotRunner.requestedDirectory {
                        await SnapshotRunner(directory: directory, monitor: monitor).run()
                    }
                }
        }
        .defaultSize(width: 1500, height: 860)
        .commands {
            CommandGroup(after: .toolbar) {
                Button(showsStatusBar ? "Hide Status Bar" : "Show Status Bar") {
                    showsStatusBar.toggle()
                }
                .keyboardShortcut("/", modifiers: .command)

                Button("Refresh Now") {
                    Task {
                        await monitor.refreshLive()
                        await monitor.loadHistory()
                    }
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }

        MenuBarExtra {
            MenuBarContent()
                .environment(monitor)
        } label: {
            // The label reflects fleet state at a glance: count plus a dot when
            // something is waiting on you.
            MenuBarLabel(
                total: monitor.live.count,
                needsAttention: monitor.needsAttentionCount
            )
        }
        .menuBarExtraStyle(.window)
    }
}

/// Menu bar title: an icon plus the live instance count.
private struct MenuBarLabel: View {
    let total: Int
    let needsAttention: Int

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: needsAttention > 0 ? "bolt.badge.clock.fill" : "bolt.horizontal.fill")
            if total > 0 {
                Text("\(total)").monospacedDigit()
            }
        }
    }
}

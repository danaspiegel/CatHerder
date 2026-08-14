import SwiftUI

/// The menu bar popover: a glance at the fleet without leaving what you're doing.
struct MenuBarContent: View {
    @Environment(FleetMonitor.self) private var monitor
    @Environment(\.openWindow) private var openWindow

    /// Measured height of the session list, so the popover fits its content.
    @State private var contentHeight: CGFloat = 0

    /// Beyond this the list scrolls rather than growing without bound.
    private static let maxListHeight: CGFloat = 560

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            if monitor.live.isEmpty {
                Text("No Claude Code instances running")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                // Every instance the label counts is listed here. The scroll
                // view is sized to its content so a short list shows no dead
                // space and a long one still stays a sane popover height.
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(monitor.live) { session in
                            MenuBarRow(session: session)
                            if session.id != monitor.live.last?.id {
                                Divider().padding(.leading, 34)
                            }
                        }
                    }
                    .background(
                        GeometryReader { proxy in
                            Color.clear
                                .onAppear { contentHeight = proxy.size.height }
                                .onChange(of: proxy.size.height) { _, height in
                                    contentHeight = height
                                }
                        }
                    )
                }
                .frame(height: min(max(contentHeight, 44), Self.maxListHeight))
            }

            Divider()
            footer
        }
        .frame(width: 380)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("Cat Herder").font(.headline)
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if monitor.isRefreshing {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var summary: String {
        let count = monitor.live.count
        guard count > 0 else { return "Nothing running" }
        var parts = ["\(count) instance\(count == 1 ? "" : "s")"]
        if monitor.workingCount > 0 { parts.append("\(monitor.workingCount) working") }
        if monitor.needsAttentionCount > 0 { parts.append("\(monitor.needsAttentionCount) need you") }
        return parts.joined(separator: " · ")
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button("Open Monitor") {
                openWindow(id: AppWindow.main.rawValue)
                NSApp.activate(ignoringOtherApps: true)
            }
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.link)
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private struct MenuBarRow: View {
    let session: MonitoredSession
    @Environment(FleetMonitor.self) private var monitor
    @State private var isHovering = false

    var body: some View {
        Button {
            monitor.focusTerminal(for: session)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                StatusBadge(status: session.status, showLabel: false)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(session.directoryName)
                            .fontWeight(.medium)
                            .lineLimit(1)
                        if let branch = session.git.branch {
                            Text(branch)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    // One line each, so every instance stays visible without
                    // scrolling — the popover is a glance, not a report.
                    Text(session.headline)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let ref = session.primaryNotionRef {
                        HStack(spacing: 3) {
                            Image(systemName: "doc.text").imageScale(.small)
                            Text(ref.displayTitle).lineLimit(1)
                        }
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    }
                }

                Spacer(minLength: 4)

                VStack(alignment: .trailing, spacing: 2) {
                    Text(Fmt.relative(session.lastActivity))
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Text("up \(Fmt.duration(session.process?.uptime))")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isHovering ? Color.primary.opacity(0.06) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Switch to this session's terminal tab")
    }
}

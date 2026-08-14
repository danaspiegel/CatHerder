import SwiftUI

// MARK: - Shared cells

/// The name given with `/rename`, or a clear placeholder when there is none.
struct NameCell: View {
    let session: MonitoredSession

    var body: some View {
        if let name = session.name {
            Text(name)
                .fontWeight(.medium)
                .lineLimit(2)
                .help(name)
        } else {
            Text("unnamed")
                .foregroundStyle(.tertiary)
                .help("Give this session a name with /rename")
        }
    }
}

/// Directory name with its tilde-path underneath.
struct DirectoryCell: View {
    let session: MonitoredSession

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(session.directoryName)
                .fontWeight(.medium)
                .lineLimit(1)
            Text(Fmt.tildePath(session.cwd))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.head)
        }
        .help(session.cwd ?? "Unknown working directory")
    }
}

/// Repo and branch, or a clear "not a git repo" when there is none.
struct GitCell: View {
    let git: GitInfo

    var body: some View {
        if git.isRepo {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(git.repoName ?? "—")
                        .lineLimit(1)
                    if git.isWorktree {
                        Text("worktree")
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }
                if let branch = git.branch {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.triangle.branch")
                            .imageScale(.small)
                        Text(branch).lineLimit(1).truncationMode(.middle)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                } else {
                    Text("no branch").font(.caption2).foregroundStyle(.tertiary)
                }
            }
        } else {
            Text("Not a git repo")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

/// The Notion card, clickable straight through to Notion.
struct NotionCell: View {
    let ref: NotionRef?

    var body: some View {
        if let ref {
            Button {
                if let url = ref.url { NSWorkspaceBridge.open(url: url) }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "doc.text")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                    Text(ref.displayTitle)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            .buttonStyle(.plain)
            .help("Open “\(ref.displayTitle)” in Notion")
        } else {
            Text("—").foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Live table

struct LiveSessionsTable: View {
    let rows: [MonitoredSession]
    @Binding var selection: MonitoredSession.ID?

    @Environment(FleetMonitor.self) private var monitor
    @State private var sortOrder = [KeyPathComparator(\MonitoredSession.sortableLastActivity, order: .reverse)]
    @State private var layout = ColumnLayoutStore(key: "columnLayout.live")

    private var sorted: [MonitoredSession] { rows.sorted(using: sortOrder) }

    var body: some View {
        Group {
            if rows.isEmpty {
                ContentUnavailableView(
                    "No Claude Code instances running",
                    systemImage: "moon.zzz",
                    description: Text("Start `claude` in a terminal and it will appear here within a few seconds.")
                )
            } else {
                table
            }
        }
    }

    private var table: some View {
        Table(sorted, selection: $selection, sortOrder: $sortOrder,
              columnCustomization: $layout.customization) {
            // Status is fixed: without it a row loses its clearest signal, so it
            // can be neither moved nor hidden.
            TableColumn("") { (session: MonitoredSession) in
                StatusBadge(status: session.status, showLabel: false)
                    .topAlignedCell()
            }
            .width(28)
            .disabledCustomizationBehavior(.all)

            TableColumn("Name", value: \.sortableName) { session in
                NameCell(session: session).topAlignedCell()
            }
            .width(min: 100, ideal: 150)
            .customizationID("name")

            TableColumn("Directory", value: \.directoryName) { session in
                DirectoryCell(session: session).topAlignedCell()
            }
            .width(min: 120, ideal: 165)
            .customizationID("directory")

            TableColumn("Repo / Branch") { (session: MonitoredSession) in
                GitCell(git: session.git).topAlignedCell()
            }
            .width(min: 110, ideal: 155)
            .customizationID("git")

            TableColumn("Notion card") { (session: MonitoredSession) in
                NotionCell(ref: session.primaryNotionRef).topAlignedCell()
            }
            .width(min: 110, ideal: 175)
            .customizationID("notion")

            TableColumn("Recap") { (session: MonitoredSession) in
                Text(session.headline)
                    .lineLimit(2)
                    .help(session.headline)
                    .topAlignedCell()
            }
            .width(min: 120, ideal: 180)
            .customizationID("recap")

            // Last-active and uptime share one column: two short lines read
            // better than two narrow columns, and it keeps every column visible
            // even in a narrow window.
            TableColumn("Activity", value: \.sortableLastActivity) { session in
                VStack(alignment: .leading, spacing: 1) {
                    Text(Fmt.relative(session.lastActivity))
                        .monospacedDigit()
                        .foregroundStyle(session.status == .working ? .primary : .secondary)
                    Text("up \(Fmt.duration(session.process?.uptime))")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
                .help("Last transcript activity, and how long the process has been running")
                .topAlignedCell()
            }
            .width(min: 86, ideal: 104)
            .customizationID("activity")
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: MonitoredSession.ID.self) { ids in
            contextMenu(for: ids)
        } primaryAction: { ids in
            if let id = ids.first, let session = rows.first(where: { $0.id == id }) {
                monitor.focusTerminal(for: session)
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for ids: Set<MonitoredSession.ID>) -> some View {
        if let id = ids.first, let session = rows.first(where: { $0.id == id }) {
            Button("Switch to Terminal Tab") { monitor.focusTerminal(for: session) }
            Button("Reveal Working Directory in Finder") { monitor.revealInFinder(session.cwd) }
            if let ref = session.primaryNotionRef, let url = ref.url {
                Button("Open Notion Card") { NSWorkspaceBridge.open(url: url) }
            }
            Divider()
            Button("Copy Session ID") { Clipboard.copy(session.sessionID) }
            Button("Copy Resume Command") {
                Clipboard.copy("cd \(session.cwd ?? "~") && claude --resume \(session.sessionID)")
            }
        }
    }
}

// MARK: - History table

struct HistoryTable: View {
    let rows: [MonitoredSession]
    @Binding var selection: MonitoredSession.ID?

    @Environment(FleetMonitor.self) private var monitor
    @State private var sortOrder = [KeyPathComparator(\MonitoredSession.sortableLastActivity, order: .reverse)]
    @State private var layout = ColumnLayoutStore(key: "columnLayout.history")

    private var sorted: [MonitoredSession] { rows.sorted(using: sortOrder) }

    var body: some View {
        Table(sorted, selection: $selection, sortOrder: $sortOrder,
              columnCustomization: $layout.customization) {
            TableColumn("Name", value: \.sortableName) { session in
                NameCell(session: session).topAlignedCell()
            }
            .width(min: 100, ideal: 145)
            .customizationID("name")

            TableColumn("Recap", value: \.headline) { session in
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.headline)
                        .fontWeight(.medium)
                        .lineLimit(2)
                    Text(session.sessionID.prefix(8))
                        .font(.caption2)
                        .monospaced()
                        .foregroundStyle(.tertiary)
                }
                .help(session.headline)
                .topAlignedCell()
            }
            .width(min: 140, ideal: 195)
            .customizationID("recap")

            TableColumn("Directory", value: \.directoryName) { session in
                DirectoryCell(session: session).topAlignedCell()
            }
            .width(min: 105, ideal: 140)
            .customizationID("directory")

            TableColumn("Repo / Branch") { (session: MonitoredSession) in
                GitCell(git: session.git).topAlignedCell()
            }
            .width(min: 100, ideal: 135)
            .customizationID("git")

            TableColumn("Notion card") { (session: MonitoredSession) in
                NotionCell(ref: session.primaryNotionRef).topAlignedCell()
            }
            .width(min: 100, ideal: 145)
            .customizationID("notion")

            TableColumn("Last active", value: \.sortableLastActivity) { session in
                VStack(alignment: .leading, spacing: 1) {
                    Text(Fmt.relative(session.lastActivity)).monospacedDigit()
                    Text(Fmt.absolute(session.lastActivity))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                .topAlignedCell()
            }
            .width(min: 86, ideal: 100)
            .customizationID("lastActive")

            TableColumn("Active for", value: \.sortableActiveSeconds) { session in
                VStack(alignment: .leading, spacing: 1) {
                    Text(Fmt.duration(session.digest.activeSeconds)).monospacedDigit()
                    Text("span \(Fmt.duration(session.digest.span))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .help("Working time excludes gaps longer than 5 minutes; span is first to last activity.")
                .topAlignedCell()
            }
            .width(min: 80, ideal: 92)
            .customizationID("activeFor")
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: MonitoredSession.ID.self) { ids in
            if let id = ids.first, let session = rows.first(where: { $0.id == id }) {
                Button("Reveal Working Directory in Finder") { monitor.revealInFinder(session.cwd) }
                if let ref = session.primaryNotionRef, let url = ref.url {
                    Button("Open Notion Card") { NSWorkspaceBridge.open(url: url) }
                }
                Divider()
                Button("Copy Session ID") { Clipboard.copy(session.sessionID) }
                Button("Copy Resume Command") {
                    Clipboard.copy("cd \(session.cwd ?? "~") && claude --resume \(session.sessionID)")
                }
            }
        }
        .overlay {
            if rows.isEmpty {
                ContentUnavailableView(
                    monitor.historyTotal == 0 ? "No transcripts found" : "Indexing…",
                    systemImage: monitor.historyTotal == 0 ? "tray" : "hourglass",
                    description: Text(monitor.historyTotal == 0
                        ? "Nothing under ~/.claude/projects yet."
                        : "Reading \(monitor.historyTotal) transcripts.")
                )
            }
        }
    }
}

// MARK: - Sort keys

extension MonitoredSession {
    /// Comparators need non-optional values, so absent dates sort oldest.
    var sortableLastActivity: Date { lastActivity ?? .distantPast }
    /// Unnamed sessions sort last rather than first.
    var sortableName: String { name ?? "\u{10FFFF}" }
    var sortableDuration: TimeInterval { duration ?? 0 }
    var sortableActiveSeconds: TimeInterval { digest.activeSeconds }
}

// MARK: - Clipboard

import AppKit

enum Clipboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

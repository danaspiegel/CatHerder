import SwiftUI

/// The recap pane: what this session is about, what it touched, and where to go next.
struct SessionDetailView: View {
    let session: MonitoredSession
    @Environment(FleetMonitor.self) private var monitor

    private var digest: TranscriptDigest { session.digest }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                Divider()
                facts
                if let ref = session.primaryNotionRef { notionSection(ref) }
                if !digest.pullRequests.isEmpty { pullRequestSection }
                if !digest.recentPrompts.isEmpty { promptsSection }
                if !digest.editedFiles.isEmpty { filesSection }
                activitySection
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                StatusBadge(status: session.status)
                    .font(.caption)
                Spacer()
                if session.isLive {
                    Text("live")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.green.opacity(0.14), in: Capsule())
                }
            }

            Text(session.headline)
                .font(.title3.weight(.semibold))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            if session.isLive {
                Button {
                    monitor.focusTerminal(for: session)
                } label: {
                    Label("Switch to Terminal Tab", systemImage: "arrow.up.forward.app")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .help(terminalHelp)
            } else {
                Button {
                    Clipboard.copy("cd \(session.cwd ?? "~") && claude --resume \(session.sessionID)")
                    monitor.statusMessage = .init(text: "Resume command copied.", isError: false)
                } label: {
                    Label("Copy Resume Command", systemImage: "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
            }
        }
    }

    private var terminalHelp: String {
        guard let terminal = session.process?.terminal else { return "" }
        if terminal.canActivateTab {
            return "Focuses \(terminal.displayName) tab on \(terminal.tty ?? "?")"
        }
        return "\(terminal.displayName) can't be driven tab-by-tab; the app will just come forward."
    }

    // MARK: - Facts

    private var facts: some View {
        VStack(alignment: .leading, spacing: 8) {
            factRow("Directory", Fmt.tildePath(session.cwd), mono: true) {
                monitor.revealInFinder(session.cwd)
            }

            if session.git.isRepo {
                factRow("Repository", session.git.repoName ?? "—")
                factRow("Branch", session.git.branch ?? "no branch", mono: true)
                if session.git.isWorktree {
                    factRow("Checkout", "linked worktree")
                }
            } else {
                factRow("Repository", "not a git repo")
            }

            factRow("Session ID", session.sessionID, mono: true) {
                Clipboard.copy(session.sessionID)
                monitor.statusMessage = .init(text: "Session ID copied.", isError: false)
            }

            if let process = session.process {
                factRow("Process", "pid \(process.pid) · \(String(format: "%.1f", process.cpuPercent))% CPU")
                factRow("Started", Fmt.absolute(process.startedAt))
                factRow("Running for", Fmt.duration(process.uptime, style: .full))
                factRow("Terminal", "\(process.terminal.displayName) · \(process.terminal.tty ?? "no tty")")
            }

            factRow("Last active", "\(Fmt.relative(digest.lastActivity)) · \(Fmt.absolute(digest.lastActivity))")

            if !session.isLive {
                factRow("Active time", Fmt.duration(digest.activeSeconds, style: .full))
                factRow("Total span", Fmt.duration(digest.span, style: .full))
            }

            factRow("Model", Fmt.model(digest.lastModel))
            if let mode = digest.permissionMode {
                factRow("Permissions", mode)
            }
        }
    }

    @ViewBuilder
    private func factRow(_ label: String, _ value: String, mono: Bool = false,
                         action: (() -> Void)? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
            if let action {
                Button(value, action: action)
                    .buttonStyle(.plain)
                    .font(mono ? .caption.monospaced() : .caption)
                    .foregroundStyle(.tint)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            } else {
                Text(value)
                    .font(mono ? .caption.monospaced() : .caption)
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Sections

    private func notionSection(_ ref: NotionRef) -> some View {
        Section {
            Button {
                if let url = ref.url { NSWorkspaceBridge.open(url: url) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "doc.text.fill").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ref.displayTitle)
                            .fontWeight(.medium)
                            .multilineTextAlignment(.leading)
                        Text("Open in Notion").font(.caption2).foregroundStyle(.tint)
                    }
                    Spacer()
                    Image(systemName: "arrow.up.right.square").foregroundStyle(.tertiary)
                }
                .padding(10)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)

            let others = session.workedNotionRefs.count - 1
            if others > 0 {
                Text("\(others) other card\(others == 1 ? "" : "s") touched in this session")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        } header: {
            sectionHeader("Notion card", systemImage: "doc.text")
        }
    }

    private var pullRequestSection: some View {
        Section {
            ForEach(digest.pullRequests.sorted(by: { $0.number > $1.number })) { pr in
                Button {
                    if let url = URL(string: pr.url) { NSWorkspaceBridge.open(url: url) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.pull").imageScale(.small)
                        Text(pr.display).font(.caption.monospaced())
                        Spacer()
                        Image(systemName: "arrow.up.right").imageScale(.small).foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
            }
        } header: {
            sectionHeader("Pull requests", systemImage: "arrow.triangle.pull")
        }
    }

    private var promptsSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(digest.recentPrompts.enumerated()), id: \.offset) { index, prompt in
                    HStack(alignment: .top, spacing: 6) {
                        Circle()
                            .fill(index == 0 ? Color.accentColor : Color.secondary.opacity(0.4))
                            .frame(width: 5, height: 5)
                            .padding(.top, 5)
                        Text(prompt.firstLine(max: 160))
                            .font(.caption)
                            .foregroundStyle(index == 0 ? .primary : .secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        } header: {
            sectionHeader("Recent instructions", systemImage: "text.bubble")
        }
    }

    private var filesSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(digest.editedFiles.prefix(12), id: \.self) { path in
                    Button {
                        NSWorkspaceBridge.reveal(path: path)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "doc").imageScale(.small).foregroundStyle(.tertiary)
                            Text(shortenRelativeToCWD(path))
                                .font(.caption.monospaced())
                                .lineLimit(1)
                                .truncationMode(.head)
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                    .help(path)
                }
                if digest.editedFiles.count > 12 {
                    Text("and \(digest.editedFiles.count - 12) more")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        } header: {
            sectionHeader("Files changed", systemImage: "pencil")
        }
    }

    private var activitySection: some View {
        Section {
            let columns = [GridItem(.adaptive(minimum: 92), spacing: 8)]
            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                metric("Turns", "\(digest.userMessageCount)")
                metric("Replies", "\(digest.assistantMessageCount)")
                if digest.agentsLaunched > 0 { metric("Agents", "\(digest.agentsLaunched)") }
                metric("Output", Fmt.tokens(digest.outputTokens))
                ForEach(topTools, id: \.0) { name, count in
                    metric(name, "\(count)")
                }
            }

            if !digest.skillsUsed.isEmpty {
                tagRow(title: "Skills", items: digest.skillsUsed)
            }
            if !digest.mcpServers.isEmpty {
                tagRow(title: "MCP", items: digest.mcpServers.map { $0.components(separatedBy: ":").last ?? $0 })
            }
        } header: {
            sectionHeader("Activity", systemImage: "chart.bar")
        }
    }

    private var topTools: [(String, Int)] {
        digest.toolCounts.sorted { lhs, rhs in
            lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
        }
        .prefix(6)
        .map { ($0.key, $0.value) }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.callout.weight(.medium).monospacedDigit())
            Text(label).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
    }

    private func tagRow(title: String, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(Set(items).sorted().joined(separator: " · "))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }

    private func sectionHeader(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .padding(.top, 2)
    }

    /// Trims the working-directory prefix so file lists stay readable.
    private func shortenRelativeToCWD(_ path: String) -> String {
        guard let cwd = session.cwd, path.hasPrefix(cwd) else { return Fmt.tildePath(path) }
        return String(path.dropFirst(cwd.count).drop(while: { $0 == "/" }))
    }
}

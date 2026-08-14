import SwiftUI

enum FleetSection: String, Hashable, CaseIterable, Identifiable {
    case live
    case history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .live: "Live"
        case .history: "History"
        }
    }
}

struct RootView: View {
    @Environment(FleetMonitor.self) private var monitor

    @State private var section: FleetSection = .live
    @State private var selection: MonitoredSession.ID?
    @State private var search = ""
    @State private var showsInspector = true

    /// Persisted so the bar's visibility survives relaunches. The ⌘/ menu item
    /// in CatHerderApp writes the same key.
    @AppStorage("showsStatusBar") private var showsStatusBar = true

    var body: some View {
        // No navigation sidebar: there are exactly two lists, which is a job for
        // a segmented control rather than a whole column.
        VStack(spacing: 0) {
            sessionList
            if showsStatusBar {
                Divider()
                statusBar
            }
        }
            // Window title stays leading, right after the traffic lights.
            // Nothing uses `.navigation`: those items lay out *before* the
            // title and would push it inline, wedged mid-toolbar.
            //
            // The list's controls belong to the right edge of the *list*, the
            // inspector toggle to the right edge of the *window*. A spacer
            // between them does not work: macOS groups adjacent toolbar items
            // into one rounded container, so an invisible spacer simply
            // stretches the group. Instead each control is declared on the view
            // that owns its section — these on the list, the toggle on the
            // inspector — and the toolbar splits at the column boundary.
            // The inspector's item stays put when the pane collapses, so no
            // fallback copy is needed (adding one shows two buttons).
            //
            // `.searchable` is deliberately not used: it installs its own field
            // after every custom item, which would put it last.
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Picker("View", selection: $section) {
                        ForEach(FleetSection.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .help("Switch between running instances and past sessions")
                }
                ToolbarItem(placement: .primaryAction) {
                    SearchField(text: $search, placeholder: "Filter sessions")
                        .frame(width: 220)
                }
                if monitor.historyLoaded < monitor.historyTotal {
                    ToolbarItem(placement: .primaryAction) { indexingIndicator }
                }
            }
            .inspector(isPresented: $showsInspector) {
                detail
                    .inspectorColumnWidth(min: 290, ideal: 340, max: 460)
                    // Declared on the inspector's content, so it lands in the
                    // inspector's own toolbar section at the window's right
                    // edge — and the list's controls right-align within the
                    // list's section instead of spanning the whole window.
                    .toolbar {
                        // Without this the toggle sits at the inspector's
                        // leading edge; the flexible spacer pushes it to the
                        // window's trailing edge.
                        //
                        // `ToolbarSpacer` needs the macOS 26 SDK to *compile*,
                        // not merely to run, so an `#available` check alone
                        // still breaks older toolchains. The compiler guard is a
                        // proxy for that SDK: Swift 6.2 is what ships with it.
                        #if compiler(>=6.2)
                        if #available(macOS 26.0, *) {
                            ToolbarSpacer(.flexible, placement: .primaryAction)
                        }
                        #endif
                        ToolbarItem(placement: .primaryAction) { inspectorToggle }
                    }
            }
            .onChange(of: section) { _, _ in
                // A row selected in one list does not exist in the other.
                selection = nil
            }
            .overlay(alignment: .bottom) {
                if let message = monitor.statusMessage {
                    StatusToast(message: message) { monitor.statusMessage = nil }
                }
            }
            // Dev-only: lets --snapshot drive navigation before capturing.
            .onChange(of: SnapshotRunner.stage.scene) { _, scene in
                guard let scene else { return }
                section = scene.section
                selection = scene.selectFirstRow ? rows.first?.id : nil
            }
    }

    /// Fleet summary along the bottom of the list. Bound to the list rather
    /// than the window, so it stops at the inspector's edge like the toolbar
    /// controls above it.
    private var statusBar: some View {
        HStack(spacing: 12) {
            count(SessionStatus.working, monitor.workingCount, "working")
            count(SessionStatus.awaitingInput, monitor.needsAttentionCount, "need you")

            Divider().frame(height: 11)

            Text("^[\(monitor.live.count) instance](inflect: true) running")
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            if monitor.historyLoaded < monitor.historyTotal {
                Text("Indexing \(monitor.historyLoaded)/\(monitor.historyTotal)")
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }

            Text(rowCountLabel)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.bar)
    }

    /// One "● N label" cell, dimmed when the count is zero.
    private func count(_ status: SessionStatus, _ value: Int, _ label: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: status.symbol)
                .imageScale(.small)
                .foregroundStyle(value > 0 ? status.tint : Color.secondary)
            Text("\(value) \(label)")
                .monospacedDigit()
                .foregroundStyle(value > 0 ? .primary : .secondary)
        }
        .help(status == .working
              ? "Instances producing output right now"
              : "Instances waiting on a reply from you")
    }

    private var rowCountLabel: String {
        let total = section == .live ? monitor.live.count : monitor.history.count
        if !search.isEmpty && rows.count != total {
            return "\(rows.count) of \(total) shown"
        }
        return section == .live ? "" : "\(total) sessions"
    }

    private var inspectorToggle: some View {
        Button {
            showsInspector.toggle()
        } label: {
            Label("Recap", systemImage: "sidebar.trailing")
        }
        .help(showsInspector ? "Hide the recap pane" : "Show the recap pane")
    }

    /// Shown only while history is still being parsed, so the toolbar is
    /// otherwise free of status chrome.
    private var indexingIndicator: some View {
        ProgressView(value: Double(monitor.historyLoaded),
                     total: Double(max(monitor.historyTotal, 1)))
            .progressViewStyle(.circular)
            .controlSize(.small)
            .help("Indexing transcripts: \(monitor.historyLoaded) of \(monitor.historyTotal)")
    }

    // MARK: - List

    private var rows: [MonitoredSession] {
        let source = section == .live ? monitor.live : monitor.history
        guard !search.isEmpty else { return source }
        let needle = search.lowercased()
        return source.filter { row in
            let haystack = [
                row.cwd, row.git.branch, row.git.repoName, row.headline,
                row.primaryNotionRef?.displayTitle, row.sessionID
            ]
            return haystack.compactMap { $0?.lowercased() }.contains { $0.contains(needle) }
        }
    }

    @ViewBuilder
    private var sessionList: some View {
        switch section {
        case .live:
            LiveSessionsTable(rows: rows, selection: $selection)
        case .history:
            HistoryTable(rows: rows, selection: $selection)
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let selection, let session = rows.first(where: { $0.id == selection }) {
            SessionDetailView(session: session)
        } else {
            ContentUnavailableView(
                "No session selected",
                systemImage: "sidebar.right",
                description: Text("Pick a session to see its recap, files, and links.")
            )
        }
    }
}

// MARK: - Toast

struct StatusToast: View {
    let message: FleetMonitor.StatusMessage
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: message.isError
                  ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(message.isError ? .orange : .green)
            Text(message.text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            if let action = message.action {
                Button(action.title) {
                    switch action {
                    case .openAutomationSettings:
                        TerminalActivator.openAutomationSettings()
                    }
                    dismiss()
                }
                .buttonStyle(.link)
                .fontWeight(.semibold)
            }
            Button("Dismiss", action: dismiss)
                .buttonStyle(.link)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 520)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
        .shadow(radius: 8, y: 2)
        .padding(.bottom, 16)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .task(id: message.id) {
            // Only confirmations time out. A failure usually needs the user to
            // do something, so it waits to be dismissed rather than vanishing
            // before it has been read.
            guard !message.isError else { return }
            try? await Task.sleep(for: .seconds(4))
            dismiss()
        }
    }
}

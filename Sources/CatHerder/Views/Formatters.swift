import SwiftUI

enum Fmt {

    /// "2m ago", "3h ago" — compact enough for a table cell.
    static func relative(_ date: Date?) -> String {
        guard let date else { return "—" }
        let seconds = Date().timeIntervalSince(date)
        if seconds < 10 { return "just now" }
        return duration(seconds, style: .abbreviated) + " ago"
    }

    enum Style { case abbreviated, full }

    /// Durations read as "4d 2h", "1h 12m", "45s".
    static func duration(_ interval: TimeInterval?, style: Style = .abbreviated) -> String {
        guard let interval, interval.isFinite, interval >= 0 else { return "—" }
        let total = Int(interval)
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60

        switch style {
        case .abbreviated:
            if days > 0 { return hours > 0 ? "\(days)d \(hours)h" : "\(days)d" }
            if hours > 0 { return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h" }
            if minutes > 0 { return "\(minutes)m" }
            return "\(seconds)s"
        case .full:
            var parts: [String] = []
            if days > 0 { parts.append("\(days) day\(days == 1 ? "" : "s")") }
            if hours > 0 { parts.append("\(hours) hour\(hours == 1 ? "" : "s")") }
            if minutes > 0 { parts.append("\(minutes) min") }
            if parts.isEmpty { parts.append("\(seconds) sec") }
            return parts.joined(separator: " ")
        }
    }

    static func absolute(_ date: Date?) -> String {
        guard let date else { return "—" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter.string(from: date)
    }

    /// Shortens a home-relative path: /Users/you/Source/x → ~/Source/x
    static func tildePath(_ path: String?) -> String {
        guard let path else { return "—" }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) { return "~" + path.dropFirst(home.count) }
        return path
    }

    static func tokens(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1_000 { return String(format: "%.1fk", Double(count) / 1_000) }
        return "\(count)"
    }

    /// "claude-opus-5" → "Opus 5"
    static func model(_ raw: String?) -> String {
        guard let raw else { return "—" }
        var name = raw
        // Vendor prefixes stack: "us.anthropic.claude-opus-5" needs two passes,
        // and stripping only once leaves "claude-…", which reads as "Claude".
        var strippedSomething = true
        while strippedSomething {
            strippedSomething = false
            for prefix in ["us.anthropic.", "eu.anthropic.", "apac.anthropic.",
                           "anthropic.", "claude-"] where name.hasPrefix(prefix) {
                name = String(name.dropFirst(prefix.count))
                strippedSomething = true
            }
        }
        let parts = name.split(separator: "-").map(String.init)
        guard let family = parts.first else { return raw }
        let capitalized = family.prefix(1).uppercased() + family.dropFirst()
        if parts.count > 1, let version = parts.dropFirst().first, version.first?.isNumber == true {
            return "\(capitalized) \(version)"
        }
        return capitalized
    }
}

extension SessionStatus {
    var tint: Color {
        switch self {
        case .working: .green
        case .awaitingInput: .orange
        case .idle: .secondary
        case .ended: .secondary
        }
    }
}

/// Coloured status dot with its label, used in tables and the menu bar.
struct StatusBadge: View {
    let status: SessionStatus
    var showLabel = true

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: status.symbol)
                .foregroundStyle(status.tint)
                .imageScale(.small)
            if showLabel {
                Text(status.label)
                    .foregroundStyle(status == .working ? .primary : .secondary)
            }
        }
        .help(status.label)
    }
}

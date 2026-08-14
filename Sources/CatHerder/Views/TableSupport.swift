import SwiftUI

// MARK: - Cell alignment

extension View {
    /// Pins a table cell's content to the top of its row.
    ///
    /// Rows grow to fit their tallest cell, so single-line cells would otherwise
    /// float in the vertical centre while their two-line neighbours fill the
    /// row — which reads as misalignment straight down the table.
    func topAlignedCell() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Persisted column order

/// Stores a `Table`'s column order and visibility in user defaults.
///
/// `TableColumnCustomization` is `Codable` but not `RawRepresentable`, so it
/// cannot go straight into `@AppStorage`. This wraps it: the binding is handed
/// to the table, and every change is encoded to JSON under `key`.
@MainActor
@Observable
final class ColumnLayoutStore {
    private let key: String
    private let defaults: UserDefaults

    var customization: TableColumnCustomization<MonitoredSession> {
        didSet { persist() }
    }

    init(key: String, defaults: UserDefaults = .standard) {
        self.key = key
        self.defaults = defaults

        if let data = defaults.string(forKey: key)?.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(
                TableColumnCustomization<MonitoredSession>.self, from: data) {
            customization = decoded
        } else {
            customization = TableColumnCustomization<MonitoredSession>()
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(customization),
              let json = String(data: data, encoding: .utf8) else { return }
        defaults.set(json, forKey: key)
    }
}

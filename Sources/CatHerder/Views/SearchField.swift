import AppKit
import SwiftUI

/// A native `NSSearchField` for the toolbar.
///
/// `.searchable` would be the obvious choice, but on macOS it always installs
/// itself at the trailing end of the toolbar, after any custom items — which
/// puts the filter field to the right of the inspector toggle and reads
/// backwards. Wrapping the AppKit control keeps the system appearance and
/// behaviour (magnifier, clear button, rounded bezel, Escape to clear) while
/// letting the toolbar decide the order.
struct SearchField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.delegate = context.coordinator
        field.placeholderString = placeholder
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.focusRingType = .default
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        // Only write when it actually differs, or typing fights the update.
        if field.stringValue != text { field.stringValue = text }
        if field.placeholderString != placeholder { field.placeholderString = placeholder }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        private let text: Binding<String>

        init(text: Binding<String>) { self.text = text }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}

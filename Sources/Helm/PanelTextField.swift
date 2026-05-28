import SwiftUI
import AppKit

/// AppKit-backed text field for the new-project form. SwiftUI's `TextField` inside our
/// non-activating panel was both (a) failing to show its caret and (b) not forwarding
/// the standard edit shortcuts — symptoms of the field editor not getting wired into the
/// responder chain when the app is `LSUIElement` + the window is `.nonactivatingPanel`.
///
/// This wrapper sidesteps both by hosting an `NSTextField` directly. The field editor's
/// standard `selectAll(_:)`, `copy:`, `paste:`, `cut:`, `undo:` actions then work
/// natively, and we expose Tab/Return as discrete handlers for autocomplete / submit.
struct PanelTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = ""
    var fontSize: CGFloat = 14
    var autofocus: Bool = false
    /// Return true to consume Tab (e.g. we autocompleted in place); false lets the
    /// responder chain move focus to the next text field.
    var onTab: () -> Bool = { false }
    /// Return true to consume Return (submitted from this field).
    var onReturn: () -> Bool = { false }

    func makeNSView(context: Context) -> NSTextField {
        let tf = NSTextField()
        tf.isBordered = false
        tf.drawsBackground = false
        tf.focusRingType = .none
        tf.isEditable = true
        tf.isSelectable = true
        tf.font = .systemFont(ofSize: fontSize)
        tf.placeholderString = placeholder
        tf.stringValue = text
        tf.delegate = context.coordinator
        tf.usesSingleLineMode = true
        tf.cell?.wraps = false
        tf.cell?.isScrollable = true
        context.coordinator.parent = self
        return tf
    }

    func updateNSView(_ tf: NSTextField, context: Context) {
        context.coordinator.parent = self
        if tf.stringValue != text { tf.stringValue = text }
        if tf.placeholderString != placeholder { tf.placeholderString = placeholder }
        if autofocus && !context.coordinator.didAutofocus {
            context.coordinator.didAutofocus = true
            DispatchQueue.main.async { tf.window?.makeFirstResponder(tf) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PanelTextField
        var didAutofocus = false

        init(_ p: PanelTextField) { parent = p }

        func controlTextDidChange(_ notification: Notification) {
            guard let tf = notification.object as? NSTextField else { return }
            parent.text = tf.stringValue
        }

        /// Intercept Tab (autocomplete) and Return (submit) before they hit the default
        /// behaviors (focus-move and field-editor commit). Everything else — including
        /// arrow keys, ⌘A, ⌘C, ⌘V, ⌘X, ⌘Z — falls through to the field editor.
        func control(_ control: NSControl,
                     textView: NSTextView,
                     doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertTab(_:)) {
                return parent.onTab()
            }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                return parent.onReturn()
            }
            return false
        }
    }
}

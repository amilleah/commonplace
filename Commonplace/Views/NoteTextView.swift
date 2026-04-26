import SwiftUI
import AppKit

/// Wraps `NSTextView` in an `NSScrollView` with an overlay (thin, autohiding)
/// scroller style. SwiftUI's `TextEditor` uses the system's default scroller
/// style, which on most user systems is the fat legacy scrollbar that's always
/// visible even when the text fits — hence this wrapper. Also surfaces
/// ⌘+Return and Escape as callbacks, which `TextEditor` can't cleanly expose.
struct NoteTextView: NSViewRepresentable {
    @Binding var text: String
    var onSubmit: () -> Void
    var onCancel: () -> Void
    var onFocusLost: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let textView = KeyTextView()
        textView.delegate = context.coordinator
        textView.string = text
        textView.font = Self.serifFont(size: 13)
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.autoresizingMask = [.width]

        if let container = textView.textContainer {
            container.widthTracksTextView = true
        }

        textView.onCmdReturn = onSubmit
        textView.onEscape = onCancel

        scrollView.documentView = textView

        DispatchQueue.main.async {
            textView.window?.makeFirstResponder(textView)
        }

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? KeyTextView else { return }
        if textView.string != text {
            textView.string = text
        }
        textView.onCmdReturn = onSubmit
        textView.onEscape = onCancel
    }

    static func serifFont(size: CGFloat) -> NSFont {
        if let serif = NSFont(name: "New York", size: size) { return serif }
        return .systemFont(ofSize: size)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NoteTextView
        init(_ parent: NoteTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }

        func textDidEndEditing(_ notification: Notification) {
            parent.onFocusLost()
        }
    }
}

/// `NSTextView` subclass that surfaces ⌘+Return and Escape as callbacks.
/// Plain Return still inserts a newline (normal prose behavior).
final class KeyTextView: NSTextView {
    var onCmdReturn: (() -> Void)?
    var onEscape: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) &&
           (event.keyCode == 36 || event.keyCode == 76) {
            onCmdReturn?()
            return
        }
        if event.keyCode == 53 {
            onEscape?()
            return
        }
        super.keyDown(with: event)
    }
}

import SwiftUI
import AppKit

/// iMessage-style expanding text input backed by NSTextView.
/// Placeholder aligns perfectly with the cursor. Grows from 1 line
/// up to 6, then scrolls. Enter = newline, Cmd+Return = submit.
struct ExpandingNoteInput: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let onSubmit: () -> Void

    static let font = NSFont.systemFont(ofSize: 13)
    fileprivate static let lineH: CGFloat = 18
    fileprivate static let maxLines = 6
    fileprivate static let pad: CGFloat = 6

    static var minHeight: CGFloat { lineH + pad * 2 }
    static var maxHeight: CGFloat { lineH * CGFloat(maxLines) + pad * 2 }

    func makeNSView(context: Context) -> ExpandingScrollView {
        let sv = ExpandingScrollView()
        sv.hasVerticalScroller = true
        sv.autohidesScrollers = true
        sv.borderType = .noBorder
        sv.drawsBackground = false
        sv.preferredHeight = Self.minHeight

        let tv = PlaceholderTextView()
        tv.isRichText = false
        tv.allowsUndo = true
        tv.font = Self.font
        tv.textColor = .labelColor
        tv.backgroundColor = .clear
        tv.drawsBackground = false
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.textContainerInset = NSSize(width: Self.pad, height: Self.pad)
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.lineFragmentPadding = 0
        tv.delegate = context.coordinator
        tv.placeholderString = placeholder
        sv.documentView = tv

        return sv
    }

    func updateNSView(_ sv: ExpandingScrollView, context: Context) {
        guard let tv = sv.documentView as? PlaceholderTextView else { return }
        if tv.string != text {
            tv.string = text
            tv.needsDisplay = true
        }
        context.coordinator.resize(tv, sv)
    }

    @available(macOS 13.0, *)
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ExpandingScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 200, height: nsView.preferredHeight)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let parent: ExpandingNoteInput
        init(_ p: ExpandingNoteInput) { parent = p }

        func textDidChange(_ n: Notification) {
            guard let tv = n.object as? NSTextView else { return }
            parent.text = tv.string
            if let sv = tv.enclosingScrollView as? ExpandingScrollView { resize(tv, sv) }
        }

        func resize(_ tv: NSTextView, _ sv: ExpandingScrollView) {
            guard let c = tv.textContainer, let lm = tv.layoutManager else { return }
            lm.ensureLayout(for: c)
            let th = lm.usedRect(for: c).height
            sv.preferredHeight = min(
                max(th + ExpandingNoteInput.pad * 2, ExpandingNoteInput.minHeight),
                ExpandingNoteInput.maxHeight
            )
        }

        func textView(_ tv: NSTextView, doCommandBy sel: Selector) -> Bool {
            if sel == #selector(NSResponder.insertNewline(_:)),
               let e = NSApp.currentEvent, e.modifierFlags.contains(.command) {
                parent.onSubmit()
                return true
            }
            return false
        }
    }
}

final class ExpandingScrollView: NSScrollView {
    var preferredHeight: CGFloat = 30 {
        didSet {
            guard oldValue != preferredHeight else { return }
            invalidateIntrinsicContentSize()
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: preferredHeight)
    }
}

private final class PlaceholderTextView: NSTextView {
    var placeholderString = ""

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholderString.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: ExpandingNoteInput.font,
            .foregroundColor: NSColor.tertiaryLabelColor
        ]
        let ins = textContainerInset
        placeholderString.draw(
            in: NSRect(x: ins.width, y: ins.height,
                       width: bounds.width - ins.width * 2, height: bounds.height),
            withAttributes: attrs
        )
    }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return super.resignFirstResponder()
    }
}

import SwiftUI
import AppKit
import Combine

// MARK: - Toast State

enum ToastState {
    case collapsed
    case compact     // text captures: minimal preview (note field only in expanded)
    case hovered
    case expanded
}

// MARK: - State Holder

class ToastStateHolder: ObservableObject {
    @Published var state: ToastState = .collapsed
    @Published var timerProgress: CGFloat = 1.0
}

// MARK: - CopyToastController

final class CopyToastController: ManagedWindowController {
    static let shared = CopyToastController()

    private var panel: KeyablePanel?
    private var hostingView: NSView?
    private var tickTimer: Timer?
    private var stateHolder: ToastStateHolder?
    private var remainingTime: TimeInterval = 0
    private var currentEntryId: String?
    private var onAnnotationSubmit: ((String, String) -> Void)?
    private var stateObserver: AnyCancellable?
    private var hoverHandler: HoverHandler?
    private var frameObserver: NSObjectProtocol?
    private let compactWidth: CGFloat = 300
    private let expandedWidth: CGFloat = 480
    private var currentDismissDelay: TimeInterval = 8.0
    private var timerPermanentlyPaused = false
    private var isAnimatingToCenter = false
    private var clipboardPollTimer: Timer?
    private var currentImage: NSImage?
    private var currentContent: String?
    private var currentFilePath: String?
    private var menuTarget: MaterialMenuTarget?
    private var annotationWindow: NSWindow?
    private var annotationDelegate: PanelWindowDelegate?

    /// Controller-managed transcriber — lifecycle is explicit, not @StateObject.
    /// This ensures stopRecording() is always called before deallocation.
    private var transcriber: SpeechTranscriber?

    /// Generation counter: incremented on every show/dismiss cycle.
    /// Async callbacks compare against this to detect staleness.
    private var generation: Int = 0

    func show(content: String, entryId: String, sourceUrl: String? = nil, sourceApp: String? = nil, windowTitle: String? = nil, onAnnotation: @escaping (String, String) -> Void) {
        showInternal(image: nil, content: content, filePath: nil, badgeLabel: "Screenshot", entryId: entryId, sourceUrl: sourceUrl, sourceApp: sourceApp, windowTitle: windowTitle, onAnnotation: onAnnotation)
    }

    func show(image: NSImage, content: String, filePath: String?, badgeLabel: String = "Screenshot", entryId: String, sourceUrl: String? = nil, sourceApp: String? = nil, windowTitle: String? = nil, onAnnotation: @escaping (String, String) -> Void) {
        showInternal(image: image, content: content, filePath: filePath, badgeLabel: badgeLabel, entryId: entryId, sourceUrl: sourceUrl, sourceApp: sourceApp, windowTitle: windowTitle, onAnnotation: onAnnotation)
    }

    private func showInternal(image: NSImage?, content: String, filePath: String?, badgeLabel: String, entryId: String, sourceUrl: String? = nil, sourceApp: String? = nil, windowTitle: String? = nil, onAnnotation: @escaping (String, String) -> Void) {
        dismiss(animated: false)

        generation += 1
        let showGeneration = generation

        self.currentEntryId = entryId
        self.onAnnotationSubmit = onAnnotation
        self.currentImage = image
        self.currentContent = content
        self.currentFilePath = filePath

        let hasImage = image != nil
        self.currentDismissDelay = 8.0

        let stateHolder = ToastStateHolder()
        stateHolder.state = hasImage ? .collapsed : .compact
        self.stateHolder = stateHolder

        // Create transcriber with controller-managed lifecycle
        let transcriber = SpeechTranscriber()
        self.transcriber = transcriber

        let toastView = CopyToastView(
            content: content,
            image: image,
            filePath: filePath,
            badgeLabel: badgeLabel,
            sourceUrl: sourceUrl,
            sourceApp: sourceApp,
            windowTitle: windowTitle,
            entryId: entryId,
            stateHolder: stateHolder,
            transcriber: transcriber,
            onSubmit: { [weak self] note in
                guard let self, self.generation == showGeneration else { return }
                guard let id = self.currentEntryId else { return }
                if !note.isEmpty {
                    self.onAnnotationSubmit?(id, note)
                }
                self.dismiss(animated: true)
            },
            onDismiss: { [weak self] in
                guard let self, self.generation == showGeneration else { return }
                self.dismiss(animated: true)
            },
            onNoteFocusChanged: { [weak self] focused in
                guard let self, self.generation == showGeneration else { return }
                if focused {
                    self.pauseDismissTimer()
                } else if !self.timerPermanentlyPaused {
                    self.resumeDismissTimer()
                }
            },
            onExpand: { [weak self] in
                guard let self, self.generation == showGeneration else { return }
                guard let entryId = self.currentEntryId else { return }
                self.dismiss(animated: true)
                BrowseWindowController.shared.showHighlight(entryId)
            }
        )

        let initialHeight: CGFloat = hasImage ? 160 : 120

        let hv = NSHostingView(rootView: toastView)
        hv.postsFrameChangedNotifications = true
        self.hostingView = hv

        let p = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: initialHeight),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isFloatingPanel = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.isMovableByWindowBackground = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.contentView = hv
        p.isOpaque = false
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        positionPanel(p, height: initialHeight)

        p.alphaValue = 0
        p.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            p.animator().alphaValue = 1
        }

        self.panel = p

        // Right-click context menu — unified with the Browse card menu.
        let target = MaterialMenuTarget()
        target.onCopy = { [weak self] in
            guard let self else { return }
            if self.currentImage != nil {
                self.performCopyImage()
            } else {
                self.performCopyText()
            }
        }
        target.onOpen = { [weak self] in
            guard let self, let entryId = self.currentEntryId,
                  let highlight = DatabaseManager.shared.highlight(byId: entryId) else { return }
            MaterialAction.open(highlight)
        }
        target.onRevealInFinder = { [weak self] in self?.performShowInFinder() }
        target.onShare = { [weak self] anchor in
            guard let self, let entryId = self.currentEntryId,
                  let highlight = DatabaseManager.shared.highlight(byId: entryId) else { return }
            presentShareMenu(for: highlight, relativeTo: anchor)
        }
        target.onToggleTag = { [weak self] tagId in
            guard let self, let entryId = self.currentEntryId else { return }
            let applied = Set(DatabaseManager.shared.tagsForHighlight(id: entryId).map { $0.id })
            if applied.contains(tagId) {
                DatabaseManager.shared.removeTag(tagId, fromHighlight: entryId)
            } else {
                DatabaseManager.shared.addTag(tagId, toHighlight: entryId)
            }
        }
        target.onNewCollection = { [weak self] in
            guard let self, let entryId = self.currentEntryId else { return }
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = ""
                alert.addButton(withTitle: "Create")
                alert.addButton(withTitle: "Cancel")
                let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
                field.placeholderString = "Collection name"
                alert.accessoryView = field
                alert.window.initialFirstResponder = field
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty,
                      let tag = DatabaseManager.shared.findOrCreateTag(name: name) else { return }
                DatabaseManager.shared.addTag(tag.id, toHighlight: entryId)
                NotificationCenter.default.post(name: .highlightDataDidChange,
                                                object: nil,
                                                userInfo: ["highlightId": entryId, "change": "tags"])
            }
        }
        target.onDismiss = { [weak self] in self?.dismiss(animated: true) }
        self.menuTarget = target

        p.contextMenuProvider = { [weak self, weak target, weak hv] in
            guard let self, let target, let hv, self.generation == showGeneration else { return nil }
            guard let entryId = self.currentEntryId,
                  let highlight = DatabaseManager.shared.highlight(byId: entryId) else {
                return nil
            }
            return buildMaterialNSMenu(for: highlight, target: target, anchorView: hv, includeDismiss: true)
        }

        // Observe state changes for resize + activation
        stateObserver = stateHolder.$state
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] newState in
                guard let self, self.generation == showGeneration else { return }
                self.handleStateChange(newState)
            }

        // Install tracking area for hover
        let handler = HoverHandler(
            stateHolder: stateHolder,
            onEnter: { [weak self] in
                guard let self, self.generation == showGeneration else { return }
                self.pauseDismissTimer()
            },
            onExit: { [weak self] in
                guard let self, self.generation == showGeneration else { return }
                self.resumeDismissTimer()
            }
        )
        self.hoverHandler = handler

        let area = NSTrackingArea(
            rect: hv.bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: handler,
            userInfo: nil
        )
        hv.addTrackingArea(area)

        // Resize panel when content size changes
        frameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: hv,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.generation == showGeneration else { return }
            self.updatePanelSize()
        }

        startDismissTimer()

        // Smart dismiss: detect clipboard changes
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self, self.generation == showGeneration, self.panel != nil else { return }
            let initialChangeCount = NSPasteboard.general.changeCount
            self.clipboardPollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                guard let self, self.generation == showGeneration, self.panel != nil else { return }
                guard !self.timerPermanentlyPaused else { return }
                if NSPasteboard.general.changeCount != initialChangeCount {
                    self.dismiss(animated: true)
                }
            }
        }
    }

    private func handleStateChange(_ state: ToastState) {
        switch state {
        case .collapsed:
            panel?.styleMask.insert(.nonactivatingPanel)
            updatePanelSize()
        case .compact:
            panel?.styleMask.insert(.nonactivatingPanel)
            updatePanelSize()
        case .hovered:
            break
        case .expanded:
            // Kill all timers FIRST so nothing can dismiss during transition
            timerPermanentlyPaused = true
            cancelDismissTimer()
            clipboardPollTimer?.invalidate()
            clipboardPollTimer = nil
            stateHolder?.timerProgress = 0
            panel?.styleMask.remove(.nonactivatingPanel)
            panel?.alphaValue = 1
            centerPanel()
            NSApp.activate(ignoringOtherApps: true)
            panel?.makeKeyAndOrderFront(nil)
        }
    }

    private func centerPanel() {
        guard let panel = panel, let hv = hostingView else { return }
        guard let screen = NSScreen.main?.visibleFrame else { return }
        let w = expandedWidth
        // Use a reasonable initial height — SwiftUI may not have laid out
        // the expanded content yet, so fittingSize can be stale.
        let fittingH = hv.fittingSize.height
        let h = min(max(fittingH > 0 ? fittingH : 400, 200), screen.height - 40)
        let x = screen.midX - w / 2
        let y = max(screen.minY, screen.midY - h / 2)
        isAnimatingToCenter = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(
                NSRect(x: x, y: y, width: w, height: h),
                display: true
            )
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.isAnimatingToCenter = false
            // Ensure panel is still visible and in front after animation
            self.panel?.alphaValue = 1
            self.panel?.orderFrontRegardless()
        })
    }

    private func updatePanelSize() {
        guard let panel = panel, let hv = hostingView else { return }
        guard !isAnimatingToCenter else { return }
        guard let screen = NSScreen.main?.visibleFrame else { return }
        if stateHolder?.state == .expanded {
            let size = hv.fittingSize
            let h = min(max(size.height, 200), screen.height - 40)
            let currentFrame = panel.frame
            // Keep centered horizontally, adjust height from center
            let x = screen.midX - expandedWidth / 2
            let newY = max(screen.minY, currentFrame.midY - h / 2)
            panel.setFrame(NSRect(x: x, y: newY,
                                  width: expandedWidth, height: h),
                           display: true, animate: false)
            return
        }
        let size = hv.fittingSize
        guard size.width > 0, size.height > 0 else { return }
        let x = screen.maxX - size.width - 16
        let bottomY = screen.minY + 16
        let maxH = screen.maxY - bottomY - 8
        let h = min(size.height, maxH)
        panel.setFrame(NSRect(x: x, y: bottomY, width: size.width, height: h), display: true, animate: false)
    }

    func teardown() {
        dismiss(animated: false)
        closeAnnotationWindow()
    }

    // MARK: - Dismiss

    func dismiss(animated: Bool = true) {
        // 0. Increment generation to invalidate any pending callbacks
        //    (hover handlers, clipboard poll, etc.) that may fire during
        //    or after teardown. Without this, onExit can restart the timer.
        generation += 1

        // 1. Stop all timers immediately
        cancelDismissTimer()
        clipboardPollTimer?.invalidate()
        clipboardPollTimer = nil

        // 2. Cancel Combine observation
        stateObserver?.cancel()
        stateObserver = nil

        // 3. CRITICAL: Stop speech transcriber BEFORE any teardown.
        //    This ensures audio engine is stopped and taps removed while
        //    the object is still fully alive — never relying on deinit.
        transcriber?.stopRecording()
        transcriber = nil

        // 4. Freeze the view — prevent further SwiftUI updates during teardown
        stateHolder?.timerProgress = 0

        // 5. Grab the panel — if nil, nothing to dismiss
        guard let p = panel else { return }

        // 6. Nil out panel immediately to prevent re-entrancy
        self.panel = nil

        // 7. Capture strong references to keep objects alive during animation
        let capturedHostingView = self.hostingView
        let capturedHandler = self.hoverHandler
        let capturedFrameObserver = self.frameObserver
        let capturedStateHolder = self.stateHolder
        let capturedMenuTarget = self.menuTarget

        // 8. Clear controller state
        self.hostingView = nil
        self.hoverHandler = nil
        self.frameObserver = nil
        self.stateHolder = nil
        self.menuTarget = nil
        self.currentEntryId = nil
        self.onAnnotationSubmit = nil
        self.currentImage = nil
        self.currentContent = nil
        self.currentFilePath = nil
        self.timerPermanentlyPaused = false
        self.isAnimatingToCenter = false

        // 9. Cleanup closure: runs after animation completes
        let cleanup = {
            // Remove tracking areas BEFORE handler can be deallocated
            if let hv = capturedHostingView, let handler = capturedHandler {
                for area in hv.trackingAreas where area.owner === handler {
                    hv.removeTrackingArea(area)
                }
            }

            // Remove frame change observer
            if let obs = capturedFrameObserver {
                NotificationCenter.default.removeObserver(obs)
            }

            // Clear context menu provider
            p.contextMenuProvider = nil

            // Order out the panel
            p.orderOut(nil)

            // Keep captured references alive until this point
            withExtendedLifetime((capturedHostingView, capturedHandler, capturedStateHolder, capturedMenuTarget)) {}
        }

        if animated {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.15
                p.animator().alphaValue = 0
            }, completionHandler: cleanup)
        } else {
            cleanup()
        }
    }

    private func positionPanel(_ panel: NSPanel, height: CGFloat = 44) {
        guard let screen = NSScreen.main?.visibleFrame else { return }
        let x = screen.maxX - 300 - 16
        let y = screen.minY + 16
        panel.setFrame(NSRect(x: x, y: y, width: 300, height: height), display: true)
    }

    // MARK: - Annotation Window

    private func openAnnotationWindow() {
        let entryId = currentEntryId
        let image = currentImage
        let content = currentContent ?? ""
        let filePath = currentFilePath
        let onAnnotation = onAnnotationSubmit

        dismiss(animated: false)

        annotationWindow?.close()
        annotationWindow = nil
        annotationDelegate = nil

        guard let entryId else { return }

        let transcriber = SpeechTranscriber()

        let annotationView = AnnotationWindowView(
            content: content,
            image: image,
            filePath: filePath,
            entryId: entryId,
            transcriber: transcriber,
            onSubmit: { [weak self] note in
                if !note.isEmpty { onAnnotation?(entryId, note) }
                self?.closeAnnotationWindow()
            },
            onDismiss: { [weak self] in
                self?.closeAnnotationWindow()
            }
        )

        let delegate = PanelWindowDelegate { [weak self] in
            self?.annotationWindow = nil
            self?.annotationDelegate = nil
        }
        self.annotationDelegate = delegate

        // Size window based on image aspect ratio
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1400, height: 900)
        let winSize: NSSize
        if let image {
            let aspect = image.size.width / max(image.size.height, 1)
            let maxW = min(screen.width * 0.55, 800.0)
            let maxH = screen.height * 0.7
            var w = maxW
            var h = w / aspect + 100 // 100 for bottom bar
            if h > maxH {
                h = maxH
                w = (h - 100) * aspect
            }
            winSize = NSSize(width: max(w, 400), height: max(h, 350))
        } else {
            winSize = NSSize(width: 480, height: 380)
        }

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: winSize.width, height: winSize.height),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isMovableByWindowBackground = true
        w.minSize = NSSize(width: 360, height: 300)
        w.delegate = delegate
        w.backgroundColor = NSColor(white: 0.12, alpha: 1)
        w.hasShadow = true
        let hc = NSHostingController(rootView: annotationView)
        hc.sizingOptions = []
        w.contentViewController = hc
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.annotationWindow = w
    }

    private func closeAnnotationWindow() {
        annotationWindow?.contentViewController = nil
        annotationWindow?.delegate = nil
        annotationWindow?.close()
        annotationWindow = nil
        annotationDelegate = nil
    }

    // MARK: - Timer

    private func startDismissTimer() {
        remainingTime = currentDismissDelay
        stateHolder?.timerProgress = 1.0
        resumeTickTimer()
    }

    private func resumeTickTimer() {
        tickTimer?.invalidate()
        let interval: TimeInterval = 1.0 / 30.0
        let gen = generation
        tickTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self, self.generation == gen else { return }
            self.remainingTime -= interval
            if self.remainingTime <= 0 {
                self.remainingTime = 0
                self.stateHolder?.timerProgress = 0
                self.dismiss(animated: true)
            } else {
                self.stateHolder?.timerProgress = CGFloat(self.remainingTime / self.currentDismissDelay)
            }
        }
    }

    private func pauseDismissTimer() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    private func resumeDismissTimer() {
        guard !timerPermanentlyPaused else { return }
        resumeTickTimer()
    }

    private func cancelDismissTimer() {
        tickTimer?.invalidate()
        tickTimer = nil
        remainingTime = 0
    }

    // MARK: - Context Menu Actions

    private func performCopyImage() {
        guard let image = currentImage else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([image])
    }

    private func performCopyText() {
        guard let content = currentContent else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(content, forType: .string)
    }

    private func performShowInFinder() {
        if let filePath = currentFilePath {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: filePath)])
        }
    }
}

// MARK: - KeyablePanel

private class KeyablePanel: NSPanel {
    var contextMenuProvider: (() -> NSMenu?)?

    override var canBecomeKey: Bool { true }
    override var becomesKeyOnlyIfNeeded: Bool {
        get { false }
        set {}
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = contextMenuProvider?(), let contentView else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: contentView)
    }
}

// MARK: - HoverHandler

private class HoverHandler: NSResponder {
    let stateHolder: ToastStateHolder
    let onEnter: () -> Void
    let onExit: () -> Void

    init(stateHolder: ToastStateHolder, onEnter: @escaping () -> Void, onExit: @escaping () -> Void) {
        self.stateHolder = stateHolder
        self.onEnter = onEnter
        self.onExit = onExit
        super.init()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseEntered(with event: NSEvent) {
        onEnter()
    }

    override func mouseExited(with event: NSEvent) {
        onExit()
    }
}

// MARK: - NativeNoteField

struct NativeNoteField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    var autoFocus: Bool = false
    let onSubmit: () -> Void
    let onFocusChange: (Bool) -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.placeholderString = placeholder
        field.isBordered = false
        field.drawsBackground = false
        field.font = .systemFont(ofSize: 12)
        field.focusRingType = .none
        field.lineBreakMode = .byWordWrapping
        field.usesSingleLineMode = false
        field.maximumNumberOfLines = 5
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.delegate = context.coordinator
        if autoFocus {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                field.window?.makeFirstResponder(field)
            }
        }
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, NSTextFieldDelegate {
        let parent: NativeNoteField
        init(_ parent: NativeNoteField) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            parent.onFocusChange(true)
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            parent.onFocusChange(false)
            if let event = NSApp.currentEvent, event.keyCode == 36 {
                parent.onSubmit()
            }
        }
    }
}

// MARK: - CopyToastView

struct CopyToastView: View {
    let content: String
    let image: NSImage?
    let filePath: String?
    let badgeLabel: String
    let sourceUrl: String?
    let sourceApp: String?
    let windowTitle: String?
    let entryId: String?
    @ObservedObject var stateHolder: ToastStateHolder
    @ObservedObject var transcriber: SpeechTranscriber
    let onSubmit: (String) -> Void
    let onDismiss: () -> Void
    let onNoteFocusChanged: (Bool) -> Void
    var onExpand: (() -> Void)?

    @State private var note = ""
    @State private var imageCopied = false
    @State private var toastTags: [Tag] = []

    private var isExpanded: Bool { stateHolder.state == .expanded }
    private var isCompact: Bool { stateHolder.state == .compact }
    private var isHovered: Bool { stateHolder.state == .hovered }
    private var hasImage: Bool { image != nil }

    @ViewBuilder
    private var sourceUrlLink: some View {
        if let sourceUrl, !sourceUrl.isEmpty, let url = URL(string: sourceUrl) {
            Button(action: { NSWorkspace.shared.open(url) }) {
                HStack(spacing: 4) {
                    Image(systemName: "link")
                        .font(.caption2)
                    Text(CardMetadata.shortURL(from: sourceUrl) ?? sourceUrl)
                        .font(.caption2)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
        }
    }

    private var timerBar: some View {
        GeometryReader { geo in
            Rectangle()
                .fill(Color.primary.opacity(0.15))
                .frame(width: geo.size.width * stateHolder.timerProgress)
        }
        .frame(height: 2)
        .animation(.linear(duration: 1.0 / 30.0), value: stateHolder.timerProgress)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            timerBar

            if isExpanded {
                expandedContent
            } else if isCompact {
                compactContent
            } else {
                collapsedContent
            }
        }
        .frame(width: isExpanded ? 480 : 300)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(.separator, lineWidth: 0.5)
        )
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: stateHolder.state)
        .onChange(of: transcriber.transcribedText) { _, newText in
            note = newText
        }
        .onChange(of: transcriber.isRecording) { _, recording in
            onNoteFocusChanged(recording)
        }
        .onExitCommand {
            transcriber.stopRecording()
            onDismiss()
        }
    }

    // MARK: - Collapsed / Hovered

    @ViewBuilder
    private var collapsedContent: some View {
        if let image = image {
            ZStack(alignment: .bottomLeading) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 300, height: 120)
                    .clipped()

                Text(badgeLabel)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .padding(8)
            }
            .frame(width: 300, height: 120)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                onExpand?() ?? { stateHolder.state = .expanded }()
            }
        } else {
            Text(content)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 44)
                .contentShape(Rectangle())
                .onTapGesture {
                    onExpand?() ?? { stateHolder.state = .expanded }()
                }
        }
    }

    // MARK: - Compact (text captures: minimal preview)

    private var compactContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(content)
                .font(.system(size: 12))
                .lineLimit(2)
                .truncationMode(.tail)
                .foregroundStyle(.primary)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture {
                    onExpand?() ?? { stateHolder.state = .expanded }()
                }

            sourceUrlLink
                .padding(.horizontal, 12)

            toastMetadataFooter
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var toastMetadataFooter: some View {
        let parts = [sourceApp, windowTitle?.prefix(40).description].compactMap { $0 }
        if !parts.isEmpty {
            Text(parts.joined(separator: " · "))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    // MARK: - Expanded

    private func copyImageToClipboard() {
        guard let image else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
        imageCopied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            imageCopied = false
        }
    }

    private func openInFinder() {
        if let filePath {
            let url = URL(fileURLWithPath: filePath)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(DatabaseManager.appSupportURL)
        }
    }

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let image = image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)

                HStack(spacing: 16) {
                    Button(action: copyImageToClipboard) {
                        Label(imageCopied ? "Copied" : "Copy", systemImage: imageCopied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(imageCopied ? .green : .secondary)

                    Button(action: openInFinder) {
                        Label("Show in Finder", systemImage: "folder")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)

                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .animation(.easeInOut(duration: 0.15), value: imageCopied)
            } else {
                ScrollView {
                    Text(content)
                        .font(.system(size: 12))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(minHeight: 30, maxHeight: 200)
                .padding(.horizontal, 12)
                .padding(.top, 12)
            }

            sourceUrlLink
                .padding(.horizontal, 12)
                .padding(.top, 6)

            // Quick-tag chips
            if let eid = entryId {
                tagChips(for: eid)
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
            }

            HStack(spacing: 6) {
                ZStack {
                    NativeNoteField(
                        text: $note,
                        placeholder: "Add a note...",
                        onSubmit: {
                            transcriber.stopRecording()
                            onSubmit(note)
                        },
                        onFocusChange: { focused in
                            onNoteFocusChanged(focused || transcriber.isRecording)
                        }
                    )
                    .opacity(transcriber.isRecording ? 0 : 1)

                    if transcriber.isRecording {
                        WaveformView(audioLevels: transcriber.audioLevels)
                            .transition(.opacity)
                    }
                }

                if transcriber.permissionStatus != .unavailable {
                    Button(action: {
                        if transcriber.permissionStatus == .unknown {
                            transcriber.requestPermissions()
                        } else if !transcriber.isProcessing {
                            transcriber.toggleRecording()
                        }
                    }) {
                        Group {
                            if transcriber.isProcessing {
                                ProgressView()
                                    .controlSize(.small)
                            } else if transcriber.isRecording {
                                Image(systemName: "stop.fill")
                                    .foregroundStyle(.red)
                                    .font(.system(size: 10))
                            } else {
                                Image(systemName: "mic")
                                    .foregroundStyle(.secondary)
                                    .font(.system(size: 12))
                            }
                        }
                        .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.plain)
                    .disabled(transcriber.permissionStatus == .denied || transcriber.isProcessing)
                    .help(transcriber.permissionStatus == .denied
                          ? "Enable in System Settings > Privacy"
                          : (transcriber.isRecording ? "Stop dictation" : "Start dictation"))
                }
            }
            .padding(12)
            .animation(.easeInOut(duration: 0.2), value: transcriber.isRecording)
            .animation(.easeInOut(duration: 0.2), value: transcriber.isProcessing)
            .background {
                Button("") {
                    if transcriber.permissionStatus != .unavailable && transcriber.permissionStatus != .denied && !transcriber.isProcessing {
                        transcriber.toggleRecording()
                    }
                }
                .keyboardShortcut("d", modifiers: .command)
                .hidden()
            }

            HStack {
                Spacer()
                Button("Dismiss") {
                    onDismiss()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(.system(size: 11))
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Tag Chips

    private func tagChips(for highlightId: String) -> some View {
        TagInputView(
            highlightId: highlightId,
            tags: $toastTags,
            compact: true
        )
        .onAppear {
            toastTags = DatabaseManager.shared.tagsForHighlight(id: highlightId)
        }
    }
}

// MARK: - Waveform View

private struct WaveformView: View {
    let audioLevels: [Float]
    private let maxSamples = 50
    private let lineWidth: CGFloat = 1

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let midY = h / 2

            ZStack {
                mirroredFill(width: w, midY: midY)
                    .fill(Color.red.opacity(0.2))

                curvePath(width: w, midY: midY, mirror: false)
                    .stroke(Color.red.opacity(0.5), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))

                curvePath(width: w, midY: midY, mirror: true)
                    .stroke(Color.red.opacity(0.5), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            }
        }
        .animation(.linear(duration: 0.08), value: audioLevels.count)
        .frame(maxWidth: .infinity)
        .frame(height: 24)
    }

    private func curvePath(width: CGFloat, midY: CGFloat, mirror: Bool) -> Path {
        Path { path in
            guard !audioLevels.isEmpty else { return }
            let step = width / CGFloat(maxSamples - 1)
            let startX = width - CGFloat(audioLevels.count - 1) * step
            let sign: CGFloat = mirror ? 1 : -1

            for (i, level) in audioLevels.enumerated() {
                let x = startX + CGFloat(i) * step
                let amplitude = CGFloat(level) * midY * 0.85
                let y = midY + sign * amplitude
                if i == 0 {
                    path.move(to: CGPoint(x: x, y: y))
                } else {
                    let prevX = startX + CGFloat(i - 1) * step
                    let cpX = (prevX + x) / 2
                    path.addQuadCurve(
                        to: CGPoint(x: x, y: y),
                        control: CGPoint(x: cpX, y: path.currentPoint?.y ?? y)
                    )
                }
            }
        }
    }

    private func mirroredFill(width: CGFloat, midY: CGFloat) -> Path {
        Path { path in
            guard !audioLevels.isEmpty else { return }
            let step = width / CGFloat(maxSamples - 1)
            let startX = width - CGFloat(audioLevels.count - 1) * step

            for (i, level) in audioLevels.enumerated() {
                let x = startX + CGFloat(i) * step
                let amplitude = CGFloat(level) * midY * 0.85
                let y = midY - amplitude
                if i == 0 {
                    path.move(to: CGPoint(x: x, y: y))
                } else {
                    let prevX = startX + CGFloat(i - 1) * step
                    let cpX = (prevX + x) / 2
                    path.addQuadCurve(
                        to: CGPoint(x: x, y: y),
                        control: CGPoint(x: cpX, y: path.currentPoint?.y ?? y)
                    )
                }
            }

            for (i, level) in audioLevels.enumerated().reversed() {
                let x = startX + CGFloat(i) * step
                let amplitude = CGFloat(level) * midY * 0.85
                let y = midY + amplitude
                let nextI = i + 1
                if nextI < audioLevels.count {
                    let nextX = startX + CGFloat(nextI) * step
                    let cpX = (nextX + x) / 2
                    path.addQuadCurve(
                        to: CGPoint(x: x, y: y),
                        control: CGPoint(x: cpX, y: path.currentPoint?.y ?? y)
                    )
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }
            path.closeSubpath()
        }
    }
}

// MARK: - Annotation Window View

struct AnnotationWindowView: View {
    let content: String
    let image: NSImage?
    let filePath: String?
    let entryId: String
    @ObservedObject var transcriber: SpeechTranscriber
    let onSubmit: (String) -> Void
    let onDismiss: () -> Void

    @State private var note = ""
    @State private var imageCopied = false
    @State private var tags: [Tag] = []

    var body: some View {
        VStack(spacing: 0) {
            // Content area — image or text fills the window
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
            } else {
                ScrollView {
                    Text(content)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // Bottom action bar
            VStack(spacing: 8) {
                // Note field with mic
                HStack(spacing: 6) {
                    ZStack {
                        NativeNoteField(
                            text: $note,
                            placeholder: "Add a note...",
                            autoFocus: true,
                            onSubmit: { onSubmit(note) },
                            onFocusChange: { _ in }
                        )
                        .opacity(transcriber.isRecording ? 0 : 1)

                        if transcriber.isRecording {
                            WaveformView(audioLevels: transcriber.audioLevels)
                                .transition(.opacity)
                        }
                    }

                    if transcriber.permissionStatus != .unavailable {
                        Button(action: {
                            if transcriber.permissionStatus == .unknown {
                                transcriber.requestPermissions()
                            } else if !transcriber.isProcessing {
                                transcriber.toggleRecording()
                            }
                        }) {
                            Group {
                                if transcriber.isProcessing {
                                    ProgressView().controlSize(.small)
                                } else if transcriber.isRecording {
                                    Image(systemName: "stop.fill")
                                        .foregroundStyle(.red)
                                        .font(.system(size: 10))
                                } else {
                                    Image(systemName: "mic")
                                        .foregroundStyle(.secondary)
                                        .font(.system(size: 12))
                                }
                            }
                            .frame(width: 18, height: 18)
                        }
                        .buttonStyle(.plain)
                        .disabled(transcriber.permissionStatus == .denied || transcriber.isProcessing)
                    }
                }

                // Tags + actions row
                HStack(spacing: 10) {
                    // Action buttons
                    if image != nil {
                        Button(action: copyImage) {
                            Image(systemName: imageCopied ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 12))
                                .foregroundStyle(imageCopied ? .green : .secondary)
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(.plain)
                        .help(imageCopied ? "Copied" : "Copy image")
                    }

                    if filePath != nil {
                        Button(action: openInFinder) {
                            Image(systemName: "folder")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(.plain)
                        .help("Show in Finder")
                    }

                    // Tags
                    TagInputView(
                        highlightId: entryId,
                        tags: $tags,
                        compact: true
                    )

                    Spacer()

                    // Done button
                    Button(action: {
                        transcriber.stopRecording()
                        onSubmit(note)
                    }) {
                        Text("Done")
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 5)
                            .background(Color.accentColor)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.bar)
        }
        .animation(.easeInOut(duration: 0.15), value: imageCopied)
        .animation(.easeInOut(duration: 0.2), value: transcriber.isRecording)
        .onAppear {
            tags = DatabaseManager.shared.tagsForHighlight(id: entryId)
        }
        .onChange(of: transcriber.transcribedText) { _, newText in
            note = newText
        }
        .onExitCommand { onDismiss() }
    }

    private func copyImage() {
        guard let image else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([image])
        imageCopied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            imageCopied = false
        }
    }

    private func openInFinder() {
        if let filePath {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: filePath)])
        }
    }
}

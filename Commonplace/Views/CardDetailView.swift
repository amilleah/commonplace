import SwiftUI
import AVKit
import PDFKit
import Quartz

// MARK: - Card Detail View

struct CardDetailView: View {
    let highlight: Highlight
    var onDismiss: (() -> Void)?
    var onTagNavigation: ((Highlight, Tag) -> Void)?
    @State private var image: NSImage?
    @State private var notes: [HighlightNote] = []
    @State private var newNoteText = ""
    @State private var tags: [Tag] = []
    @State private var confirmationText: String?
    @State private var showCollectionPicker = false
    @State private var collectionInput = ""
    @State private var allCollections: [Tag] = DatabaseManager.shared.allTags()
    @State private var pickerSelection: Int = 0

    private var isScreenshot: Bool { highlight.highlightType == "screenshot" }
    private var isRecording: Bool { highlight.highlightType == "recording" }
    private var isFile: Bool { highlight.highlightType == "file" }

    private func showConfirmation(_ text: String) {
        withAnimation(.easeInOut(duration: 0.15)) { confirmationText = text }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation(.easeInOut(duration: 0.3)) { confirmationText = nil }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar

            Divider().opacity(0.5)

            ScrollView {
                VStack(alignment: .leading, spacing: UITokens.sectionSpacing) {
                    // Content preview
                    if isScreenshot {
                        if let image {
                            Image(nsImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: .infinity)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    } else if isRecording {
                        recordingDetailContent
                    } else if isFile {
                        fileDetailContent
                    } else if highlight.isURLCopy {
                        if highlight.fileId != nil {
                            downloadedFileLinkContent
                        } else {
                            linkDetailContent
                        }
                    } else {
                        // Copied text — styled as a clipping
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 5) {
                                Image(systemName: "doc.on.clipboard")
                                    .font(.system(size: 10))
                                Text("Copied text")
                                    .font(.system(size: 11, weight: .medium))
                                if let app = highlight.sourceApp {
                                    Text("from \(app)")
                                        .font(.system(size: 11))
                                }
                            }
                            .foregroundStyle(.tertiary)

                            HStack(alignment: .top, spacing: 12) {
                                RoundedRectangle(cornerRadius: 1)
                                    .fill(Color.primary.opacity(0.12))
                                    .frame(width: 2.5)

                                Text(highlight.contentText)
                                    .font(.system(.body))
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }

                    notesTimeline

                    // OCR text — collapsed metadata, full-width
                    if isScreenshot, let screenshotId = highlight.screenshotId,
                       let screenshot = DatabaseManager.shared.screenshot(byId: screenshotId),
                       let ocrText = screenshot.ocrText, !ocrText.isEmpty {
                        OCRTextBlock(text: ocrText)
                    }

                    // Auxiliary preview for URLs embedded inside text copies.
                    if !highlight.isURLCopy,
                       !isFile, !isScreenshot, !isRecording,
                       let embeddedURL = Self.firstEmbeddedURL(in: highlight.contentText) {
                        embeddedLinkPreviewSection(url: embeddedURL.absoluteString)
                    }
                }
                .padding(20)
            }

            Divider().opacity(0.5)

            noteInput
        }
        .frame(minWidth: 520, idealWidth: 740, maxWidth: .infinity, minHeight: 420, idealHeight: 720, maxHeight: .infinity)
        .task {
            if isScreenshot && image == nil {
                let path = highlight.contentText
                image = await Task.detached {
                    NSImage(contentsOfFile: path)
                }.value
            }
            loadNotes()
            tags = DatabaseManager.shared.tagsForHighlight(id: highlight.id)
            allCollections = DatabaseManager.shared.allTags()
        }
    }

    // MARK: - Header Bar (always visible)

    private var headerTitleText: String {
        if let wt = highlight.windowTitle, !wt.isEmpty { return wt }
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMMM d"
        return f.string(from: highlight.date)
    }

    private var headerBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Title row — title on the left, bare-icon actions on the right
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(headerTitleText)
                    .font(.system(.title3, design: .serif).weight(.semibold))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .layoutPriority(1)

                Spacer(minLength: 12)

                HStack(spacing: 16) {
                    InstantTooltipButton(icon: "doc.on.doc", label: "Copy content") {
                        copyContent(); showConfirmation("Copied")
                    }
                    if isScreenshot || isFile {
                        InstantTooltipButton(icon: "folder", label: "Reveal in Finder") {
                            showInFinder(); showConfirmation("Revealed in Finder")
                        }
                    }
                    if isFile {
                        InstantTooltipButton(icon: "arrow.up.forward.app", label: "Open file") {
                            openFile(highlight.contentText); showConfirmation("Opened")
                        }
                    }
                    InstantTooltipButton(icon: "trash", label: "Delete") {
                        MaterialAction.delete(highlight)
                        onDismiss?()
                    }
                    InstantTooltipButton(icon: "xmark", label: "Close") {
                        onDismiss?()
                    }
                }
            }

            // Meta row — flat line: date · time · app · host  |  #tags  + add       Copied
            headerMetaLine
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    @ViewBuilder
    private var headerMetaLine: some View {
        let hasTitle = highlight.windowTitle?.isEmpty == false
        let host = CardMetadata.domain(from: highlight.sourceUrl)

        HStack(spacing: 0) {
            // Provenance group
            Group {
                if hasTitle {
                    Text(highlight.date, style: .date)
                    dot
                }
                Text(highlight.date, style: .time)
                if let app = highlight.sourceApp {
                    dot
                    Text(app)
                }
                if let host, let url = highlight.sourceUrl {
                    dot
                    InlineLink(text: host, url: url) {
                        openURL(url); showConfirmation("Opened \(host)")
                    }
                    .contextMenu {
                        Button("Copy URL") {
                            let pb = NSPasteboard.general
                            pb.clearContents()
                            pb.setString(url, forType: .string)
                            showConfirmation("Copied URL")
                        }
                    }
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)

            // Spacer between provenance and organisation groups
            if !tags.isEmpty {
                Spacer().frame(width: 18)
            } else {
                Spacer().frame(width: 12)
            }

            // Organisation group — flat tags + add
            HStack(spacing: 10) {
                ForEach(tags) { tag in
                    FlatTag(
                        name: tag.name,
                        onRemove: { removeCollection(tag) },
                        onTap: onTagNavigation.map { handler in
                            { handler(highlight, tag) }
                        }
                    )
                }

                Button(action: {
                    showCollectionPicker.toggle()
                    if showCollectionPicker {
                        allCollections = DatabaseManager.shared.allTags()
                        collectionInput = ""
                        pickerSelection = 0
                    }
                }) {
                    Text(tags.isEmpty ? "+ add collection" : "+")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help(tags.isEmpty ? "Add to a collection" : "Add to another collection")
                .popover(isPresented: $showCollectionPicker, arrowEdge: .bottom) {
                    collectionPickerContent
                }
            }

            Spacer(minLength: 8)

            // Inline confirmation — no pill, no background
            if let text = confirmationText {
                Text(text)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .lineLimit(1)
    }

    private var dot: some View {
        Text(" · ")
            .font(.system(size: 12))
            .foregroundStyle(.quaternary)
    }

    private var collectionPickerContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Search input
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                TextField("Search or create...", text: $collectionInput)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .onSubmit { submitPickerSelection() }
                    .onKeyPress(.downArrow) {
                        pickerSelection = min(pickerSelection + 1, filteredCollections.count - 1)
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        pickerSelection = max(pickerSelection - 1, 0)
                        return .handled
                    }
                if !collectionInput.isEmpty {
                    Button(action: { collectionInput = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .onChange(of: collectionInput) { _, _ in pickerSelection = 0 }

            Divider()

            // Existing collections list
            if !filteredCollections.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(filteredCollections.enumerated()), id: \.element.id) { index, tag in
                                collectionRow(tag, isHighlighted: index == pickerSelection)
                                    .id(tag.id)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(maxHeight: 300)
                    .onChange(of: pickerSelection) { _, newValue in
                        if newValue < filteredCollections.count {
                            proxy.scrollTo(filteredCollections[newValue].id, anchor: .center)
                        }
                    }
                }
            } else if collectionInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("No collections yet")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            } else {
                Text("No matches")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }

            // "Create new" at the bottom
            if !collectionInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let trimmed = collectionInput.trimmingCharacters(in: .whitespacesAndNewlines)
                let exactMatch = filteredCollections.contains { $0.name.lowercased() == trimmed.lowercased() }
                if !exactMatch {
                    Divider()
                    Button(action: { createOrApplyCollection() }) {
                        HStack(spacing: 6) {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(.blue)
                            Text("Create \"\(trimmed)\"")
                                .font(.system(size: 13))
                                .foregroundStyle(.primary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(width: 240)
        .onAppear {
            allCollections = DatabaseManager.shared.allTags()
            pickerSelection = 0
        }
    }

    /// Enter applies the highlighted collection, or creates a new one if no match.
    private func submitPickerSelection() {
        if !filteredCollections.isEmpty && pickerSelection < filteredCollections.count {
            let tag = filteredCollections[pickerSelection]
            let isApplied = tags.contains { $0.id == tag.id }
            if isApplied { removeCollection(tag) } else { applyCollection(tag) }
        } else {
            createOrApplyCollection()
        }
    }

    private func collectionRow(_ tag: Tag, isHighlighted: Bool = false) -> some View {
        let isApplied = tags.contains { $0.id == tag.id }
        return Button(action: {
            if isApplied { removeCollection(tag) } else { applyCollection(tag) }
        }) {
            HStack(spacing: 8) {
                // Emoji or folder icon — matches the sidebar style
                if let emoji = tag.emoji, !emoji.isEmpty {
                    Text(emoji)
                        .font(.system(size: 13))
                        .frame(width: 16)
                } else {
                    Image(systemName: "folder.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                }
                Text(tag.name)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer()
                if isApplied {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.blue)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                isHighlighted ? Color.accentColor.opacity(0.12) :
                isApplied ? Color.blue.opacity(0.04) : Color.clear
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var filteredCollections: [Tag] {
        let trimmed = collectionInput.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.isEmpty { return allCollections }
        return allCollections.filter { $0.name.lowercased().contains(trimmed) }
    }

    private func createOrApplyCollection() {
        let name = collectionInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if let tag = DatabaseManager.shared.findOrCreateTag(name: name) {
            applyCollection(tag)
        }
        collectionInput = ""
    }

    private func applyCollection(_ tag: Tag) {
        guard !tags.contains(where: { $0.id == tag.id }) else { return }
        DatabaseManager.shared.addTag(tag.id, toHighlight: highlight.id)
        tags.append(tag)
        allCollections = DatabaseManager.shared.allTags()
    }

    private func removeCollection(_ tag: Tag) {
        DatabaseManager.shared.removeTag(tag.id, fromHighlight: highlight.id)
        tags.removeAll { $0.id == tag.id }
    }

    // MARK: - Collections (moved to header bar — see collectionChips)

    // MARK: - Notes

    @ViewBuilder
    private var notesTimeline: some View {
        if !notes.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "Notes")

                VStack(alignment: .leading, spacing: 10) {
                    ForEach(notes) { note in
                        NoteRow(note: note) { deleteNote(note) }
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var noteInput: some View {
        HStack(alignment: .center, spacing: 10) {
            TextField("Add a note...", text: $newNoteText, axis: .vertical)
                .font(.system(size: 13))
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .padding(.vertical, 6)
                .onKeyPress(.return) {
                    // Shift+Return inserts a newline (default TextField behavior).
                    // Plain Return submits.
                    if NSEvent.modifierFlags.contains(.shift) { return .ignored }
                    if noteIsEmpty { return .ignored }
                    submitNote()
                    return .handled
                }

            Button(action: submitNote) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(noteIsEmpty ? Color.gray.opacity(0.3) : Color.accentColor)
            }
            .buttonStyle(.plain)
            .disabled(noteIsEmpty)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var noteIsEmpty: Bool {
        newNoteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Actions

    private func loadNotes() {
        notes = DatabaseManager.shared.notesForHighlight(id: highlight.id)
    }

    private func submitNote() {
        let body = newNoteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        DatabaseManager.shared.addNoteToHighlight(highlightId: highlight.id, body: body)
        newNoteText = ""
        loadNotes()
        NotificationCenter.default.post(name: .highlightDidSave, object: nil)
    }

    private func deleteNote(_ note: HighlightNote) {
        DatabaseManager.shared.deleteNote(id: note.id, highlightId: highlight.id)
        loadNotes()
    }

    private func copyContent() {
        let pb = NSPasteboard.general
        pb.clearContents()
        if isScreenshot {
            if let image { pb.writeObjects([image]) }
        } else {
            pb.setString(highlight.contentText, forType: .string)
        }
    }

    private func showInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: highlight.contentText)])
    }

    private func openURL(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Recording Detail

    @ViewBuilder
    private var recordingDetailContent: some View {
        let filePath = highlight.contentText
        let fileURL = URL(fileURLWithPath: filePath)
        let exists = FileManager.default.fileExists(atPath: filePath)

        VStack(alignment: .leading, spacing: 12) {
            if exists {
                InlineVideoPlayer(url: fileURL)
                    .aspectRatio(16/9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                HStack(spacing: 16) {
                    Button(action: {
                        NSWorkspace.shared.open(fileURL)
                    }) {
                        Label("Open in QuickTime", systemImage: "play.rectangle")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)

                    Button(action: {
                        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                    }) {
                        Label("Show in Finder", systemImage: "folder")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)

                    Spacer()
                }
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Recording file not found")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            // Recording metadata
            if let recordingId = highlight.recordingId,
               let rec = DatabaseManager.shared.recording(byId: recordingId) {
                HStack(spacing: 16) {
                    Label(rec.formattedDuration, systemImage: "clock")
                    Label(rec.formattedFileSize, systemImage: "internaldrive")
                    if rec.hasAudio {
                        Label("Audio", systemImage: "waveform")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Link detail (full-size preview for URL copies)

    private var linkDetailContent: some View {
        DetailLinkPreview(urlString: highlight.contentText.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - Downloaded file link (URL-copy whose target file was auto-downloaded)

    @ViewBuilder
    private var downloadedFileLinkContent: some View {
        if let fileId = highlight.fileId,
           let fileRec = DatabaseManager.shared.fileRecord(byId: fileId) {
            VStack(alignment: .leading, spacing: 12) {
                filePreview(fileRec)

                HStack(spacing: 12) {
                    fileInfoRow("File", fileRec.fileName, "doc")
                    fileInfoRow("Size", fileRec.formattedFileSize, "externaldrive")
                    if let ct = fileRec.contentType {
                        fileInfoRow("Type", ct, "tag")
                    }
                }

                // Source-link row — keeps the "this was a copied link" affordance.
                HStack(spacing: 6) {
                    Image(systemName: "link")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    InlineLink(
                        text: highlight.contentText,
                        url: highlight.contentText
                    ) {
                        openURL(highlight.contentText)
                        showConfirmation("Opened")
                    }
                    .font(.caption)
                }
            }
        } else {
            // Download still in flight or failed — fall back to link preview.
            linkDetailContent
        }
    }

    // MARK: - Embedded link preview (URLs inside non-URL text)

    private static let urlDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    static func firstEmbeddedURL(in text: String) -> URL? {
        guard let detector = urlDetector else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = detector.firstMatch(in: text, options: [], range: range),
              let url = match.url,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }
        return url
    }

    @ViewBuilder
    private func embeddedLinkPreviewSection(url: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "Link in this note")
            EmbeddedLinkPreview(urlString: url)
        }
    }

    @ViewBuilder
    private var fileDetailContent: some View {
        let fileRec: FileRecord? = {
            if let fileId = highlight.fileId,
               let r = DatabaseManager.shared.fileRecord(byId: fileId) {
                return r
            }
            return DatabaseManager.shared.fileRecordByPath(highlight.contentText)
        }()
        if let fileRec {
            VStack(alignment: .leading, spacing: 12) {
                // Inline preview based on content type
                filePreview(fileRec)

                // File info
                HStack(spacing: 12) {
                    fileInfoRow("File", fileRec.fileName, "doc")
                    fileInfoRow("Size", fileRec.formattedFileSize, "externaldrive")
                    if let ct = fileRec.contentType {
                        fileInfoRow("Type", ct, "tag")
                    }
                }

                // File existence check
                if !FileManager.default.fileExists(atPath: fileRec.filePath) {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("File has been moved or deleted")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(8)
                    .background(.orange.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }

    @ViewBuilder
    private func filePreview(_ fileRec: FileRecord) -> some View {
        let ct = fileRec.contentType ?? ""
        let url = URL(fileURLWithPath: fileRec.filePath)

        let ext = url.pathExtension.lowercased()

        if ct == "pdf" {
            // Interactive PDF viewer — NSViewRepresentable has no intrinsic
            // size, so give it an explicit frame or it collapses to 0 height.
            PDFPreviewView(url: url)
                .frame(maxWidth: .infinity, minHeight: 400, idealHeight: 500, maxHeight: 600)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 0.5)
                )
        } else if ct == "ebook" || ext == "epub" {
            // Full EPUB reader via Quick Look — paginated, scrollable, selectable.
            QuickLookPreviewView(url: url)
                .frame(maxWidth: .infinity, minHeight: 400, idealHeight: 520, maxHeight: 640)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 0.5)
                )
        } else if ct == "image", let img = NSImage(contentsOfFile: fileRec.filePath) {
            // Full image
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .frame(maxHeight: 400)
        } else if ct == "video" {
            // Owns its AVPlayer in @State so typing in the note field (which
            // re-runs CardDetailView.body) doesn't rebuild the player and blink.
            StableVideoPlayer(url: url)
                .frame(height: 300)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else if let thumbPath = fileRec.thumbnailPath,
                  let thumbImage = NSImage(contentsOfFile: thumbPath) {
            // QL thumbnail for documents etc.
            Image(nsImage: thumbImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .frame(maxHeight: 300)
        } else {
            // System file icon
            HStack {
                Spacer()
                Image(nsImage: NSWorkspace.shared.icon(forFile: fileRec.filePath))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 64)
                Spacer()
            }
            .padding(.vertical, 8)
        }
    }

    private func fileInfoRow(_ label: String, _ value: String, _ icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(width: 14)
            Text(label)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(width: 60, alignment: .leading)
            Text(value)
                .font(.caption)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        }
    }

}

// MARK: - Stable Video Player

struct StableVideoPlayer: View {
    let url: URL
    @State private var player: AVPlayer

    init(url: URL) {
        self.url = url
        self._player = State(initialValue: AVPlayer(url: url))
    }

    var body: some View {
        VideoPlayer(player: player)
            .onChange(of: url) { _, newURL in
                player.replaceCurrentItem(with: AVPlayerItem(url: newURL))
            }
    }
}

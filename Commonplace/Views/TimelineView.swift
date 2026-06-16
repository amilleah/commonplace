import SwiftUI
import AVKit
import PDFKit
import Combine

// MARK: - SelectionManager

final class SelectionManager: ObservableObject {
    @Published var selectedIds: Set<String> = []

    func toggle(_ id: String) {
        if selectedIds.contains(id) { selectedIds.remove(id) } else { selectedIds.insert(id) }
    }
    func clear() { selectedIds.removeAll() }
    func set(_ ids: Set<String>) { selectedIds = ids }
    var isEmpty: Bool { selectedIds.isEmpty }
    var count: Int { selectedIds.count }
}

// MARK: - CardFrameKey

private struct CardFrameKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

// MARK: - TimelineView

struct TimelineView: View {
    @ObservedObject var sidebarState: SidebarState
    @Binding var appFacets: [AppFacet]
    @Binding var allTags: [Tag]
    @Binding var tagCounts: [String: Int]
    @Binding var typeCounts: [String: Int]

    @State private var isActive = false
    @State private var searchText = ""
    @State private var highlights: [Highlight] = []
    @State private var highlightsOffset = 0
    @State private var hasMore = false
    private let pageSize = 100

    @State private var selectedHighlight: Highlight?

    // Multi-selection
    @StateObject private var selection = SelectionManager()
    @State private var cardFrames: [String: CGRect] = [:]
    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?
    @State private var dragCmdHeld = false

    private var sessions: [TimelineSession] { groupIntoSessions(highlights) }

    var body: some View {
        Group {
            if sidebarState.showSettings {
                ScrollView {
                    SettingsView()
                        .frame(maxWidth: 500)
                        .padding(24)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    scrollContent
                        .onPreferenceChange(CardFrameKey.self) { cardFrames = $0 }
                        .simultaneousGesture(
                            DragGesture(minimumDistance: 5, coordinateSpace: .global)
                                .onChanged { val in
                                    if dragStart == nil {
                                        let onCard = cardFrames.values.contains { $0.contains(val.startLocation) }
                                        guard !onCard else { return }
                                        dragCmdHeld = NSApp.currentEvent?.modifierFlags.contains(.command) ?? false
                                        if !dragCmdHeld { selection.clear() }
                                        dragStart = val.startLocation
                                    }
                                    dragCurrent = val.location
                                    updateLassoSelection()
                                }
                                .onEnded { _ in
                                    dragStart = nil
                                    dragCurrent = nil
                                }
                        )

                    if !selection.isEmpty {
                        selectionBar
                    }

                    Divider()
                    CaptureSearchBar(searchText: $searchText, count: highlights.count)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Cmd+Delete keyboard shortcut
                .background {
                    Button(action: deleteSelection) {}
                        .keyboardShortcut(.delete, modifiers: .command)
                        .frame(width: 0, height: 0)
                        .opacity(0)
                }
                .overlay { detailOverlay }
                .onExitCommand { selection.clear() }
                .environmentObject(selection)
            }
        }
        .onChange(of: sidebarState.selectedFilter) { _, _ in guard isActive else { return }; loadHighlights(reset: true) }
        .onChange(of: sidebarState.selectedApp)    { _, _ in guard isActive else { return }; loadHighlights(reset: true) }
        .onChange(of: sidebarState.selectedTagIds) { _, _ in guard isActive else { return }; loadHighlights(reset: true) }
        .onChange(of: searchText)                  { _, _ in guard isActive else { return }; loadHighlights(reset: true) }
        .onAppear {
            isActive = true
            loadHighlights(reset: true)
            refreshSidebarData()
        }
        .onDisappear { isActive = false }
        .onReceive(NotificationCenter.default.publisher(for: BrowseWindowController.windowDidShowNotification)) { _ in
            isActive = true
            loadHighlights(reset: true)
            refreshSidebarData()
        }
        .onReceive(NotificationCenter.default.publisher(for: .highlightDidSave)
            .throttle(for: .seconds(1), scheduler: DispatchQueue.main, latest: true)) { _ in
            guard isActive else { return }
            loadHighlights(reset: true)
            refreshSidebarData()
        }
        .onReceive(NotificationCenter.default.publisher(for: .highlightDataDidChange)
            .receive(on: DispatchQueue.main)) { _ in
            guard isActive else { return }
            refreshSidebarData()
        }
        .onReceive(NotificationCenter.default.publisher(for: .highlightDidDelete)) { notification in
            guard let hid = notification.userInfo?["highlightId"] as? String else { return }
            highlights.removeAll { $0.id == hid }
            if selectedHighlight?.id == hid { selectedHighlight = nil }
            selection.selectedIds.remove(hid)
            refreshSidebarData()
        }
        .onReceive(NotificationCenter.default.publisher(for: BrowseWindowController.showSettingsNotification)) { _ in
            sidebarState.showSettings = true
        }
        .onReceive(NotificationCenter.default.publisher(for: BrowseWindowController.showTagFilterNotification)) { notification in
            guard let tagId = notification.userInfo?["tagId"] as? String else { return }
            sidebarState.selectedFilter = .all
            sidebarState.selectedApp = nil
            searchText = ""
            isActive = true
            sidebarState.selectedTagIds = [tagId]
        }
    }

    // MARK: - Subviews

    private var scrollContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if sessions.isEmpty {
                    TimelineNoteComposer(tagIds: Array(sidebarState.selectedTagIds))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    emptyState
                } else {
                    ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                        SessionRow(
                            session: session,
                            labelText: sessionLabel(for: session.date),
                            noteTagIds: Array(sidebarState.selectedTagIds),
                            showsComposer: index == 0,
                            showsTopConnector: index > 0,
                            showsBottomConnector: index < sessions.count - 1,
                            onSelect: { h in
                                withAnimation(.easeInOut(duration: 0.2)) { selectedHighlight = h }
                            }
                        )
                    }
                }
            }
            .padding(.bottom, 16)
        }
        .onScrollGeometryChange(for: Bool.self) { geo in
            let bottomEdge = geo.contentOffset.y + geo.containerSize.height
            return bottomEdge >= geo.contentSize.height - 400
        } action: { _, near in
            if near && hasMore { loadHighlights(reset: false) }
        }
        .overlay(alignment: .topLeading) {
            lassoRect
        }
    }

    @ViewBuilder
    private var lassoRect: some View {
        if let start = dragStart, let current = dragCurrent {
            GeometryReader { proxy in
                let svOrigin = proxy.frame(in: .global).origin
                let rect = makeRect(start: start, current: current)
                Rectangle()
                    .fill(Color.accentColor.opacity(0.08))
                    .overlay(Rectangle().strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1))
                    .frame(width: max(0, rect.width), height: max(0, rect.height))
                    .offset(x: rect.minX - svOrigin.x, y: rect.minY - svOrigin.y)
                    .allowsHitTesting(false)
            }
        }
    }

    private var selectionBar: some View {
        HStack(spacing: 10) {
            Text("\(selection.count) selected")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Spacer()

            Menu {
                if allTags.isEmpty {
                    Text("No collections yet")
                } else {
                    ForEach(allTags) { tag in
                        Button(tag.name) { bulkAddTag(tag) }
                    }
                }
            } label: {
                Label("Add to Collection", systemImage: "folder.badge.plus")
                    .font(.system(size: 12))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Button(role: .destructive, action: deleteSelection) {
                Label("Delete", systemImage: "trash")
                    .font(.system(size: 12))
            }

            Button {
                selection.clear()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
                    .font(.system(size: 16))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private var detailOverlay: some View {
        if let h = selectedHighlight {
            ZStack {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { selectedHighlight = nil } }
                CardDetailView(
                    highlight: h,
                    onDismiss: { withAnimation(.easeInOut(duration: 0.2)) { selectedHighlight = nil } },
                    onTagNavigation: { _, tag in
                        sidebarState.selectedFilter = .all
                        sidebarState.selectedApp = nil
                        sidebarState.selectedTagIds = [tag.id]
                        withAnimation(.easeInOut(duration: 0.2)) { selectedHighlight = nil }
                    }
                )
                .id(h.id)
                .frame(maxWidth: 700, maxHeight: .infinity)
                .background(Color(.windowBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(color: .black.opacity(0.25), radius: 16, y: 4)
                .padding(40)
            }
            .transition(.opacity)
            .onExitCommand { withAnimation(.easeInOut(duration: 0.2)) { selectedHighlight = nil } }
        }
    }

    private var emptyState: some View {
        EmptyView()
    }

    // MARK: - Selection actions

    private func updateLassoSelection() {
        guard let start = dragStart, let current = dragCurrent else { return }
        let rect = makeRect(start: start, current: current)
        let inLasso = Set(cardFrames.filter { rect.intersects($0.value) }.map { $0.key })
        selection.set(inLasso)
    }

    private func makeRect(start: CGPoint, current: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        )
    }

    private func deleteSelection() {
        guard !selection.isEmpty else { return }
        let ids = selection.selectedIds
        for id in ids {
            DatabaseManager.shared.deleteHighlight(id: id)
        }
        highlights.removeAll { ids.contains($0.id) }
        if let sh = selectedHighlight, ids.contains(sh.id) { selectedHighlight = nil }
        selection.clear()
        refreshSidebarData()
    }

    private func bulkAddTag(_ tag: Tag) {
        for id in selection.selectedIds {
            DatabaseManager.shared.addTag(tag.id, toHighlight: id)
        }
        NotificationCenter.default.post(name: .highlightDataDidChange, object: nil)
    }

    // MARK: - Helpers

    private func sessionLabel(for date: Date) -> String {
        let cal = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if cal.isDateInToday(date) { return time }
        if cal.isDateInYesterday(date) { return "Yesterday  \(time)" }
        if let days = cal.dateComponents([.day], from: date, to: Date()).day, days < 7 {
            return date.formatted(.dateTime.weekday(.wide)) + "  \(time)"
        }
        return date.formatted(date: .abbreviated, time: .omitted) + "  \(time)"
    }

    // MARK: - Data

    private var loadRequest: BrowseLoadRequest {
        BrowseLoadRequest(
            searchText: searchText,
            selectedFilter: sidebarState.selectedFilter,
            selectedApp: sidebarState.selectedApp,
            selectedTagIds: sidebarState.selectedTagIds
        )
    }

    private func loadHighlights(reset: Bool) {
        guard isActive else { return }
        if reset { highlightsOffset = 0; highlights = []; hasMore = false }
        let request = loadRequest
        let offset = highlightsOffset
        let limit = pageSize
        Task.detached(priority: .userInitiated) {
            let batch = DatabaseManager.shared.browseHighlights(request, offset: offset, limit: limit)
            await MainActor.run {
                let existingIds = Set(highlights.map(\.id))
                highlights.append(contentsOf: batch.filter { !existingIds.contains($0.id) })
                highlightsOffset += batch.count
                hasMore = batch.count == limit
            }
        }
    }

    private func refreshSidebarData() {
        Task.detached(priority: .userInitiated) {
            let db = DatabaseManager.shared
            db.pruneEmptyTags()
            let tags = db.allTags()
            let tCounts = db.tagHighlightCounts()
            var counts = db.typeCounts()
            counts["_annotated"] = db.annotatedHighlightCount()
            counts["_links"] = db.linkHighlightCount()
            counts["_videos"] = db.videoHighlightCount()
            counts["_filesNoVideo"] = db.fileExcludingVideoCount()
            await MainActor.run {
                allTags = tags
                tagCounts = tCounts
                typeCounts = counts
            }
        }
    }
}

// MARK: - Session grouping

struct TimelineSession: Identifiable {
    let highlights: [Highlight]
    var id: String { highlights.first?.id ?? "" }
    var date: Date { highlights.first?.date ?? Date() }
}

private func groupIntoSessions(_ highlights: [Highlight]) -> [TimelineSession] {
    var sessions: [TimelineSession] = []
    var bucket: [Highlight] = []
    for h in highlights {
        if let prev = bucket.last, prev.date.timeIntervalSince(h.date) > 90 * 60 {
            sessions.append(TimelineSession(highlights: bucket))
            bucket = [h]
        } else {
            bucket.append(h)
        }
    }
    if !bucket.isEmpty { sessions.append(TimelineSession(highlights: bucket)) }
    return sessions
}

// MARK: - Session row (label + horizontal strip of cards)

private struct SessionRow: View {
    let session: TimelineSession
    let labelText: String
    let noteTagIds: [String]
    let showsComposer: Bool
    let showsTopConnector: Bool
    let showsBottomConnector: Bool
    let onSelect: (Highlight) -> Void

    private let dotSize: CGFloat = 7
    private let dotTopInset: CGFloat = 20

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Spine
            VStack(spacing: 0) {
                connectorSegment(visible: showsTopConnector)
                    .frame(height: dotTopInset)
                Circle()
                    .fill(Color.primary.opacity(0.2))
                    .frame(width: dotSize, height: dotSize)
                connectorSegment(visible: showsBottomConnector)
                    .frame(maxHeight: .infinity)
            }
            .frame(width: 20)
            .padding(.leading, 16)

            VStack(alignment: .leading, spacing: 6) {
                Text(labelText.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 16)

                FlowLayout(spacing: 8) {
                    if showsComposer {
                        TimelineNoteComposer(tagIds: noteTagIds)
                    }
                    ForEach(session.highlights) { h in
                        TimelineCard(highlight: h, onSelect: onSelect)
                    }
                }
                .padding(.trailing, 20)
                .padding(.bottom, 16)
            }
            .padding(.leading, 12)
        }
    }

    @ViewBuilder
    private func connectorSegment(visible: Bool) -> some View {
        if visible {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(width: 1)
        } else {
            Color.clear
                .frame(width: 1)
        }
    }
}

// MARK: - Note composer

private struct TimelineNoteComposer: View {
    let tagIds: [String]
    @State private var text = ""
    @State private var isEditing = false

    private var showExpanded: Bool {
        isEditing || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var hasText: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Group {
            if showExpanded {
                VStack(spacing: 0) {
                    NoteTextView(
                        text: $text,
                        onSubmit: save,
                        onCancel: cancel,
                        onFocusLost: {
                            isEditing = false
                        }
                    )
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if hasText {
                        Divider().opacity(0.5)
                        AddButton(action: save)
                    }
                }
            } else {
                VStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Image(systemName: "plus")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("Add note")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { isEditing = true }
            }
        }
        .frame(width: cardWidth, height: cardHeight)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }

    private func save() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { cancel(); return }
        HighlightCapture.shared.captureFromUserAdd(text: trimmed, tagIds: tagIds)
        text = ""
        isEditing = false
    }

    private func cancel() { text = ""; isEditing = false }
}

// MARK: - Card

private let cardWidth: CGFloat = 160
private let cardHeight: CGFloat = 120

private struct TimelineCard: View {
    let highlight: Highlight
    let onSelect: (Highlight) -> Void

    @EnvironmentObject var selection: SelectionManager

    private var isSelected: Bool { selection.selectedIds.contains(highlight.id) }

    var body: some View {
        Button {
            let cmdHeld = NSApp.currentEvent?.modifierFlags.contains(.command) ?? false
            if cmdHeld || !selection.isEmpty {
                selection.toggle(highlight.id)
            } else {
                onSelect(highlight)
            }
        } label: {
            Group {
                switch highlight.highlightType {
                case "screenshot":
                    ScreenshotCard(highlight: highlight)
                case "file", "recording":
                    FileCard(highlight: highlight)
                default:
                    if highlight.isURLCopy {
                        LinkCard(highlight: highlight)
                    } else {
                        TextCard(highlight: highlight)
                    }
                }
            }
            .frame(width: cardWidth, height: cardHeight)
            .background(Color(.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(
                        isSelected ? Color.accentColor : Color.primary.opacity(0.07),
                        lineWidth: isSelected ? 2 : 0.5
                    )
            )
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.white, Color.accentColor)
                        .font(.system(size: 14, weight: .semibold))
                        .padding(4)
                        .shadow(color: .black.opacity(0.2), radius: 2)
                }
            }
        }
        .buttonStyle(.plain)
        .materialContextMenu(for: highlight)
        .background(GeometryReader { geo in
            Color.clear.preference(
                key: CardFrameKey.self,
                value: [highlight.id: geo.frame(in: .global)]
            )
        })
    }
}

// MARK: - Screenshot card

private struct ScreenshotCard: View {
    let highlight: Highlight
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let img = image {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: cardWidth, height: cardHeight)
                    .clipped()
            } else {
                Rectangle()
                    .fill(Color.primary.opacity(0.05))
                    .overlay(Image(systemName: "photo").foregroundStyle(.quaternary))
            }
        }
        .task {
            guard image == nil else { return }
            image = await Task.detached { NSImage(contentsOfFile: highlight.contentText) }.value
        }
    }
}

// MARK: - Text / note card

private struct TextCard: View {
    let highlight: Highlight
    private var isNote: Bool { highlight.highlightType == "note" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isNote {
                Rectangle()
                    .fill(Color.orange.opacity(0.7))
                    .frame(height: 2)
            }
            Text(highlight.contentText)
                .font(isNote ? .system(.caption, design: .serif) : .caption)
                .foregroundStyle(isNote ? .primary : .secondary)
                .lineLimit(6)
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

// MARK: - Link card

private struct LinkCard: View {
    let highlight: Highlight
    @State private var preview: LinkPreview?
    @State private var heroImage: NSImage?
    @State private var faviconImage: NSImage?
    @State private var didLoad = false

    private var urlString: String { highlight.contentText.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var displayHost: String {
        preview?.siteName
            ?? URL(string: urlString)?.host?.replacingOccurrences(of: "www.", with: "")
            ?? urlString
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let hero = heroImage {
                Image(nsImage: hero)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: cardWidth, height: 70)
                    .clipped()
            } else {
                Rectangle()
                    .fill(Color.primary.opacity(0.04))
                    .frame(height: 70)
                    .overlay(
                        didLoad ? AnyView(Image(systemName: "link").foregroundStyle(.quaternary))
                                : AnyView(ProgressView().controlSize(.mini))
                    )
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if let fav = faviconImage {
                        Image(nsImage: fav).resizable().frame(width: 10, height: 10)
                    } else {
                        Image(systemName: "link").font(.system(size: 8)).foregroundStyle(.tertiary)
                    }
                    Text(displayHost).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
                Text(preview?.title ?? urlString)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task {
            guard !didLoad else { return }
            let fetched = await LinkPreviewStore.shared.preview(for: urlString)
            preview = fetched
            didLoad = true
            if let path = fetched?.imagePath {
                heroImage = await Task.detached { NSImage(contentsOfFile: path) }.value
            }
            if let path = fetched?.faviconPath {
                faviconImage = await Task.detached { NSImage(contentsOfFile: path) }.value
            }
        }
    }
}

// MARK: - File / recording card

private struct FileCard: View {
    let highlight: Highlight
    @State private var thumbnail: NSImage?

    private var fileName: String { URL(fileURLWithPath: highlight.contentText).lastPathComponent }
    private var isRecording: Bool { highlight.highlightType == "recording" }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if let thumb = thumbnail {
                    Image(nsImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: cardWidth, height: 76)
                        .clipped()
                } else {
                    Rectangle()
                        .fill(Color.primary.opacity(0.04))
                        .frame(height: 76)
                    Image(nsImage: NSWorkspace.shared.icon(forFile: highlight.contentText))
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 36, height: 36)
                }
                if isRecording {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.white.opacity(0.85))
                        .shadow(radius: 2)
                }
            }

            Text(fileName)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .task {
            guard thumbnail == nil else { return }
            if let fid = highlight.fileId,
               let rec = DatabaseManager.shared.fileRecord(byId: fid),
               let path = rec.thumbnailPath {
                thumbnail = await Task.detached { NSImage(contentsOfFile: path) }.value
            }
            if thumbnail == nil {
                thumbnail = await LiveThumbnail.generate(for: URL(fileURLWithPath: highlight.contentText))
            }
        }
    }
}

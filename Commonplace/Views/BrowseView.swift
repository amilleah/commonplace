import SwiftUI
import AVKit
import Combine
import UniformTypeIdentifiers
import PDFKit
import Quartz
import QuickLookThumbnailing

// MARK: - Shared design tokens

enum UITokens {
    static let tagFont: Font = .system(size: 11, weight: .medium)
    static let tagHPad: CGFloat = 8
    static let tagVPad: CGFloat = 3
    static let sectionLabelFont: Font = .system(size: 10, weight: .semibold)
    static let sectionLabelTracking: CGFloat = 0.8
    static let sectionSpacing: CGFloat = 20
    static let chipFill = Color.primary.opacity(0.06)
    static let chipBorder = Color.primary.opacity(0.1)
    static let linkColor = Color.primary.opacity(0.78)
    static let linkHoverColor = Color.primary
}

struct ChipBackground: ViewModifier {
    var dashed: Bool = false
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, UITokens.tagHPad)
            .padding(.vertical, UITokens.tagVPad)
            .background(Capsule().fill(dashed ? Color.clear : UITokens.chipFill))
            .overlay(
                Capsule().strokeBorder(
                    UITokens.chipBorder,
                    style: StrokeStyle(lineWidth: 0.5, dash: dashed ? [2, 2] : [])
                )
            )
    }
}

extension View {
    func chipBackground(dashed: Bool = false) -> some View {
        modifier(ChipBackground(dashed: dashed))
    }
}

struct TagChip: View {
    let name: String
    var onRemove: (() -> Void)? = nil
    var onTap: (() -> Void)? = nil
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 4) {
            Text(name)
                .font(UITokens.tagFont)
                .foregroundStyle(onTap != nil && isHovered ? Color.accentColor : .secondary)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .chipBackground()
        .contentShape(Capsule())
        .onTapGesture {
            onTap?()
        }
        .onHover { hovering in
            guard onTap != nil else { return }
            isHovered = hovering
            if hovering {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.arrow.set()
            }
        }
    }
}

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(UITokens.sectionLabelFont)
            .tracking(UITokens.sectionLabelTracking)
            .foregroundStyle(.tertiary)
    }
}

struct FlatTag: View {
    let name: String
    var onRemove: (() -> Void)?
    var onTap: (() -> Void)?
    @State private var isHovered = false

    private var labelColor: Color {
        if onTap != nil && isHovered { return Color.accentColor }
        return isHovered ? Color.primary.opacity(0.85) : Color.primary.opacity(0.55)
    }

    var body: some View {
        HStack(spacing: 3) {
            Text("#\(name)")
                .font(.system(size: 12))
                .foregroundStyle(labelColor)
            if isHovered, let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onTap?()
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.1)) { isHovered = hovering }
            guard onTap != nil else { return }
            if hovering {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.arrow.set()
            }
        }
    }
}

struct InlineLink: View {
    let text: String
    let url: String
    var onTap: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 3) {
                Text(text)
                    .underline(isHovered, color: UITokens.linkHoverColor)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9, weight: .semibold))
                    .opacity(0.7)
            }
            .foregroundStyle(isHovered ? UITokens.linkHoverColor : UITokens.linkColor)
        }
        .buttonStyle(.plain)
        .help(url)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.1)) { isHovered = hovering }
        }
    }
}

struct OCRTextBlock: View {
    let text: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                SectionLabel(text: "Extracted text")
                Spacer()
                Button(action: { withAnimation(.easeInOut(duration: 0.12)) { expanded.toggle() } }) {
                    HStack(spacing: 3) {
                        Text(expanded ? "Show less" : "Show more")
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(expanded ? nil : 3)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }
}

struct NoteRow: View {
    let note: HighlightNote
    var onDelete: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(note.body)
                    .font(.system(.title3, design: .serif))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(CardMetadata.timeAgo(from: note.date))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.leading, 14)
            .overlay(alignment: .leading) {
                // Accent bar as an overlay so it hugs the text block exactly —
                // putting it as an HStack sibling let SwiftUI add slack.
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.orange.opacity(0.85))
                    .frame(width: 2.5)
            }

            Button(action: onDelete) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.primary.opacity(0.05)))
                    .opacity(isHovered ? 1 : 0)
            }
            .buttonStyle(.plain)
            .help("Delete note")
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.1)) { isHovered = hovering }
        }
    }
}

struct BrowseView: View {

    // MARK: - Injected sidebar state + data

    @ObservedObject var sidebarState: SidebarState
    @Binding var appFacets: [AppFacet]
    @Binding var allTags: [Tag]
    @Binding var tagCounts: [String: Int]
    @Binding var typeCounts: [String: Int]

    // MARK: - Local state

    @AppStorage("cardMinColumnWidth") private var minColumnWidth: Double = 260
    private let minColumnWidthRange: ClosedRange<Double> = 160...520
    private let zoomStep: Double = 40

    @State private var isActive = false
    @State private var searchText = ""
    @State private var selectedHighlight: Highlight?
    @State private var highlights: [Highlight] = []
    @State private var highlightsOffset = 0
    @State private var noteCounts: [String: Int] = [:]
    @State private var highlightTags: [String: [Tag]] = [:]
    @State private var isDropTargeted = false
    @State private var pinnedOrigin: PinnedOrigin? = nil
    @State private var hasMore = false
    private let pageSize = 50

    // MARK: - Pinned origin (navigation breadcrumb)

    struct PinnedOrigin: Equatable {
        let highlight: Highlight
        let targetTagId: String

        static func == (lhs: PinnedOrigin, rhs: PinnedOrigin) -> Bool {
            lhs.highlight.id == rhs.highlight.id && lhs.targetTagId == rhs.targetTagId
        }
    }

    private func navigateToTag(from origin: Highlight, tag: Tag) {
        selectedHighlight = nil
        pinnedOrigin = PinnedOrigin(highlight: origin, targetTagId: tag.id)
        sidebarState.selectedFilter = .all
        sidebarState.selectedApp = nil
        searchText = ""
        sidebarState.selectedTagIds = [tag.id]
        // loadCaptures triggered by onChange(of: sidebarState.selectedTagIds)
    }

    @ViewBuilder
    private func pinnedOriginRow(_ pinned: PinnedOrigin) -> some View {
        let tagName = allTags.first(where: { $0.id == pinned.targetTagId })?.name ?? "collection"
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.accentColor)
                    Text("From this capture → #\(tagName)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                MasonryCard(
                    highlight: pinned.highlight,
                    noteCount: noteCounts[pinned.highlight.id] ?? 0,
                    cardTags: highlightTags[pinned.highlight.id] ?? [],
                    onTagTap: { tag in
                        navigateToTag(from: pinned.highlight, tag: tag)
                    }
                )
                .frame(width: 240)
                .onTapGesture { selectedHighlight = pinned.highlight }
            }

            Spacer()

            Button(action: { pinnedOrigin = nil }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Unpin")
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .background(Color.accentColor.opacity(0.04))
    }

    // MARK: - Computed

    private var browseLoadRequest: BrowseLoadRequest {
        BrowseLoadRequest(
            searchText: searchText,
            selectedFilter: sidebarState.selectedFilter,
            selectedApp: sidebarState.selectedApp,
            selectedTagIds: sidebarState.selectedTagIds
        )
    }

    private var filteredHighlights: [Highlight] {
        var result = highlights
        // Exclude the pinned-origin highlight so it only shows as the pinned card.
        if let pinned = pinnedOrigin {
            result = result.filter { $0.id != pinned.highlight.id }
        }
        return result
    }

    private var emptyStateTitle: String {
        if browseLoadRequest.hasActiveSearch {
            return "No matching captures"
        }
        if browseLoadRequest.hasActiveFilters {
            return "No captures match this filter"
        }
        return "No captures yet"
    }

    private var emptyStateSubtitle: String? {
        if browseLoadRequest.hasActiveSearch || browseLoadRequest.hasActiveFilters {
            return "Clear the search or adjust the current filters."
        }
        return nil
    }

    /// The "+" add tile pins to the top-left of the masonry only on user-curated
    /// views. Type and App filters are metadata-derived (things land in those
    /// buckets based on how they were captured), so "add to Screenshots" or
    /// "add to app = Chrome" is semantically meaningless there.
    private var showAddTile: Bool {
        sidebarState.selectedFilter == .all && sidebarState.selectedApp == nil && !sidebarState.showSettings
    }

    // MARK: - Body

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
                // Breadcrumb: pinned origin from a tag navigation
                if let pinned = pinnedOrigin {
                    pinnedOriginRow(pinned)
                    Divider()
                }

                if filteredHighlights.isEmpty && !showAddTile {
                    VStack(spacing: 12) {
                        Spacer()
                        Image(systemName: "tray")
                            .font(.system(size: 36))
                            .foregroundStyle(.quaternary)
                        Text(emptyStateTitle)
                            .foregroundStyle(.secondary)
                            .font(.callout)
                        if let emptyStateSubtitle {
                            Text(emptyStateSubtitle)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        } else {
                            VStack(spacing: 4) {
                                Text("Cmd+Shift+3 — screenshot")
                                Text("Cmd+Shift+4 — region capture")
                                Text("Copy text anywhere — auto-captured")
                                Text("Drop files here to import")
                            }
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        }
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        MasonryLayout(minColumnWidth: minColumnWidth, spacing: 14, pinFirst: showAddTile) {
                            if showAddTile {
                                AddTile(tagIds: Array(sidebarState.selectedTagIds))
                            }
                            ForEach(filteredHighlights) { highlight in
                                MasonryCard(
                                    highlight: highlight,
                                    noteCount: noteCounts[highlight.id] ?? 0,
                                    cardTags: highlightTags[highlight.id] ?? [],
                                    onTagTap: { tag in
                                        navigateToTag(from: highlight, tag: tag)
                                    }
                                )
                                .id(highlight.id)
                                .onTapGesture {
                                    withAnimation(.easeInOut(duration: 0.2)) { selectedHighlight = highlight }
                                }
                            }
                        }
                        .padding(.horizontal, 16).padding(.vertical, 12)
                    }
                    .onScrollGeometryChange(for: Bool.self) { geo in
                        // True when scrolled within 400pt of the bottom of the content
                        let bottomEdge = geo.contentOffset.y + geo.containerSize.height
                        let threshold = geo.contentSize.height - 400
                        return bottomEdge >= threshold
                    } action: { _, isNearBottom in
                        if isNearBottom && hasMore {
                            loadCaptures(reset: false)
                        }
                    }
                }

                Divider()
                CaptureSearchBar(searchText: $searchText, count: filteredHighlights.count)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded { clearFocus() })
            .onDrop(of: [.fileURL, .item], isTargeted: $isDropTargeted) { providers in
                handleDrop(providers)
            }
            .overlay {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
                        .background(Color.accentColor.opacity(0.08))
                        .overlay {
                            VStack(spacing: 8) {
                                Image(systemName: "square.and.arrow.down.on.square")
                                    .font(.system(size: 36, weight: .regular))
                                    .foregroundStyle(Color.accentColor)
                                Text("Drop to add to captures")
                                    .font(.headline)
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .padding(8)
                        .allowsHitTesting(false)
                }
            }

            }
        }
        .background {
            Group {
                Button("") { minColumnWidth = min(minColumnWidth + zoomStep, minColumnWidthRange.upperBound) }
                    .keyboardShortcut("+", modifiers: .command)
                Button("") { minColumnWidth = max(minColumnWidth - zoomStep, minColumnWidthRange.lowerBound) }
                    .keyboardShortcut("-", modifiers: .command)
            }
            .hidden()
        }
        .onChange(of: sidebarState.selectedApp) { _, _ in
            guard isActive else { return }
            pinnedOrigin = nil
            loadCaptures(reset: true)
        }
        .onChange(of: sidebarState.selectedFilter) { _, _ in
            guard isActive else { return }
            pinnedOrigin = nil
            loadCaptures(reset: true)
        }
        .onChange(of: sidebarState.selectedTagIds) { _, newValue in
            guard isActive else { return }
            if let pinned = pinnedOrigin, newValue != Set([pinned.targetTagId]) {
                pinnedOrigin = nil
            }
            loadCaptures(reset: true)
        }
        .onChange(of: searchText) { _, _ in
            guard isActive else { return }
            loadCaptures(reset: true)
        }
        .onAppear {
            isActive = true
            loadCaptures(reset: true)
            refreshSidebarData()
        }
        .onDisappear { isActive = false }
        .onReceive(NotificationCenter.default.publisher(for: BrowseWindowController.windowDidShowNotification)) { _ in
            isActive = true
            loadCaptures(reset: true)
            refreshSidebarData()
        }
        .onReceive(NotificationCenter.default.publisher(for: .highlightDidSave).throttle(for: .seconds(1), scheduler: DispatchQueue.main, latest: true)) { _ in
            guard isActive else { return }
            loadCaptures(reset: true)
            refreshSidebarData()
        }
        .onReceive(NotificationCenter.default.publisher(for: .highlightDataDidChange).receive(on: DispatchQueue.main)) { notification in
            guard isActive else { return }
            let userInfo = notification.userInfo ?? [:]
            let hid = userInfo["highlightId"] as? String
            let change = userInfo["change"] as? String ?? ""

            // Targeted refresh for the affected highlight's cached state.
            if let hid {
                switch change {
                case "tags":
                    highlightTags[hid] = DatabaseManager.shared.tagsForHighlight(id: hid)
                case "notes":
                    let counts = DatabaseManager.shared.noteCountsForHighlights(ids: [hid])
                    noteCounts[hid] = counts[hid] ?? 0
                    // The userNote strip on the masonry card reads from highlight.userNote,
                    // which changes when a note is added/removed — refetch that row too.
                    if let updated = DatabaseManager.shared.highlight(byId: hid),
                       let idx = highlights.firstIndex(where: { $0.id == hid }) {
                        highlights[idx] = updated
                    }
                case "userNote":
                    if let updated = DatabaseManager.shared.highlight(byId: hid),
                       let idx = highlights.firstIndex(where: { $0.id == hid }) {
                        highlights[idx] = updated
                    }
                default:
                    break
                }
            }

            // Sidebar counts + allTags always refresh — both are cheap indexed scans.
            refreshSidebarData()

            if browseLoadRequest.shouldReloadOnHighlightMutation(change: change) {
                loadCaptures(reset: true)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .highlightDidDelete)) { notification in
            guard let hid = notification.userInfo?["highlightId"] as? String else { return }
            highlights.removeAll { $0.id == hid }
            if selectedHighlight?.id == hid { selectedHighlight = nil }
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
        .onReceive(NotificationCenter.default.publisher(for: BrowseWindowController.showHighlightDetailNotification)) { notification in
            guard let highlightId = notification.userInfo?["highlightId"] as? String,
                  let highlight = DatabaseManager.shared.highlight(byId: highlightId) else { return }
            sidebarState.selectedFilter = .all
            sidebarState.selectedApp = nil
            sidebarState.selectedTagIds = []
            searchText = ""
            isActive = true
            loadCaptures(reset: true)
            withAnimation(.easeInOut(duration: 0.2)) { selectedHighlight = highlight }
        }
        .overlay {
            if let highlight = selectedHighlight {
                ZStack {
                    Color.black.opacity(0.3)
                        .ignoresSafeArea()
                        .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { selectedHighlight = nil } }

                    CardDetailView(
                        highlight: highlight,
                        onDismiss: { withAnimation(.easeInOut(duration: 0.2)) { selectedHighlight = nil } },
                        onTagNavigation: { origin, tag in
                            navigateToTag(from: origin, tag: tag)
                        }
                    )
                        .id(highlight.id)
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
    }

    // MARK: - Data Loading

    private func loadCaptures(reset: Bool) {
        guard isActive else { return }
        if reset {
            highlightsOffset = 0
            highlights = []
            hasMore = false
        }

        let request = browseLoadRequest
        let offset = highlightsOffset
        let limit = pageSize
        let shouldRefreshFacets = reset

        Task.detached(priority: .userInitiated) {
            let db = DatabaseManager.shared
            let batch = db.browseHighlights(request, offset: offset, limit: limit)
            let newCounts = db.noteCountsForHighlights(ids: batch.map(\.id))
            let newTags = db.tagsForHighlights(ids: batch.map(\.id))
            let facets: [(appName: String, bundleId: String?, count: Int)]? =
                shouldRefreshFacets ? db.appFacets() : nil

            await MainActor.run {
                // Dedupe by id: an in-flight paginated load can race with a
                // reset triggered by .highlightDidSave / .highlightDataDidChange,
                // and real-time inserts can shift rows so the same id appears
                // on consecutive OFFSET pages. Either way, duplicate ids in
                // ForEach give undefined layout (overlapping masonry cards).
                let existingIds = Set(highlights.map(\.id))
                let newRows = batch.filter { !existingIds.contains($0.id) }
                highlights.append(contentsOf: newRows)
                highlightsOffset += batch.count
                hasMore = batch.count == limit
                noteCounts.merge(newCounts) { _, new in new }
                highlightTags.merge(newTags) { _, new in new }
                if let facets {
                    appFacets = facets.map {
                        AppFacet(appName: $0.appName, bundleId: $0.bundleId, count: $0.count)
                    }
                }
            }
        }
    }

    private func clearFocus() {
        NSApp.keyWindow?.makeFirstResponder(nil)
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

    // MARK: - Drag & Drop Import

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }

        // Snapshot the current tag filter at drop time so any tag change
        // mid-import doesn't race with the async import pipeline.
        let inheritedTagIds = Array(sidebarState.selectedTagIds)

        for provider in providers {
            provider.loadFileRepresentation(forTypeIdentifier: UTType.item.identifier) { url, error in
                if let error {
                    CaptureLog.warning("Drop import: loadFileRepresentation failed: \(error.localizedDescription)")
                    return
                }
                guard let url else { return }

                // The URL in this callback is deleted once the callback returns,
                // so we copy to a temp location we own before the async import.
                let tempDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("drop-import-\(UUID().uuidString)", isDirectory: true)
                do {
                    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                } catch {
                    CaptureLog.warning("Drop import: temp dir failed: \(error.localizedDescription)")
                    return
                }
                let tempURL = tempDir.appendingPathComponent(url.lastPathComponent)
                do {
                    try FileManager.default.copyItem(at: url, to: tempURL)
                } catch {
                    CaptureLog.warning("Drop import: temp copy failed for \(url.lastPathComponent): \(error.localizedDescription)")
                    return
                }

                Task {
                    await FileMonitor.shared.importFile(from: tempURL, tagIds: inheritedTagIds)
                    try? FileManager.default.removeItem(at: tempDir)
                }
            }
        }
        return true
    }
}

// MARK: - Masonry Layout

private struct MasonryLayout: Layout {
    let minColumnWidth: CGFloat
    let spacing: CGFloat
    /// When true, subview index 0 is placed at (col 0, row 0) regardless of
    /// column heights. The remaining subviews flow using the shortest-column
    /// heuristic. Used by the Browse view to pin the "+" AddTile top-left.
    var pinFirst: Bool = false

    private func columnCount(for width: CGFloat) -> Int {
        guard width.isFinite, width > 0, minColumnWidth > 0 else { return 2 }
        let maxCols = Int((width + spacing) / (minColumnWidth + spacing))
        return min(5, max(1, maxCols))
    }

    private func columnWidth(for totalWidth: CGFloat, columns: Int) -> CGFloat {
        let gaps = CGFloat(columns - 1) * spacing
        return max(0, (totalWidth - gaps) / CGFloat(columns))
    }

    struct CacheData {
        var measuredWidth: CGFloat = 0
        var columns: Int = 0
        var columnWidth: CGFloat = 0
        var heights: [CGFloat] = []
        var assignments: [(col: Int, y: CGFloat)] = []
        var contentHeight: CGFloat = 0
    }

    func makeCache(subviews: Subviews) -> CacheData { CacheData() }

    private func measureHeights(subviews: Subviews, colWidth: CGFloat) -> [CGFloat] {
        subviews.map {
            let measured = $0.sizeThatFits(.init(width: colWidth, height: nil)).height
            return measured.isFinite ? measured : 0
        }
    }

    private func refreshCache(
        for totalWidth: CGFloat,
        subviews: Subviews,
        cache: inout CacheData
    ) {
        let columns = columnCount(for: totalWidth)
        let colWidth = columnWidth(for: totalWidth, columns: columns)
        let heights = measureHeights(subviews: subviews, colWidth: colWidth)

        let widthChanged = abs(cache.measuredWidth - totalWidth) > 0.5
        let structureChanged =
            widthChanged ||
            cache.columns != columns ||
            cache.heights != heights ||
            cache.assignments.count != subviews.count

        guard structureChanged else { return }

        let (colHeights, assignments) = layout(columns: columns, colWidth: colWidth, heights: heights)
        cache.measuredWidth = totalWidth
        cache.columns = columns
        cache.columnWidth = colWidth
        cache.heights = heights
        cache.assignments = assignments
        cache.contentHeight = colHeights.max() ?? 0
    }

    /// Shortest-column-first with deterministic tie-breaking (leftmost column wins).
    /// This balances column heights evenly while being consistent across relayouts.
    /// When `pinFirst` is true, index 0 is always placed at (col 0, y 0) and the
    /// rest flow starting from that column's bumped height.
    private func layout(columns: Int, colWidth: CGFloat, heights: [CGFloat]) -> (colHeights: [CGFloat], assignments: [(col: Int, y: CGFloat)]) {
        var colHeights = Array(repeating: CGFloat(0), count: columns)
        var assignments: [(col: Int, y: CGFloat)] = []
        assignments.reserveCapacity(heights.count)

        var startIndex = 0
        if pinFirst, let firstHeight = heights.first {
            assignments.append((col: 0, y: 0))
            colHeights[0] = firstHeight
            startIndex = 1
        }

        for i in startIndex..<heights.count {
            let h = heights[i]
            // Pick the shortest column; on ties, pick the leftmost (lowest index)
            var shortestCol = 0
            var shortestH = colHeights[0]
            for c in 1..<columns {
                if colHeights[c] < shortestH {
                    shortestH = colHeights[c]
                    shortestCol = c
                }
            }
            if colHeights[shortestCol] > 0 { colHeights[shortestCol] += spacing }
            let y = colHeights[shortestCol]
            assignments.append((col: shortestCol, y: y))
            colHeights[shortestCol] += h
        }
        return (colHeights, assignments)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout CacheData) -> CGSize {
        let width = proposal.width ?? 300
        refreshCache(for: width, subviews: subviews, cache: &cache)
        return CGSize(width: width, height: cache.contentHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout CacheData) {
        refreshCache(for: bounds.width, subviews: subviews, cache: &cache)
        for (i, subview) in subviews.enumerated() {
            let a = cache.assignments[i]
            let x = bounds.minX + CGFloat(a.col) * (cache.columnWidth + spacing)
            let y = bounds.minY + a.y
            subview.place(
                at: CGPoint(x: x, y: y),
                proposal: .init(width: cache.columnWidth, height: cache.heights[i])
            )
        }
    }
}

// MARK: - Masonry Card

private struct MasonryCard: View {
    let highlight: Highlight
    var noteCount: Int = 0
    var cardTags: [Tag] = []
    var onTagTap: ((Tag) -> Void)? = nil
    @State private var isHovered = false
    @State private var isLinkHovered = false

    private var hasAnnotation: Bool {
        if let note = highlight.userNote, !note.isEmpty { return true }
        return false
    }

    private var hasSourceUrl: Bool {
        guard let url = highlight.sourceUrl, !url.isEmpty else { return false }
        return URL(string: url) != nil
    }

    private var sourceDomain: String? {
        guard let urlString = highlight.sourceUrl,
              let url = URL(string: urlString),
              let host = url.host else { return nil }
        return host.replacingOccurrences(of: "www.", with: "")
    }

    var body: some View {
        VStack(spacing: 0) {
            cardContent

            if hasAnnotation {
                VStack(alignment: .leading, spacing: 5) {
                    Text(highlight.userNote ?? "")
                        .font(.system(.callout, design: .serif))
                        .foregroundStyle(.primary.opacity(0.85))
                        .lineLimit(6)

                    if noteCount > 1 {
                        Text("+\(noteCount - 1) more")
                            .font(.caption2)
                            .foregroundStyle(.orange.opacity(0.8))
                    }
                }
                .padding(.leading, 14)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 0.5)
                        .fill(Color.orange.opacity(0.7))
                        .frame(width: 2)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !cardTags.isEmpty {
                HStack(spacing: 5) {
                    ForEach(cardTags.prefix(3)) { tag in
                        TagChip(name: tag.name, onTap: onTagTap.map { handler in
                            { handler(tag) }
                        })
                    }
                    if cardTags.count > 3 {
                        Text("+\(cardTags.count - 3)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
        }
        .background(Color(.windowBackgroundColor))
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
        .overlay(alignment: .topTrailing) {
            if hasSourceUrl && isHovered {
                Button(action: {
                    if let url = highlight.sourceUrl, let parsed = URL(string: url) {
                        NSWorkspace.shared.open(parsed)
                    }
                }) {
                    HStack(spacing: 0) {
                        if let domain = sourceDomain {
                            Text(domain)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .fixedSize()
                                .frame(width: isLinkHovered ? nil : 0, alignment: .trailing)
                                .clipped()
                                .padding(.leading, isLinkHovered ? 8 : 0)
                                .padding(.trailing, isLinkHovered ? 4 : 0)
                        }
                        Image(systemName: "arrow.up.forward.square.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.white)
                    }
                    .padding(.trailing, 4)
                    .padding(.vertical, 4)
                    .background(
                        Capsule().fill(.black.opacity(0.55))
                            .opacity(isLinkHovered ? 1 : 0)
                    )
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                }
                .buttonStyle(.plain)
                .padding(8)
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isLinkHovered = hovering
                    }
                }
                .transition(.opacity)
            }
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .materialContextMenu(for: highlight, cardTags: cardTags)
    }

    @ViewBuilder
    private var cardContent: some View {
        switch highlight.highlightType {
        case "screenshot":
            ScreenshotCard(highlight: highlight)
        case "recording":
            ScreenshotCard(highlight: highlight)
        case "highlight":
            HighlightCard(highlight: highlight)
        case "note":
            NoteCard(highlight: highlight)
        case "file":
            FileCard(highlight: highlight)
        default:
            if highlight.isURLCopy {
                LinkCard(highlight: highlight)
            } else {
                TextCard(highlight: highlight)
            }
        }
    }

    static func isURLCopy(_ h: Highlight) -> Bool {
        if h.contentType == "url" { return true }
        let trimmed = h.contentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") else { return false }
        // Ensure the whole thing is a URL, not a paragraph containing one.
        return !trimmed.contains(" ") && !trimmed.contains("\n")
    }
}

// MARK: - Screenshot Card

private struct CardCoverPreview<Placeholder: View, Overlay: View>: View {
    let image: NSImage?
    let fallbackAspectRatio: CGFloat
    let preferredAspectRatio: CGFloat?
    let aspectRatioBuckets: [CGFloat]
    let placeholder: Placeholder
    let overlay: Overlay

    init(
        image: NSImage?,
        fallbackAspectRatio: CGFloat = 1.3,
        preferredAspectRatio: CGFloat? = nil,
        aspectRatioBuckets: [CGFloat] = [0.82, 1.18, 1.62],
        @ViewBuilder placeholder: () -> Placeholder,
        @ViewBuilder overlay: () -> Overlay
    ) {
        self.image = image
        self.fallbackAspectRatio = fallbackAspectRatio
        self.preferredAspectRatio = preferredAspectRatio
        self.aspectRatioBuckets = aspectRatioBuckets
        self.placeholder = placeholder()
        self.overlay = overlay()
    }

    private var targetAspectRatio: CGFloat {
        // Exact DB ratio keeps the card height stable before and after image load —
        // no bucket snap means no jump when the image renders.
        if let preferred = preferredAspectRatio { return preferred }
        let buckets = aspectRatioBuckets.isEmpty ? [fallbackAspectRatio] : aspectRatioBuckets.sorted()
        guard let image, image.size.width > 0, image.size.height > 0 else {
            return nearestAspectRatio(to: fallbackAspectRatio, buckets: buckets)
        }
        return nearestAspectRatio(to: image.size.width / image.size.height, buckets: buckets)
    }

    private func nearestAspectRatio(to rawValue: CGFloat, buckets: [CGFloat]) -> CGFloat {
        buckets.min(by: { abs($0 - rawValue) < abs($1 - rawValue) }) ?? fallbackAspectRatio
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                placeholder
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            overlay
        }
        .aspectRatio(targetAspectRatio, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .background(.quaternary.opacity(0.12))
        .clipped()
    }
}

private extension CardCoverPreview where Overlay == EmptyView {
    init(
        image: NSImage?,
        fallbackAspectRatio: CGFloat = 1.3,
        preferredAspectRatio: CGFloat? = nil,
        aspectRatioBuckets: [CGFloat] = [0.82, 1.18, 1.62],
        @ViewBuilder placeholder: () -> Placeholder
    ) {
        self.init(
            image: image,
            fallbackAspectRatio: fallbackAspectRatio,
            preferredAspectRatio: preferredAspectRatio,
            aspectRatioBuckets: aspectRatioBuckets,
            placeholder: placeholder,
            overlay: { EmptyView() }
        )
    }
}

private struct ScreenshotCard: View {
    let highlight: Highlight
    @State private var image: NSImage?

    private var preferredAspectRatio: CGFloat? {
        guard let screenshotId = highlight.screenshotId,
              let record = DatabaseManager.shared.screenshot(byId: screenshotId),
              let width = record.imageWidth,
              let height = record.imageHeight,
              width > 0,
              height > 0 else { return nil }
        return CGFloat(width) / CGFloat(height)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardCoverPreview(
                image: image,
                fallbackAspectRatio: 1.42,
                preferredAspectRatio: preferredAspectRatio,
                aspectRatioBuckets: [0.82, 1.25, 1.78]
            ) {
                Rectangle()
                    .fill(.quaternary.opacity(0.3))
                    .overlay {
                        Image(systemName: "photo")
                            .foregroundStyle(.tertiary)
                    }
            }

            Text(CardMetadata.timeAgo(from: highlight.date))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .task {
            if image == nil {
                let path = highlight.contentText
                // Try loading as image first (screenshots, PNGs)
                image = await Task.detached {
                    NSImage(contentsOfFile: path)
                }.value
                // Fall back to video thumbnail extraction for recordings (.mov, .mp4)
                if image == nil {
                    image = await LiveThumbnail.generate(for: URL(fileURLWithPath: path))
                }
                // Fall back to FileRecord thumbnail if available
                if image == nil, let fileId = highlight.fileId,
                   let rec = DatabaseManager.shared.fileRecord(byId: fileId),
                   let thumbPath = rec.thumbnailPath {
                    image = await Task.detached {
                        NSImage(contentsOfFile: thumbPath)
                    }.value
                }
            }
        }
    }
}

// MARK: - Live Thumbnail Fallback

/// Generates a preview image on demand for videos and PDFs when the cached
/// `thumbnailPath` is missing or the file at that path cannot be loaded.
/// Used by RecordingCard and FileCard so the masonry always shows a real
/// preview instead of an icon placeholder.
enum LiveThumbnail {
    static func generate(for fileURL: URL) async -> NSImage? {
        let ext = fileURL.pathExtension.lowercased()
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }

        // Image files: load directly. QuickLook sometimes returns nil for PNGs
        // and other common image types, which causes the masonry to render a
        // file-icon placeholder instead of the actual image.
        let imageExts: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "gif", "bmp", "tiff", "tif", "webp"]
        if imageExts.contains(ext) {
            return await Task.detached(priority: .utility) {
                NSImage(contentsOf: fileURL)
            }.value
        }

        if ext == "pdf" {
            return await Task.detached(priority: .utility) {
                guard let doc = PDFDocument(url: fileURL),
                      let page = doc.page(at: 0) else { return nil }
                let pageRect = page.bounds(for: .mediaBox)
                let scale: CGFloat = 600.0 / max(pageRect.width, 1)
                let size = CGSize(width: pageRect.width * scale, height: pageRect.height * scale)
                return page.thumbnail(of: size, for: .mediaBox)
            }.value
        }

        let videoExts: Set<String> = ["mp4", "mov", "m4v", "avi", "mkv", "webm"]
        if videoExts.contains(ext) {
            let asset = AVURLAsset(url: fileURL)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 600, height: 600)
            // Prefer ~1s in — first frame is often black/partial on many codecs.
            for seconds in [1.0, 0.5, 0.0] {
                do {
                    let (cgImage, _) = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
                    return NSImage(cgImage: cgImage, size: .zero)
                } catch {
                    continue
                }
            }
            return nil
        }

        // Generic fallback: let QuickLook extract a cover/preview for any other
        // file type it understands — including EPUBs, Keynote, iBooks, etc.
        let request = QLThumbnailGenerator.Request(
            fileAt: fileURL,
            size: CGSize(width: 600, height: 600),
            scale: 2.0,
            representationTypes: .thumbnail
        )
        do {
            let thumbnail = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            return NSImage(cgImage: thumbnail.cgImage, size: .zero)
        } catch {
            return nil
        }
    }
}

// MARK: - Inline Video Player

struct InlineVideoPlayer: NSViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AVPlayerView {
        let playerView = AVPlayerView()
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        playerView.player = player
        playerView.controlsStyle = .inline
        playerView.showsFullScreenToggleButton = true
        context.coordinator.player = player
        context.coordinator.playerView = playerView
        player.play()
        return playerView
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {}

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: Coordinator) {
        coordinator.tearDown()
    }

    class Coordinator {
        var player: AVPlayer?
        var playerView: AVPlayerView?

        func tearDown() {
            player?.pause()
            player?.replaceCurrentItem(with: nil)
            if let pv = playerView, pv.window != nil, !pv.isHidden {
                pv.player = nil
            }
            playerView = nil
            player = nil
        }

        deinit {
            player?.pause()
            player?.replaceCurrentItem(with: nil)
        }
    }
}

// MARK: - Text Card

private struct TextCard: View {
    let highlight: Highlight

    var body: some View {
        if TextHighlightRouter.isImageFilePath(highlight.contentText) {
            ScreenshotCard(highlight: highlight)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 0) {
                    RoundedRectangle(cornerRadius: 0.5)
                        .fill(Color.primary.opacity(0.12))
                        .frame(width: 2)

                    Text(highlight.contentText)
                        .font(.system(.callout, design: .serif))
                        .foregroundStyle(.primary.opacity(0.85))
                        .lineLimit(12)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(CardMetadata.timeAgo(from: highlight.date))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }
}

// MARK: - Highlight Card

private struct HighlightCard: View {
    let highlight: Highlight

    var body: some View {
        if TextHighlightRouter.isImageFilePath(highlight.contentText) {
            ScreenshotCard(highlight: highlight)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 0) {
                    RoundedRectangle(cornerRadius: 0.5)
                        .fill(Color.orange.opacity(0.8))
                        .frame(width: 2)

                    Text(highlight.contentText)
                        .font(.system(.callout, design: .serif))
                        .foregroundStyle(.primary.opacity(0.85))
                        .lineLimit(12)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(CardMetadata.timeAgo(from: highlight.date))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }
}

// Shared detection — some highlights have a raw image file path as their
// contentText due to legacy capture paths. Render those as images instead of
// spewing the internal path across the masonry.
private enum TextHighlightRouter {
    private static let imageExts: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "gif", "bmp", "tiff", "tif", "webp"
    ]

    static func isImageFilePath(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return false }
        guard !trimmed.contains("\n") else { return false }
        let ext = (trimmed as NSString).pathExtension.lowercased()
        guard imageExts.contains(ext) else { return false }
        return FileManager.default.fileExists(atPath: trimmed)
    }
}

// MARK: - Note Card

private struct NoteCard: View {
    let highlight: Highlight

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(highlight.contentText)
                .font(.system(.body, design: .serif))
                .foregroundStyle(.primary.opacity(0.85))
                .lineLimit(12)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(CardMetadata.timeAgo(from: highlight.date))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

// MARK: - File Card

private struct FileCard: View {
    let highlight: Highlight
    @State private var thumbnail: NSImage?
    @State private var fileRecord: FileRecord?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardCoverPreview(
                image: thumbnail,
                fallbackAspectRatio: 1.28,
                aspectRatioBuckets: [1.0, 1.28, 1.58]
            ) {
                Rectangle()
                    .fill(.quaternary.opacity(0.15))
                    .overlay {
                        VStack(spacing: 6) {
                            Image(nsImage: systemFileIcon)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(height: 48)
                            if let ext = fileRecord?.fileExtension, !ext.isEmpty {
                                Text(ext.uppercased())
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
            } overlay: {
                if let pages = fileRecord?.pageCount, pages > 0 {
                    Text("\(pages) pg")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.6))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .padding(6)
                }
            }

            HStack {
                Text(fileRecord?.fileName ?? URL(fileURLWithPath: highlight.contentText).lastPathComponent)
                    .font(.caption)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Spacer()
                Text(CardMetadata.timeAgo(from: highlight.date))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .task {
            // Resolve the FileRecord: prefer foreign key, but fall back to
            // a path lookup if the highlight was inserted before the FK fix.
            var rec: FileRecord?
            if let fId = highlight.fileId {
                rec = DatabaseManager.shared.fileRecord(byId: fId)
            }
            if rec == nil {
                rec = DatabaseManager.shared.fileRecordByPath(highlight.contentText)
            }
            guard let rec else { return }
            self.fileRecord = rec

            if let thumbPath = rec.thumbnailPath {
                thumbnail = await Task.detached {
                    NSImage(contentsOfFile: thumbPath)
                }.value
            }
            // Always try a live preview for videos/PDFs when the cached
            // thumbnail is missing or failed to load.
            if thumbnail == nil {
                thumbnail = await LiveThumbnail.generate(for: URL(fileURLWithPath: rec.filePath))
            }
        }
    }

    private var systemFileIcon: NSImage {
        let path = highlight.contentText
        if FileManager.default.fileExists(atPath: path) {
            return NSWorkspace.shared.icon(forFile: path)
        }
        // File might have been deleted — use UTI-based icon
        if let ext = fileRecord?.fileExtension,
           let utType = UTType(filenameExtension: ext) {
            return NSWorkspace.shared.icon(for: utType)
        }
        return NSWorkspace.shared.icon(for: .data)
    }
}

// MARK: - Link Card

private struct LinkCard: View {
    let highlight: Highlight
    @State private var preview: LinkPreview?
    @State private var heroImage: NSImage?
    @State private var faviconImage: NSImage?
    @State private var didLoad = false

    private var urlString: String {
        highlight.contentText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var displayHost: String {
        preview?.siteName
            ?? URL(string: urlString)?.host?.replacingOccurrences(of: "www.", with: "")
            ?? urlString
    }

    private var displayTitle: String {
        if let title = preview?.title, !title.isEmpty { return title }
        return urlString
    }

    private func openURL() {
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: openURL) {
                VStack(alignment: .leading, spacing: 0) {
                    if heroImage != nil || !didLoad {
                        CardCoverPreview(
                            image: heroImage,
                            fallbackAspectRatio: 1.45,
                            aspectRatioBuckets: [1.33, 1.58, 1.82]
                        ) {
                            Rectangle()
                                .fill(.quaternary.opacity(0.15))
                                .overlay {
                                    if !didLoad {
                                        ProgressView()
                                            .controlSize(.small)
                                    } else {
                                        Image(systemName: "link")
                                            .font(.system(size: 20, weight: .medium))
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            if let faviconImage {
                                Image(nsImage: faviconImage)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 14, height: 14)
                            } else {
                                Image(systemName: "link")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 14, height: 14)
                            }
                            Text(displayHost)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }

                        Text(displayTitle)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(3)
                            .truncationMode(.tail)
                            .multilineTextAlignment(.leading)

                        HStack(spacing: 4) {
                            if let app = highlight.sourceApp {
                                Text(app)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                            Text(CardMetadata.timeAgo(from: highlight.date))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .buttonStyle(.plain)
        }
        .task {
            let fetched = await LinkPreviewStore.shared.preview(for: urlString)
            self.preview = fetched
            self.didLoad = true
            if let path = fetched?.imagePath {
                self.heroImage = await Task.detached { NSImage(contentsOfFile: path) }.value
            }
            if let path = fetched?.faviconPath {
                self.faviconImage = await Task.detached { NSImage(contentsOfFile: path) }.value
            }
        }
    }
}

// MARK: - Detail Link Preview (full-size, shown inside CardDetailView)

struct DetailLinkPreview: View {
    let urlString: String
    @State private var preview: LinkPreview?
    @State private var heroImage: NSImage?
    @State private var faviconImage: NSImage?
    @State private var didLoad = false
    @State private var isHovered = false

    private var displayHost: String {
        preview?.siteName
            ?? URL(string: urlString)?.host?.replacingOccurrences(of: "www.", with: "")
            ?? urlString
    }

    private var displayTitle: String {
        if let title = preview?.title, !title.isEmpty { return title }
        return urlString
    }

    var body: some View {
        Button(action: openInBrowser) {
            VStack(alignment: .leading, spacing: 14) {
                if let heroImage {
                    Image(nsImage: heroImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: 360)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else if !didLoad {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.quaternary.opacity(0.15))
                        .frame(height: 200)
                        .overlay { ProgressView() }
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        if let faviconImage {
                            Image(nsImage: faviconImage)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 14, height: 14)
                        } else {
                            Image(systemName: "link")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .frame(width: 14, height: 14)
                        }
                        Text(displayHost)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(isHovered ? .primary : .tertiary)
                    }

                    Text(displayTitle)
                        .font(.system(.title3, design: .serif).weight(.semibold))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isHovered ? Color.primary.opacity(0.04) : Color.primary.opacity(0.02))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.primary.opacity(isHovered ? 0.18 : 0.1), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .help(urlString)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) { isHovered = hovering }
        }
        .task {
            let fetched = await LinkPreviewStore.shared.preview(for: urlString)
            self.preview = fetched
            self.didLoad = true
            if let path = fetched?.imagePath {
                self.heroImage = await Task.detached { NSImage(contentsOfFile: path) }.value
            }
            if let path = fetched?.faviconPath {
                self.faviconImage = await Task.detached { NSImage(contentsOfFile: path) }.value
            }
        }
    }

    private func openInBrowser() {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Embedded Link Preview (compact row, shown near the bottom of detail view)

struct EmbeddedLinkPreview: View {
    let urlString: String
    @State private var preview: LinkPreview?
    @State private var heroImage: NSImage?
    @State private var faviconImage: NSImage?
    @State private var didLoad = false

    private var displayHost: String {
        preview?.siteName
            ?? URL(string: urlString)?.host?.replacingOccurrences(of: "www.", with: "")
            ?? urlString
    }

    private var displayTitle: String {
        if let title = preview?.title, !title.isEmpty { return title }
        return urlString
    }

    var body: some View {
        // Hide the section entirely if the fetch failed and there's nothing
        // meaningful to show — don't pollute the detail view with error rows.
        if didLoad && preview?.fetchError != nil && heroImage == nil && preview?.title == nil {
            EmptyView()
        } else {
            Button(action: openInBrowser) {
                HStack(alignment: .top, spacing: 10) {
                    if let heroImage {
                        Image(nsImage: heroImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 80, height: 60)
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    } else if !didLoad {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(.quaternary.opacity(0.2))
                            .frame(width: 80, height: 60)
                            .overlay { ProgressView().controlSize(.small) }
                    } else {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(.quaternary.opacity(0.15))
                            .frame(width: 80, height: 60)
                            .overlay {
                                Image(systemName: "link")
                                    .foregroundStyle(.tertiary)
                            }
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            if let faviconImage {
                                Image(nsImage: faviconImage)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 12, height: 12)
                            }
                            Text(displayHost)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Text(displayTitle)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 0)
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.secondary.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.secondary.opacity(0.12), lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
            .task {
                let fetched = await LinkPreviewStore.shared.preview(for: urlString)
                self.preview = fetched
                self.didLoad = true
                if let path = fetched?.imagePath {
                    self.heroImage = await Task.detached { NSImage(contentsOfFile: path) }.value
                }
                if let path = fetched?.faviconPath {
                    self.faviconImage = await Task.detached { NSImage(contentsOfFile: path) }.value
                }
            }
        }
    }

    private func openInBrowser() {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Card Metadata

// MARK: - Instant Tooltip Button

struct InstantTooltipButton: View {
    let icon: String
    let label: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(isHovered ? Color.primary : Color.primary.opacity(0.4))
        }
        .buttonStyle(.plain)
        .help(label)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.1)) { isHovered = hovering }
        }
    }
}

// MARK: - PDF Preview

struct PDFPreviewView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displaysPageBreaks = true
        pdfView.document = PDFDocument(url: url)
        pdfView.backgroundColor = NSColor.textBackgroundColor
        // PDFView has no useful intrinsic content size — force a sensible
        // default so SwiftUI gives it real vertical space inside a ScrollView.
        pdfView.setContentHuggingPriority(.defaultLow, for: .vertical)
        pdfView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        pdfView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        pdfView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return pdfView
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        if nsView.document?.documentURL != url {
            nsView.document = PDFDocument(url: url)
        }
    }
}

// MARK: - EPUB Preview (wraps macOS QLPreviewView — renders the full book)

/// Wraps `QLPreviewView` so SwiftUI can embed it. `QLPreviewView` is the same
/// NSView macOS uses for inline Quick Look previews and renders EPUBs as a
/// full paginated reader. It also handles many other formats, so we can reuse
/// it as a generic fallback for file types that don't have a dedicated branch.
struct QuickLookPreviewView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        view.previewItem = url as QLPreviewItem
        // Fill whatever space the parent SwiftUI frame gives us — QLPreviewView
        // has no meaningful intrinsic content size.
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateNSView(_ nsView: QLPreviewView, context: Context) {
        if let current = nsView.previewItem as? URL, current == url { return }
        nsView.previewItem = url as QLPreviewItem
    }

    static func dismantleNSView(_ nsView: QLPreviewView, coordinator: ()) {
        nsView.close()
    }
}

// MARK: - File Open Helper

/// Opens a file, using Preview for PDFs instead of the system default.
func openFile(_ path: String) {
    let url = URL(fileURLWithPath: path)
    if url.pathExtension.lowercased() == "pdf",
       let previewURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") {
        NSWorkspace.shared.open([url], withApplicationAt: previewURL, configuration: NSWorkspace.OpenConfiguration())
    } else {
        NSWorkspace.shared.open(url)
    }
}

enum CardMetadata {
    static func domain(from urlString: String?) -> String? {
        guard let urlString, !urlString.isEmpty,
              let url = URL(string: urlString),
              let host = url.host else { return nil }
        // Strip "www." prefix for cleaner display
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    static func shortURL(from urlString: String?) -> String? {
        guard let urlString, !urlString.isEmpty,
              let url = URL(string: urlString),
              let host = url.host else { return nil }
        let domain = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let path = url.path == "/" ? "" : url.path
        let full = domain + path
        return full.count > 60 ? String(full.prefix(57)) + "..." : full
    }

    static func timeAgo(from date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        switch seconds {
        case ..<60:     return "just now"
        case ..<3600:
            let m = seconds / 60
            return "\(m) min ago"
        case ..<86400:
            let h = seconds / 3600
            return "\(h) hr\(h == 1 ? "" : "s") ago"
        case ..<172800: return "yesterday"
        default:
            let f = DateFormatter()
            f.dateFormat = "MMM d"
            return f.string(from: date)
        }
    }
}

private struct CardMetadataFooter: View {
    let highlight: Highlight

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let wt = highlight.windowTitle, !wt.isEmpty {
                Text(wt.count > 50 ? String(wt.prefix(47)) + "..." : wt)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack(spacing: 4) {
                if let app = highlight.sourceApp {
                    Text(app)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if let shortURL = CardMetadata.shortURL(from: highlight.sourceUrl) {
                    Text(shortURL)
                        .font(.caption2)
                        .foregroundStyle(.blue.opacity(0.7))
                        .lineLimit(1)
                        .onTapGesture {
                            if let url = URL(string: highlight.sourceUrl ?? "") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                }
                if let ct = highlight.contentType, ct != "prose" {
                    Text(ct)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.quaternary.opacity(0.5))
                        .clipShape(Capsule())
                }
                Spacer()
                Text(CardMetadata.timeAgo(from: highlight.date))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// CardDetailView and StableVideoPlayer live in CardDetailView.swift

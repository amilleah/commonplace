import SwiftUI

/// Left sidebar for the Browse window.
/// Collections (tags) first, then type filters, then source apps.
struct CaptureFilterSidebar: View {
    let appFacets: [AppFacet]
    let allTags: [Tag]
    let tagCounts: [String: Int]
    let typeCounts: [String: Int]
    @Binding var selectedApp: String?
    @Binding var selectedFilter: CaptureFilter
    @Binding var selectedTagIds: Set<String>
    @Binding var showSettings: Bool
    @State private var emojiPickerTagId: String?
    @State private var renamingTagId: String?
    @State private var renameText: String = ""

    private var totalCount: Int {
        typeCounts.totalBrowseHighlights
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Collections (tags) — first, only those with items
                    if !allTags.isEmpty {
                        collectionsSection
                    }

                    // Type filters
                    typeSection

                    // Source apps
                    if !appFacets.isEmpty {
                        appSection
                    }
                }
                .padding(.vertical, 12)
            }

            Divider()

            Button(action: { cancelRename(); showSettings.toggle() }) {
                HStack(spacing: 8) {
                    Image(systemName: "gear")
                        .font(.caption)
                        .frame(width: 16)
                    Text("Settings")
                        .font(.callout)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(showSettings ? Color.accentColor.opacity(0.15) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(showSettings ? .primary : .secondary)
        }
        .frame(width: 200)
    }

    // MARK: - Collections (Tags)

    private var collectionsSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Collections")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 12)
                .padding(.bottom, 4)

            ForEach(allTags) { tag in
                tagRow(tag)
            }
        }
    }

    @ViewBuilder
    private func tagRow(_ tag: Tag) -> some View {
        let count = tagCounts[tag.id] ?? 0
        let isSelected = selectedTagIds.contains(tag.id)
        HStack(spacing: 8) {
            // Clickable icon — hover highlights, click opens emoji picker
            TagIconButton(tag: tag, isPickerOpen: emojiPickerTagId == tag.id) {
                emojiPickerTagId = tag.id
            }
            .popover(isPresented: Binding(
                get: { emojiPickerTagId == tag.id },
                set: { if !$0 { emojiPickerTagId = nil } }
            ), arrowEdge: .trailing) {
                EmojiPickerView(
                    currentEmoji: tag.emoji,
                    onSelect: { emoji in
                        DatabaseManager.shared.setTagEmoji(id: tag.id, emoji: emoji)
                        emojiPickerTagId = nil
                        NotificationCenter.default.post(name: .highlightDataDidChange, object: nil,
                                                        userInfo: ["change": "tags"])
                    },
                    onRemove: {
                        DatabaseManager.shared.setTagEmoji(id: tag.id, emoji: nil)
                        emojiPickerTagId = nil
                        NotificationCenter.default.post(name: .highlightDataDidChange, object: nil,
                                                        userInfo: ["change": "tags"])
                    }
                )
            }

            if renamingTagId == tag.id {
                InlineTagRenameField(
                    text: $renameText,
                    onCommit: {
                        commitRename(tag)
                    },
                    onCancel: {
                        renamingTagId = nil
                    }
                )
                .font(.callout)
            } else {
                Text(tag.name)
                    .font(.callout)
                    .lineLimit(1)
                    .onTapGesture(count: 2) {
                        renameText = tag.name
                        renamingTagId = tag.id
                        // Also select this collection so you're viewing it while renaming
                        if selectedTagIds != [tag.id] {
                            selectedTagIds = [tag.id]
                            selectedFilter = .all
                            selectedApp = nil
                            showSettings = false
                        }
                    }
            }
            Spacer(minLength: 0)
            if renamingTagId != tag.id {
                if tag.isPublished == true {
                    Image(systemName: "cloud.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.blue.opacity(0.6))
                }
                Text("\(count)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .foregroundStyle(isSelected ? .primary : .secondary)
        .onTapGesture {
            if renamingTagId == tag.id { return }
            selectTag(tag.id)
        }
        .contextMenu {
            tagContextMenu(tag)
        }
    }

    private func commitRename(_ tag: Tag) {
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && trimmed.lowercased() != tag.name {
            DatabaseManager.shared.renameTag(id: tag.id, newName: trimmed)
            NotificationCenter.default.post(name: .highlightDataDidChange, object: nil,
                                            userInfo: ["change": "tags"])
        }
        renamingTagId = nil
    }

    @ViewBuilder
    private func tagContextMenu(_ tag: Tag) -> some View {
        Button("Rename") {
            renameText = tag.name
            renamingTagId = tag.id
        }
        Divider()
        if tag.isPublished == true {
            Button("Unpublish") {
                CollectionPublisher.shared.unpublishCollection(tag)
            }
            if !CollectionPublisher.shared.publicUrl.isEmpty {
                let url = "\(CollectionPublisher.shared.publicUrl)/\(tag.slug)/index.html"
                Button("Copy Web URL") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url, forType: .string)
                }
                let apiUrl = "\(CollectionPublisher.shared.publicUrl)/\(tag.slug)/manifest.json"
                Button("Copy API URL") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(apiUrl, forType: .string)
                }
            }
        } else {
            Button("Publish") {
                Task { await CollectionPublisher.shared.publishCollection(tag) }
            }
            .disabled(!CollectionPublisher.shared.isConfigured)
        }
        Divider()
        Button(role: .destructive) {
            deleteCollection(tag)
        } label: {
            Label("Delete Collection", systemImage: "trash")
        }
    }

    private func deleteCollection(_ tag: Tag) {
        if selectedTagIds.contains(tag.id) {
            selectedTagIds.remove(tag.id)
            if selectedTagIds.isEmpty { selectedFilter = .all }
        }
        DatabaseManager.shared.deleteTag(id: tag.id)
        NotificationCenter.default.post(name: .highlightDataDidChange, object: nil, userInfo: ["change": "tags"])
    }

    private func cancelRename() {
        renamingTagId = nil
    }

    private func selectTag(_ tagId: String) {
        cancelRename()
        NSApp.keyWindow?.makeFirstResponder(nil)
        if selectedTagIds == [tagId] { return }
        selectedTagIds = [tagId]
        selectedFilter = .all
        selectedApp = nil
        showSettings = false
    }

    // MARK: - Type Filters

    private var typeSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Type")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 12)
                .padding(.bottom, 4)

            ForEach(CaptureFilter.allCases, id: \.self) { filter in
                let count: Int = if filter == .all {
                    totalCount
                } else if filter == .annotated {
                    typeCounts["_annotated"] ?? 0
                } else if filter == .links {
                    typeCounts["_links"] ?? 0
                } else if filter == .videos {
                    typeCounts["_videos"] ?? 0
                } else if filter == .files {
                    typeCounts["_filesNoVideo"] ?? 0
                } else {
                    typeCounts[filter.highlightType ?? ""] ?? 0
                }

                HStack(spacing: 8) {
                    Image(systemName: filter.icon)
                        .font(.caption)
                        .frame(width: 16)
                    Text(filter.rawValue)
                        .font(.callout)
                    Spacer(minLength: 0)
                    Text("\(count)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(isTypeSelected(filter) ? Color.accentColor.opacity(0.15) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
                .foregroundStyle(isTypeSelected(filter) ? .primary : .secondary)
                .onTapGesture { selectType(filter) }
            }
        }
    }

    private func isTypeSelected(_ filter: CaptureFilter) -> Bool {
        selectedFilter == filter && selectedApp == nil && selectedTagIds.isEmpty
    }

    private func selectType(_ filter: CaptureFilter) {
        cancelRename()
        NSApp.keyWindow?.makeFirstResponder(nil)
        selectedFilter = filter
        selectedApp = nil
        selectedTagIds = []
        showSettings = false
    }

    // MARK: - Source Apps

    private var appSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Source App")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 12)
                .padding(.bottom, 4)

            ForEach(appFacets.prefix(15)) { facet in
                HStack(spacing: 8) {
                    appIcon(for: facet)
                        .frame(width: 16, height: 16)
                    Text(facet.appName)
                        .font(.callout)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text("\(facet.count)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(selectedApp == facet.appName ? Color.accentColor.opacity(0.15) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
                .foregroundStyle(selectedApp == facet.appName ? .primary : .secondary)
                .onTapGesture { selectApp(facet.appName) }
            }
        }
    }

    private func selectApp(_ appName: String) {
        cancelRename()
        NSApp.keyWindow?.makeFirstResponder(nil)
        if selectedApp == appName {
            selectedApp = nil
            selectedFilter = .all
            selectedTagIds = []
            return
        }
        selectedApp = appName
        selectedFilter = .all
        selectedTagIds = []
        showSettings = false
    }

    @ViewBuilder
    private func appIcon(for facet: AppFacet) -> some View {
        if let bundleId = facet.bundleId,
           let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            let icon = NSWorkspace.shared.icon(forFile: appURL.path)
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "app")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - CaptureFilter (shared enum)

enum CaptureFilter: String, CaseIterable {
    case all = "All"
    case annotated = "Annotated"
    case screenshots = "Screenshots"
    case videos = "Videos"
    case links = "Links"
    case copies = "Copies"
    case files = "Files"

    var highlightType: String? {
        switch self {
        case .all, .annotated, .links, .videos: return nil
        case .screenshots: return "screenshot"
        case .copies: return "copy"
        case .files: return "file"
        }
    }

    var isAnnotatedFilter: Bool { self == .annotated }
    var isLinksFilter: Bool { self == .links }
    var isVideosFilter: Bool { self == .videos }
    /// Files filter excludes videos — they have their own category.
    var isFilesExcludingVideos: Bool { self == .files }

    var icon: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .annotated: return "text.bubble"
        case .screenshots: return "camera.viewfinder"
        case .videos: return "video.fill"
        case .links: return "link"
        case .copies: return "doc.on.clipboard"
        case .files: return "doc.fill"
        }
    }
}

// MARK: - AppFacet

struct AppFacet: Identifiable {
    let appName: String
    let bundleId: String?
    let count: Int

    var id: String { appName }
}

// MARK: - Color hex helper

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: Double
        switch hex.count {
        case 6:
            r = Double((int >> 16) & 0xFF) / 255
            g = Double((int >> 8) & 0xFF) / 255
            b = Double(int & 0xFF) / 255
        default:
            r = 0.5; g = 0.5; b = 0.5
        }
        self.init(red: r, green: g, blue: b)
    }
}

// MARK: - Tag Icon Button

/// The folder/emoji icon in a tag row. Hover shows a subtle highlight;
/// click opens the emoji picker popover.
private struct TagIconButton: View {
    let tag: Tag
    let isPickerOpen: Bool
    let onTap: () -> Void
    @State private var isHovered = false

    var body: some View {
        Group {
            if let emoji = tag.emoji, !emoji.isEmpty {
                Text(emoji)
                    .font(.system(size: 13))
            } else {
                Image(systemName: "folder.fill")
                    .font(.caption)
            }
        }
        .frame(width: 22, height: 22)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isHovered || isPickerOpen ? Color.primary.opacity(0.08) : Color.clear)
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.1)) { isHovered = hovering }
        }
        .onTapGesture {
            onTap()
        }
        .help("Set icon")
    }
}

// MARK: - Inline Rename Field

/// A text field that appears in place of the tag name for renaming.
/// Auto-focuses and selects all text. Enter or focus-loss commits, Escape cancels.
private struct InlineTagRenameField: View {
    @Binding var text: String
    let onCommit: () -> Void
    let onCancel: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.primary.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                    )
            )
            .focused($isFocused)
            .onSubmit { onCommit() }
            .onExitCommand { onCancel() }
            .onAppear {
                isFocused = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    if let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
                        editor.selectAll(nil)
                    }
                }
            }
            .onChange(of: isFocused) { _, focused in
                if !focused { onCommit() }
            }
    }
}

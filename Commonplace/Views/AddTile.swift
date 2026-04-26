import SwiftUI
import AppKit

/// Simple text note "+" tile pinned to the top-left of the Browse masonry.
/// Click to start typing, ⌘+Enter to save, Esc to cancel. Inherits the
/// current tag filter so notes land in the collection the user is viewing.
struct AddTile: View {
    let tagIds: [String]

    @State private var text: String = ""
    @State private var isEditing: Bool = false

    /// Key for persisting drafts per collection in UserDefaults.
    private var draftKey: String {
        let id = tagIds.sorted().joined(separator: ",")
        return "addTileDraft_\(id)"
    }

    /// Show the expanded editor if actively editing OR there's a draft with text.
    private var showExpanded: Bool {
        isEditing || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Group {
            if showExpanded {
                expandedBody
            } else {
                collapsedBody
            }
        }
        .frame(height: 180)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture {
            if !isEditing {
                isEditing = true
            }
        }
        .onChange(of: tagIds) { _, _ in
            // Save current draft, load the new collection's draft
            saveDraft()
            isEditing = false
            text = UserDefaults.standard.string(forKey: draftKey) ?? ""
        }
        .onAppear {
            text = UserDefaults.standard.string(forKey: draftKey) ?? ""
        }
    }

    // MARK: - Collapsed

    private var collapsedBody: some View {
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
    }

    // MARK: - Expanded

    private var hasText: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var expandedBody: some View {
        VStack(spacing: 0) {
            NoteTextView(
                text: $text,
                onSubmit: save,
                onCancel: cancel,
                onFocusLost: {
                    isEditing = false
                    saveDraft()
                }
            )
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if hasText {
                Divider().opacity(0.5)
                AddButton(action: save)
            }
        }
    }

    // MARK: - Actions

    private func save() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { cancel(); return }
        HighlightCapture.shared.captureFromUserAdd(text: trimmed, tagIds: tagIds)
        text = ""
        isEditing = false
        UserDefaults.standard.removeObject(forKey: draftKey)
    }

    private func cancel() {
        text = ""
        isEditing = false
        UserDefaults.standard.removeObject(forKey: draftKey)
    }

    private func saveDraft() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: draftKey)
        } else {
            UserDefaults.standard.set(text, forKey: draftKey)
        }
    }
}

// MARK: - Add Button (full-width footer, shown only when text is present)

struct AddButton: View {
    let action: () -> Void
    @State private var isHovered = false

    init(action: @escaping () -> Void) {
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text("Add")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isHovered ? Color.primary : Color.primary.opacity(0.7))
                .frame(maxWidth: .infinity)
                .frame(height: 36)
                .background(isHovered ? Color.primary.opacity(0.06) : Color.clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.1)) { isHovered = hovering }
        }
    }
}

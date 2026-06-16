import SwiftUI
import AppKit

// Unified right-click menu for any material in the archive.
// Layout: Copy, Open, Reveal in Finder, Share, Collection.
// Open/Reveal only appear when the action has a meaningful target for the type.

enum MaterialAction {
    static func copy(_ highlight: Highlight) {
        let pb = NSPasteboard.general
        pb.clearContents()
        if highlight.highlightType == "screenshot",
           let sid = highlight.screenshotId,
           let rec = DatabaseManager.shared.screenshot(byId: sid),
           let img = NSImage(contentsOfFile: rec.filePath) {
            pb.writeObjects([img])
            return
        }
        if let url = localFileURL(for: highlight) {
            pb.writeObjects([url as NSURL])
            return
        }
        pb.setString(highlight.contentText, forType: .string)
    }

    static func open(_ highlight: Highlight) {
        guard let url = openTarget(for: highlight) else { return }
        if highlight.highlightType == "file" {
            openFile(highlight.contentText)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    static func revealInFinder(_ highlight: Highlight) {
        guard let url = localFileURL(for: highlight) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    static func localFileURL(for highlight: Highlight) -> URL? {
        switch highlight.highlightType {
        case "screenshot":
            guard let sid = highlight.screenshotId,
                  let rec = DatabaseManager.shared.screenshot(byId: sid) else { return nil }
            return URL(fileURLWithPath: rec.filePath)
        case "recording", "file":
            let path = highlight.contentText
            return path.isEmpty ? nil : URL(fileURLWithPath: path)
        default:
            return nil
        }
    }

    static func openTarget(for highlight: Highlight) -> URL? {
        if highlight.isURLCopy {
            let s = highlight.contentText.trimmingCharacters(in: .whitespacesAndNewlines)
            return URL(string: s)
        }
        return localFileURL(for: highlight)
    }

    static func copyLabel(for highlight: Highlight) -> String {
        switch highlight.highlightType {
        case "screenshot": return "Copy Image"
        case "recording", "file": return "Copy File"
        default:
            return highlight.isURLCopy ? "Copy URL" : "Copy Text"
        }
    }

    static func openLabel(for highlight: Highlight) -> String {
        switch highlight.highlightType {
        case "recording": return "Open in QuickTime"
        default:
            return highlight.isURLCopy ? "Open in Browser" : "Open"
        }
    }

    static func openIcon(for highlight: Highlight) -> String {
        switch highlight.highlightType {
        case "recording": return "play.rectangle"
        case "file":      return "arrow.up.forward.app"
        default:          return highlight.isURLCopy ? "safari" : "arrow.up.forward.app"
        }
    }

    static func delete(_ highlight: Highlight) {
        DatabaseManager.shared.deleteHighlight(id: highlight.id)
    }

    static func shareItems(for highlight: Highlight) -> [Any] {
        if let url = localFileURL(for: highlight) { return [url] }
        if highlight.isURLCopy,
           let url = URL(string: highlight.contentText.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return [url]
        }
        return [highlight.contentText]
    }
}

// MARK: - SwiftUI modifier

struct MaterialContextMenuModifier: ViewModifier {
    let highlight: Highlight
    let cardTags: [Tag]

    func body(content: Content) -> some View {
        content.contextMenu {
            Button(action: { MaterialAction.copy(highlight) }) {
                Label(MaterialAction.copyLabel(for: highlight), systemImage: "doc.on.doc")
            }

            if MaterialAction.openTarget(for: highlight) != nil {
                Button(action: { MaterialAction.open(highlight) }) {
                    Label(MaterialAction.openLabel(for: highlight), systemImage: MaterialAction.openIcon(for: highlight))
                }
            }

            if MaterialAction.localFileURL(for: highlight) != nil {
                Button("Reveal in Finder") {
                    MaterialAction.revealInFinder(highlight)
                }
            }

            shareButton

            Divider()

            Menu("Collection") {
                ForEach(DatabaseManager.shared.allTags()) { tag in
                    let isApplied = cardTags.contains(where: { $0.id == tag.id })
                    Button(action: {
                        if isApplied {
                            DatabaseManager.shared.removeTag(tag.id, fromHighlight: highlight.id)
                        } else {
                            DatabaseManager.shared.addTag(tag.id, toHighlight: highlight.id)
                        }
                    }) {
                        HStack {
                            Text(tag.name)
                            if isApplied { Image(systemName: "checkmark") }
                        }
                    }
                }
            }

            Divider()

            Button(role: .destructive) {
                MaterialAction.delete(highlight)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private var shareButton: some View {
        if let url = MaterialAction.localFileURL(for: highlight) {
            ShareLink(item: url)
        } else if highlight.isURLCopy,
                  let url = URL(string: highlight.contentText.trimmingCharacters(in: .whitespacesAndNewlines)) {
            ShareLink(item: url)
        } else {
            ShareLink(item: highlight.contentText)
        }
    }
}

extension View {
    func materialContextMenu(for highlight: Highlight, cardTags: [Tag] = []) -> some View {
        modifier(MaterialContextMenuModifier(highlight: highlight, cardTags: cardTags))
    }
}

// MARK: - NSMenu builder (for the AppKit capture toast)

final class MaterialMenuTarget: NSObject {
    var onCopy: (() -> Void)?
    var onOpen: (() -> Void)?
    var onRevealInFinder: (() -> Void)?
    var onShare: ((NSView) -> Void)?
    var onToggleTag: ((String) -> Void)?
    var onDelete: (() -> Void)?
    var onDismiss: (() -> Void)?

    @objc func copyMaterial() { onCopy?() }
    @objc func openMaterial() { onOpen?() }
    @objc func revealInFinder() { onRevealInFinder?() }
    @objc func share(_ sender: NSMenuItem) {
        guard let view = sender.representedObject as? NSView else { return }
        onShare?(view)
    }
    @objc func toggleTag(_ sender: NSMenuItem) {
        guard let tagId = sender.representedObject as? String else { return }
        onToggleTag?(tagId)
    }
    @objc func deleteMaterial() { onDelete?() }
    @objc func dismissToast() { onDismiss?() }
}

func buildMaterialNSMenu(
    for highlight: Highlight,
    target: MaterialMenuTarget,
    anchorView: NSView,
    includeDismiss: Bool
) -> NSMenu {
    let menu = NSMenu()

    let copyItem = NSMenuItem(title: MaterialAction.copyLabel(for: highlight),
                              action: #selector(MaterialMenuTarget.copyMaterial),
                              keyEquivalent: "")
    copyItem.target = target
    copyItem.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
    menu.addItem(copyItem)

    if MaterialAction.openTarget(for: highlight) != nil {
        let openItem = NSMenuItem(title: MaterialAction.openLabel(for: highlight),
                                  action: #selector(MaterialMenuTarget.openMaterial),
                                  keyEquivalent: "")
        openItem.target = target
        openItem.image = NSImage(systemSymbolName: MaterialAction.openIcon(for: highlight), accessibilityDescription: nil)
        menu.addItem(openItem)
    }

    if MaterialAction.localFileURL(for: highlight) != nil {
        let revealItem = NSMenuItem(title: "Reveal in Finder",
                                    action: #selector(MaterialMenuTarget.revealInFinder),
                                    keyEquivalent: "")
        revealItem.target = target
        menu.addItem(revealItem)
    }

    let shareItem = NSMenuItem(title: "Share…",
                               action: #selector(MaterialMenuTarget.share(_:)),
                               keyEquivalent: "")
    shareItem.target = target
    shareItem.representedObject = anchorView
    menu.addItem(shareItem)

    menu.addItem(.separator())

    let collMenu = NSMenu()
    let applied = Set(DatabaseManager.shared.tagsForHighlight(id: highlight.id).map { $0.id })
    let tags = DatabaseManager.shared.allTags()
    if tags.isEmpty {
        let empty = NSMenuItem(title: "No collections yet", action: nil, keyEquivalent: "")
        empty.isEnabled = false
        collMenu.addItem(empty)
    } else {
        for tag in tags {
            let item = NSMenuItem(title: tag.name,
                                  action: #selector(MaterialMenuTarget.toggleTag(_:)),
                                  keyEquivalent: "")
            item.target = target
            item.representedObject = tag.id
            item.state = applied.contains(tag.id) ? .on : .off
            collMenu.addItem(item)
        }
    }
    let collItem = NSMenuItem(title: "Collection", action: nil, keyEquivalent: "")
    collItem.submenu = collMenu
    menu.addItem(collItem)

    menu.addItem(.separator())

    let deleteItem = NSMenuItem(title: "Delete",
                                action: #selector(MaterialMenuTarget.deleteMaterial),
                                keyEquivalent: "")
    deleteItem.target = target
    menu.addItem(deleteItem)

    if includeDismiss {
        menu.addItem(.separator())
        let dismissItem = NSMenuItem(title: "Dismiss",
                                     action: #selector(MaterialMenuTarget.dismissToast),
                                     keyEquivalent: "")
        dismissItem.target = target
        menu.addItem(dismissItem)
    }

    return menu
}

func presentShareMenu(for highlight: Highlight, relativeTo view: NSView) {
    let picker = NSSharingServicePicker(items: MaterialAction.shareItems(for: highlight))
    picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
}

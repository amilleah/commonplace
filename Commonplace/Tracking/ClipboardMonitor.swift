import AppKit
import Combine
import UniformTypeIdentifiers

struct ClipboardEntry: Identifiable, Codable {
    let id: UUID
    let content: String
    let timestamp: Double
    let sourceApp: String?

    var date: Date { Date(timeIntervalSince1970: timestamp) }

    init(content: String, date: Date, sourceApp: String?) {
        self.id = UUID()
        self.content = content
        self.timestamp = date.timeIntervalSince1970
        self.sourceApp = sourceApp
    }
}

final class ClipboardMonitor: ObservableObject {
    static let shared = ClipboardMonitor()

    @Published var history: [ClipboardEntry] = []

    var onCopyWithContent: ((String, String?, String, CaptureContext) -> Void)?

    private var timer: Timer?
    private var lastChangeCount: Int = 0
    private let maxHistory = 100
    private let linksFolder: URL
    private var isChecking = false

    /// Clipboard dedup — in-memory guard (Layer 1). Tracks the last contentHash
    /// we wrote and the time it was written. NSPasteboard.changeCount can fire
    /// multiple times for a single copy operation (macOS UI interactions, paste
    /// events, rapid retriggers); within this short window any repeat of the
    /// same hash is swallowed. A complementary DB-backed check (Layer 2) in
    /// DatabaseManager.recentCopyHighlightExists covers the edge case where
    /// this in-memory state has been lost (e.g. app restart mid-burst).
    private var lastWrittenHash: String?
    private var lastWrittenAt: Date?
    private let inMemoryDedupWindow: TimeInterval = 5.0
    private let dbDedupWindow: TimeInterval = 30.0

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private init() {
        linksFolder = DatabaseManager.appSupportURL
            .appendingPathComponent("links")
        try? FileManager.default.createDirectory(at: linksFolder, withIntermediateDirectories: true)
        lastChangeCount = NSPasteboard.general.changeCount
        loadTodayEntries()
    }

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkClipboard()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func copyToClipboard(_ entry: ClipboardEntry) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(entry.content, forType: .string)
        lastChangeCount = pasteboard.changeCount
    }

    private func checkClipboard() {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount

        // Image first — checked before the frontmost-app guard so clipboard
        // screenshots (Cmd+Ctrl+Shift+3/4) are captured even when Commonplace
        // has focus. Plain text copies don't carry .png/.tiff reps, so this
        // only fires on a deliberate image copy.
        if tryCaptureImage(from: pasteboard) { return }

        // Skip text copies that originated inside Commonplace itself.
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Bundle.main.bundleIdentifier {
            return
        }

        guard let content = pasteboard.string(forType: .string),
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        if let last = history.first, last.content == content { return }

        // Compute hash up front so both dedup layers can key on it.
        let hash = CaptureContext.contentHash(for: content)

        // Layer 1 — in-memory dedup. Swallow the common case where
        // NSPasteboard.changeCount bumps multiple times for a single copy.
        if let lastHash = lastWrittenHash,
           let lastAt = lastWrittenAt,
           lastHash == hash,
           Date().timeIntervalSince(lastAt) < inMemoryDedupWindow {
            return
        }

        // Layer 2 — DB safety net. Covers cases where Layer 1's in-memory
        // state was lost (app restart mid-burst) or where the same URL/text
        // bounces through the clipboard in rapid succession from a different
        // source. 30-second window is wide enough to catch out-of-process
        // duplication but short enough to preserve legitimate re-captures
        // days apart.
        if DatabaseManager.shared.recentCopyHighlightExists(
            contentHash: hash,
            withinSeconds: dbDedupWindow
        ) {
            // Update the in-memory guard so subsequent polls don't repeatedly
            // hit the DB for the same dupe burst.
            lastWrittenHash = hash
            lastWrittenAt = Date()
            return
        }

        // Gather context at the moment of copy — ephemeral data captured now
        let context = CaptureContext.current(captureClipboardTypes: true)

        let frontApp = NSWorkspace.shared.frontmostApplication?.localizedName
        let entry = ClipboardEntry(content: content, date: Date(), sourceApp: frontApp)

        DispatchQueue.main.async {
            self.history.insert(entry, at: 0)
            if self.history.count > self.maxHistory {
                self.history.removeLast()
            }
        }

        appendToMarkdown(entry)
        saveRawEntry(entry)

        let cType = CaptureContext.contentType(for: content)

        let dbEntry = ClipboardEntryRecord(
            id: entry.id.uuidString,
            timestamp: entry.timestamp,
            content: entry.content,
            sourceApp: entry.sourceApp,
            windowTitle: context.windowTitle,
            bundleId: context.bundleId,
            sourceUrl: context.sourceUrl,
            clipboardTypes: context.clipboardTypes,
            contentHash: hash,
            documentPath: context.documentPath,
            contentType: cType
        )
        DatabaseManager.shared.insertClipboardEntry(dbEntry)

        // Record this write for the in-memory dedup guard.
        lastWrittenHash = hash
        lastWrittenAt = Date()

        // Fix: use the same entry ID for both clipboard_entry and highlight records
        let entryId = entry.id.uuidString
        onCopyWithContent?(content, frontApp, entryId, context)
    }

    // MARK: - Image Capture

    /// Returns true if image bytes were found on the pasteboard and handled
    /// (either saved or deduped). When true, the caller should not fall through
    /// to the text path — image copies often carry a text representation as
    /// fallback, but we treat the image as the primary signal.
    private func tryCaptureImage(from pasteboard: NSPasteboard) -> Bool {
        guard let (imageData, _) = Self.readImageData(from: pasteboard) else { return false }

        // Dedup by raw bytes. Same Layer 1 guard as the text path — this
        // swallows changeCount multi-bumps that carry the same image.
        let hash = CaptureContext.contentHash(for: imageData)
        if let lastHash = lastWrittenHash,
           let lastAt = lastWrittenAt,
           lastHash == hash,
           Date().timeIntervalSince(lastAt) < inMemoryDedupWindow {
            return true
        }

        guard let nsImage = NSImage(data: imageData),
              let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            // Data was present but undecodable — treat as handled so we don't
            // double-process into the text path, but log it.
            CaptureLog.warning("ClipboardMonitor: image data present but failed to decode")
            return true
        }

        lastWrittenHash = hash
        lastWrittenAt = Date()

        let context = CaptureContext.current(captureClipboardTypes: true)

        Task {
            guard let result = await ScreenshotCapture.shared.saveClipboardImage(
                image: cgImage, context: context
            ) else {
                CaptureLog.error("ClipboardMonitor: saveClipboardImage failed")
                return
            }

            let toastImage = NSImage(
                cgImage: cgImage,
                size: NSSize(width: cgImage.width, height: cgImage.height)
            )

            await MainActor.run {
                HighlightCapture.shared.captureFromUserScreenshot(
                    filePath: result.filePath,
                    image: toastImage,
                    screenshotId: result.screenshotId,
                    context: result.context,
                    badgeLabel: "Pasted image"
                )
            }
        }

        return true
    }

    /// Read the first available image representation off the pasteboard.
    /// Prefers PNG (lossless, universally decodable) over TIFF. Falls back to
    /// reading the file from disk when Finder copies an image file — in that
    /// case the pasteboard carries only a file URL, not pixel data.
    private static func readImageData(from pasteboard: NSPasteboard) -> (Data, NSPasteboard.PasteboardType)? {
        // Finder file copy: check file URL first. Finder also puts a .tiff icon
        // preview on the pasteboard (lazily, so absent on the first copy but
        // present on subsequent ones). Always reading from disk ensures we
        // capture real pixels rather than the icon thumbnail on every copy.
        if let fileURLs = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL],
           let url = fileURLs.first,
           let uti = UTType(filenameExtension: url.pathExtension.lowercased()),
           uti.conforms(to: .image),
           let data = try? Data(contentsOf: url), !data.isEmpty {
            return (data, .png)
        }

        // Direct pixel data — "Copy Image" in Preview, browser, etc.
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = pasteboard.data(forType: type), !data.isEmpty {
                return (data, type)
            }
        }

        return nil
    }

    // MARK: - Markdown

    private func appendToMarkdown(_ entry: ClipboardEntry) {
        let dateString = dateFormatter.string(from: entry.date)
        let timeString = timeFormatter.string(from: entry.date)
        let fileURL = linksFolder.appendingPathComponent("\(dateString).md")

        let trimmed = entry.content.trimmingCharacters(in: .whitespacesAndNewlines)

        var line = "- **\(timeString)**"
        if let app = entry.sourceApp {
            line += " (\(app))"
        }

        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            let firstLine = trimmed.components(separatedBy: .newlines).first ?? trimmed
            line += " — [\(firstLine)](\(firstLine))"
        } else {
            let lines = trimmed.components(separatedBy: .newlines)
            if lines.count == 1 {
                line += " — \(trimmed)"
            } else {
                line += " —\n  ```\n  \(lines.joined(separator: "\n  "))\n  ```"
            }
        }
        line += "\n"

        if !FileManager.default.fileExists(atPath: fileURL.path) {
            let header = "# Clipboard — \(dateString)\n\n"
            try? header.write(to: fileURL, atomically: true, encoding: .utf8)
        }

        if let handle = try? FileHandle(forWritingTo: fileURL) {
            handle.seekToEndOfFile()
            if let data = line.data(using: .utf8) {
                handle.write(data)
            }
            handle.closeFile()
        }
    }

    // MARK: - JSON

    private func jsonFileURL(for date: Date = Date()) -> URL {
        let dateString = dateFormatter.string(from: date)
        return linksFolder.appendingPathComponent(".\(dateString).json")
    }

    private func saveRawEntry(_ entry: ClipboardEntry) {
        let fileURL = jsonFileURL()
        var entries = loadRawEntries(from: fileURL)
        entries.append(entry)
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: fileURL)
        }
    }

    private func loadRawEntries(from url: URL) -> [ClipboardEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([ClipboardEntry].self, from: data)) ?? []
    }

    private func loadTodayEntries() {
        let entries = loadRawEntries(from: jsonFileURL())
        history = entries.reversed()
    }
}

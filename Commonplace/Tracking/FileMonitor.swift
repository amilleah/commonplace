import Foundation
import UniformTypeIdentifiers
import QuickLookThumbnailing
import AppKit
import PDFKit
import AVFoundation

final class FileMonitor {
    static let shared = FileMonitor()

    private static let watchedFoldersKey = "fileMonitorWatchedFolders"
    private static let defaultFolders = [
        NSHomeDirectory() + "/Downloads",
        NSHomeDirectory() + "/Desktop"
    ]

    private var watchers: [String: FolderWatcher] = [:]
    private let db = DatabaseManager.shared

    private static let thumbnailsURL: URL = {
        let url = DatabaseManager.appSupportURL.appendingPathComponent("thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private static let filesURL: URL = {
        let url = DatabaseManager.appSupportURL.appendingPathComponent("files", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    // MARK: - Public API

    var watchedFolders: [String] {
        UserDefaults.standard.stringArray(forKey: Self.watchedFoldersKey) ?? Self.defaultFolders
    }

    private static let desktopMigrationKey = "fileMonitorDesktopMigrated"

    func start() {
        // One-time migration: add Desktop to existing installs that only had Downloads
        if !UserDefaults.standard.bool(forKey: Self.desktopMigrationKey) {
            UserDefaults.standard.set(true, forKey: Self.desktopMigrationKey)
            let desktop = NSHomeDirectory() + "/Desktop"
            if let saved = UserDefaults.standard.stringArray(forKey: Self.watchedFoldersKey),
               !saved.contains(desktop) {
                var updated = saved
                updated.append(desktop)
                UserDefaults.standard.set(updated, forKey: Self.watchedFoldersKey)
            }
        }

        let folders = watchedFolders
        for folder in folders {
            startWatching(folder)
        }
        CaptureLog.info("FileMonitor started watching \(folders.count) folder(s)")
    }

    func stop() {
        for (_, watcher) in watchers {
            watcher.stop()
        }
        watchers.removeAll()
    }

    func addFolder(_ path: String) {
        var folders = watchedFolders
        guard !folders.contains(path) else { return }
        folders.append(path)
        UserDefaults.standard.set(folders, forKey: Self.watchedFoldersKey)
        startWatching(path)
    }

    func removeFolder(_ path: String) {
        var folders = watchedFolders
        folders.removeAll { $0 == path }
        UserDefaults.standard.set(folders, forKey: Self.watchedFoldersKey)
        watchers[path]?.stop()
        watchers.removeValue(forKey: path)
    }

    // MARK: - Watching

    private func startWatching(_ path: String) {
        guard watchers[path] == nil else { return }
        guard FileManager.default.fileExists(atPath: path) else {
            CaptureLog.warning("FileMonitor: folder does not exist: \(path)")
            return
        }

        let watcher = FolderWatcher(path: path) { [weak self] filePath, sourceFolder in
            self?.processNewFile(filePath: filePath, sourceFolder: sourceFolder)
        }
        watcher.start()
        watchers[path] = watcher
    }

    // MARK: - Manual Import (drag-and-drop)

    /// Ingest an arbitrary file the user explicitly chose (drag-and-drop, open panel, etc.).
    /// Copies to persistent storage, creates a FileRecord + Highlight, and generates a thumbnail.
    /// Uses the current time as the capture timestamp, regardless of the source file's metadata.
    /// `tagIds` — apply these tags to the new highlight after insertion. Used by the Browse
    /// "+" tile / drop handler to inherit the current collection filter.
    func importFile(from sourceURL: URL, tagIds: [String] = []) async {
        guard let record = await ingestFile(
            from: sourceURL,
            sourceFolder: "Drag & Drop",
            logTag: "imported via drag-and-drop"
        ) else { return }

        let thumbImage: NSImage? = record.thumbnailPath.flatMap { NSImage(contentsOfFile: $0) }

        await MainActor.run {
            HighlightCapture.shared.captureFromFileDetection(
                fileRecord: record, thumbnailImage: thumbImage, tagIds: tagIds
            )
        }
    }

    /// Ingest a file downloaded from a URL without creating a new Highlight —
    /// the caller (URLFileDownloader) attaches the resulting FileRecord to an
    /// existing copy-type highlight. Returns the populated FileRecord on success.
    ///
    /// The source file is **moved** (not copied) into persistent storage so we
    /// don't pay for two writes of the same bytes. Only safe because the caller
    /// owns `sourceURL` (URLSession's temp file).
    func importDownloadedFile(
        from sourceURL: URL,
        displayFilename: String?,
        originalUrl: String
    ) async -> FileRecord? {
        return await ingestFile(
            from: sourceURL,
            sourceFolder: "Downloaded Link",
            overrideFilename: displayFilename,
            originalUrl: originalUrl,
            moveInsteadOfCopy: true,
            logTag: "downloaded from link"
        )
    }

    /// Shared implementation for importFile / importDownloadedFile.
    /// Places sourceURL into files/{dayString}/ (copying or moving), inserts
    /// a FileRecord, and generates a thumbnail. Does NOT create a Highlight.
    private func ingestFile(
        from sourceURL: URL,
        sourceFolder: String,
        overrideFilename: String? = nil,
        originalUrl: String? = nil,
        moveInsteadOfCopy: Bool = false,
        logTag: String
    ) async -> FileRecord? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: sourceURL.path) else { return nil }
        guard let attrs = try? fm.attributesOfItem(atPath: sourceURL.path) else { return nil }
        let fileSize = (attrs[.size] as? Int64) ?? 0
        let creationDate = (attrs[.creationDate] as? Date)?.timeIntervalSince1970

        let chosenName = overrideFilename ?? sourceURL.lastPathComponent
        let ext = (chosenName as NSString).pathExtension.lowercased()
        let uti = UTType(filenameExtension: ext)?.identifier
        let contentType = Self.contentTypeCategory(from: ext, uti: uti)
        let now = Date()
        let dayString = ScreenshotCapture.dayString(for: now)

        let filesDir = Self.filesURL.appendingPathComponent(dayString)
        try? fm.createDirectory(at: filesDir, withIntermediateDirectories: true)

        var destURL = filesDir.appendingPathComponent(chosenName)
        if fm.fileExists(atPath: destURL.path) {
            let stem = (chosenName as NSString).deletingPathExtension
            let suffix = String(UUID().uuidString.prefix(6))
            destURL = filesDir.appendingPathComponent(ext.isEmpty ? "\(stem)-\(suffix)" : "\(stem)-\(suffix).\(ext)")
        }

        let persistentPath: String
        do {
            if moveInsteadOfCopy {
                try fm.moveItem(at: sourceURL, to: destURL)
            } else {
                try fm.copyItem(at: sourceURL, to: destURL)
            }
            persistentPath = destURL.path
            CaptureLog.info("FileMonitor: \(logTag): \(chosenName)")
        } catch {
            CaptureLog.warning("FileMonitor: ingest failed (\(logTag)): \(error.localizedDescription)")
            // If a move across volumes fails, fall back to copy.
            if moveInsteadOfCopy {
                do {
                    try fm.copyItem(at: sourceURL, to: destURL)
                    try? fm.removeItem(at: sourceURL)
                    persistentPath = destURL.path
                    CaptureLog.info("FileMonitor: \(logTag) (fallback copy): \(chosenName)")
                } catch {
                    CaptureLog.warning("FileMonitor: ingest fallback copy failed: \(error.localizedDescription)")
                    return nil
                }
            } else {
                return nil
            }
        }

        let pageCount: Int? = if contentType == "pdf" {
            PDFDocument(url: URL(fileURLWithPath: persistentPath))?.pageCount
        } else {
            nil
        }

        var record = FileRecord(
            id: nil,
            timestamp: now.timeIntervalSince1970,
            dayString: dayString,
            filePath: persistentPath,
            fileName: chosenName,
            fileSize: fileSize,
            uti: uti,
            contentType: contentType,
            thumbnailPath: nil,
            sourceFolder: sourceFolder,
            creationDate: creationDate,
            fileExtension: ext.isEmpty ? nil : ext,
            pageCount: pageCount,
            originalUrl: originalUrl
        )

        db.insertFileRecord(&record)

        let thumbPath = await generateThumbnail(for: URL(fileURLWithPath: persistentPath), dayString: dayString)
        if let thumbPath, let recordId = record.id {
            db.updateFileRecordThumbnail(id: recordId, thumbnailPath: thumbPath)
            record.thumbnailPath = thumbPath
        }

        return record
    }

    // MARK: - Processing

    private func processNewFile(filePath: String, sourceFolder: String) {
        // Dedup check
        guard db.fileRecordByPath(filePath) == nil else { return }

        let url = URL(fileURLWithPath: filePath)
        let fm = FileManager.default

        guard let attrs = try? fm.attributesOfItem(atPath: filePath) else { return }
        let fileSize = (attrs[.size] as? Int64) ?? 0
        let creationDate = (attrs[.creationDate] as? Date)?.timeIntervalSince1970

        let ext = url.pathExtension.lowercased()
        let fileName = url.lastPathComponent
        let uti = UTType(filenameExtension: ext)?.identifier
        let contentType = Self.contentTypeCategory(from: ext, uti: uti)
        let now = Date()
        let dayString = ScreenshotCapture.dayString(for: now)

        // Copy file to persistent storage
        let filesDir = Self.filesURL.appendingPathComponent(dayString)
        try? fm.createDirectory(at: filesDir, withIntermediateDirectories: true)

        var destURL = filesDir.appendingPathComponent(fileName)
        if fm.fileExists(atPath: destURL.path) {
            let stem = url.deletingPathExtension().lastPathComponent
            let suffix = String(UUID().uuidString.prefix(6))
            destURL = filesDir.appendingPathComponent(ext.isEmpty ? "\(stem)-\(suffix)" : "\(stem)-\(suffix).\(ext)")
        }

        let persistentPath: String
        do {
            try fm.copyItem(at: url, to: destURL)
            persistentPath = destURL.path
            CaptureLog.info("FileMonitor: copied \(fileName) to persistent storage")
        } catch {
            CaptureLog.warning("FileMonitor: copy failed, using original path: \(error.localizedDescription)")
            persistentPath = filePath
        }

        // Get page count for PDFs
        let pageCount: Int? = if contentType == "pdf" {
            PDFDocument(url: URL(fileURLWithPath: persistentPath))?.pageCount
        } else {
            nil
        }

        var record = FileRecord(
            id: nil,
            timestamp: now.timeIntervalSince1970,
            dayString: dayString,
            filePath: persistentPath,
            fileName: fileName,
            fileSize: fileSize,
            uti: uti,
            contentType: contentType,
            thumbnailPath: nil,
            sourceFolder: sourceFolder,
            creationDate: creationDate,
            fileExtension: ext.isEmpty ? nil : ext,
            pageCount: pageCount
        )

        db.insertFileRecord(&record)

        // Generate thumbnail from the persistent copy, then hand off to HighlightCapture
        let thumbSourceURL = URL(fileURLWithPath: persistentPath)
        Task {
            let thumbPath = await generateThumbnail(for: thumbSourceURL, dayString: dayString)
            if let thumbPath, let recordId = record.id {
                db.updateFileRecordThumbnail(id: recordId, thumbnailPath: thumbPath)
                record.thumbnailPath = thumbPath
            }

            let thumbImage: NSImage? = if let thumbPath { NSImage(contentsOfFile: thumbPath) } else { nil }

            await MainActor.run {
                HighlightCapture.shared.captureFromFileDetection(fileRecord: record, thumbnailImage: thumbImage)
            }
        }

        CaptureLog.info("FileMonitor: captured \(fileName) (\(RecordingRecord.formatFileSize(fileSize))) from \(sourceFolder)")
    }

    // MARK: - Thumbnail

    private func generateThumbnail(for fileURL: URL, dayString: String) async -> String? {
        let thumbDir = Self.thumbnailsURL.appendingPathComponent(dayString)
        try? FileManager.default.createDirectory(at: thumbDir, withIntermediateDirectories: true)

        let ext = fileURL.pathExtension.lowercased()

        // PDFs: render first page via PDFKit
        if ext == "pdf" {
            return generatePDFThumbnail(for: fileURL, thumbDir: thumbDir)
        }

        // Images: load and resize directly for best quality
        let imageExts: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "tiff", "tif", "bmp"]
        if imageExts.contains(ext) {
            return generateImageThumbnail(for: fileURL, thumbDir: thumbDir)
        }

        // Videos: extract a frame via AVFoundation
        let videoExts: Set<String> = ["mp4", "mov", "avi", "mkv", "webm", "m4v"]
        if videoExts.contains(ext) {
            return await generateVideoThumbnail(for: fileURL, thumbDir: thumbDir)
        }

        // Everything else: QuickLook
        let request = QLThumbnailGenerator.Request(
            fileAt: fileURL,
            size: CGSize(width: 480, height: 480),
            scale: 2.0,
            representationTypes: .thumbnail
        )

        do {
            let thumbnail = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            return saveCGImage(thumbnail.cgImage, to: thumbDir)
        } catch {
            CaptureLog.info("FileMonitor: no thumbnail for \(fileURL.lastPathComponent): \(error.localizedDescription)")
            return nil
        }
    }

    private func generatePDFThumbnail(for fileURL: URL, thumbDir: URL) -> String? {
        guard let doc = PDFDocument(url: fileURL),
              let page = doc.page(at: 0) else { return nil }

        let pageRect = page.bounds(for: .mediaBox)
        let scale: CGFloat = 600.0 / max(pageRect.width, 1)
        let renderSize = CGSize(width: pageRect.width * scale, height: pageRect.height * scale)

        let image = page.thumbnail(of: renderSize, for: .mediaBox)
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

        return saveCGImage(cgImage, to: thumbDir)
    }

    private func generateImageThumbnail(for fileURL: URL, thumbDir: URL) -> String? {
        guard let imageSource = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else { return nil }

        // Resize to max 600px on longest side
        let w = CGFloat(cgImage.width)
        let h = CGFloat(cgImage.height)
        let maxDim: CGFloat = 600
        let scale = min(maxDim / max(w, 1), maxDim / max(h, 1), 1.0)
        let newW = Int(w * scale)
        let newH = Int(h * scale)

        guard let ctx = CGContext(
            data: nil, width: newW, height: newH,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return saveCGImage(cgImage, to: thumbDir) }

        ctx.interpolationQuality = .high
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: newW, height: newH))
        guard let resized = ctx.makeImage() else { return saveCGImage(cgImage, to: thumbDir) }
        return saveCGImage(resized, to: thumbDir)
    }

    private func generateVideoThumbnail(for fileURL: URL, thumbDir: URL) async -> String? {
        let asset = AVURLAsset(url: fileURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 600, height: 600)

        do {
            let (cgImage, _) = try await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600))
            return saveCGImage(cgImage, to: thumbDir)
        } catch {
            // Try frame at 0 if 1s fails (very short videos)
            do {
                let (cgImage, _) = try await generator.image(at: .zero)
                return saveCGImage(cgImage, to: thumbDir)
            } catch {
                CaptureLog.info("FileMonitor: no video thumbnail for \(fileURL.lastPathComponent)")
                return nil
            }
        }
    }

    private func saveCGImage(_ cgImage: CGImage, to directory: URL) -> String? {
        let thumbFile = directory.appendingPathComponent(UUID().uuidString + ".jpg")
        guard let dest = CGImageDestinationCreateWithURL(
            thumbFile as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(dest, cgImage, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return thumbFile.path
    }

    // MARK: - Content Type Mapping

    private static func contentTypeCategory(from ext: String, uti: String?) -> String {
        // Check extension first for common types
        switch ext {
        case "pdf": return "pdf"
        case "jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "tiff", "bmp", "svg": return "image"
        case "mp4", "mov", "avi", "mkv", "webm", "m4v": return "video"
        case "mp3", "wav", "aac", "flac", "m4a", "ogg": return "audio"
        case "epub", "mobi", "azw", "azw3", "ibooks": return "ebook"
        case "zip", "gz", "tar", "rar", "7z", "bz2", "xz", "dmg": return "archive"
        case "doc", "docx", "odt", "rtf", "pages": return "document"
        case "xls", "xlsx", "csv", "numbers": return "spreadsheet"
        case "ppt", "pptx", "key": return "presentation"
        case "txt", "md", "json", "xml", "yaml", "yml", "log": return "text"
        case "swift", "py", "js", "ts", "html", "css", "rb", "go", "rs", "c", "cpp", "h", "java": return "code"
        case "ttf", "otf", "woff", "woff2": return "font"
        case "app": return "app"
        default: break
        }

        // Fall back to UTI hierarchy
        guard let uti, let utType = UTType(uti) else { return "file" }
        if utType.conforms(to: .image) { return "image" }
        if utType.conforms(to: .movie) || utType.conforms(to: .video) { return "video" }
        if utType.conforms(to: .audio) { return "audio" }
        if utType.conforms(to: .archive) { return "archive" }
        if utType.conforms(to: .sourceCode) { return "code" }
        if utType.conforms(to: .text) || utType.conforms(to: .plainText) { return "text" }
        if utType.conforms(to: .spreadsheet) { return "spreadsheet" }
        if utType.conforms(to: .presentation) { return "presentation" }
        if utType.conforms(to: .font) { return "font" }

        return "file"
    }
}

// MARK: - FolderWatcher

private final class FolderWatcher {
    let path: String
    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private var knownFiles: Set<String> = []
    private var pendingFiles: [String: PendingFile] = [:]
    private var debounceTimer: Timer?
    private let onNewFile: (String, String) -> Void

    private static let skipExtensions: Set<String> = [
        "crdownload", "download", "part", "tmp", "partial", "opdownload"
    ]

    // A single sweep that turns up more candidates than this is almost
    // certainly a bulk move/unzip/restore/sync — not user-intent capture.
    // Ingesting 2,700 old files at once is a much worse failure than
    // skipping a legit 50-file download.
    private static let bulkArrivalThreshold = 50

    struct PendingFile {
        let detectedAt: Date
        var lastSize: Int64
        var stableCount: Int
    }

    init(path: String, onNewFile: @escaping (String, String) -> Void) {
        self.path = path
        self.onNewFile = onNewFile
    }

    func start() {
        // Snapshot existing files
        knownFiles = Set(contentsOfDirectory() ?? [])

        fileDescriptor = open(path, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            CaptureLog.warning("FileMonitor: cannot open \(path) for monitoring")
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: .write,
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.checkForNewFiles()
        }
        source.setCancelHandler { [weak self] in
            if let fd = self?.fileDescriptor, fd >= 0 {
                close(fd)
                self?.fileDescriptor = -1
            }
        }
        source.resume()
        self.source = source
    }

    func stop() {
        debounceTimer?.invalidate()
        debounceTimer = nil
        source?.cancel()
        source = nil
        pendingFiles.removeAll()
    }

    private func checkForNewFiles() {
        guard let currentFiles = contentsOfDirectory() else { return }
        let currentSet = Set(currentFiles)
        let newFiles = currentSet.subtracting(knownFiles)

        var candidates: [String] = []
        for fileName in newFiles {
            // Skip hidden files
            guard !fileName.hasPrefix(".") else {
                knownFiles.insert(fileName)
                continue
            }
            // Skip temp files
            guard !fileName.contains("~") else {
                knownFiles.insert(fileName)
                continue
            }
            // Skip partial downloads
            let ext = (fileName as NSString).pathExtension.lowercased()
            guard !Self.skipExtensions.contains(ext) else { continue }

            candidates.append(fileName)
        }

        // Bulk-arrival guard: unzip/restore/sync/Time Machine can drop
        // thousands of files into a watched folder at once. Mark them seen
        // so we don't keep re-processing, and skip capture.
        if candidates.count > Self.bulkArrivalThreshold {
            CaptureLog.warning(
                "FileMonitor: bulk arrival in \(path) — \(candidates.count) files detected in one sweep, skipping capture"
            )
            knownFiles.formUnion(currentSet)
            return
        }

        for fileName in candidates {
            let fullPath = (path as NSString).appendingPathComponent(fileName)
            let size = fileSize(at: fullPath) ?? 0

            pendingFiles[fileName] = PendingFile(
                detectedAt: Date(),
                lastSize: size,
                stableCount: 0
            )
        }

        // Also add newly appeared files to known set so we don't re-detect them
        knownFiles.formUnion(currentSet)

        // Start debounce timer if we have pending files
        if !pendingFiles.isEmpty && debounceTimer == nil {
            debounceTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.checkPendingFiles()
            }
        }
    }

    private func checkPendingFiles() {
        var completed: [String] = []

        for (fileName, var pending) in pendingFiles {
            let fullPath = (path as NSString).appendingPathComponent(fileName)
            guard let currentSize = fileSize(at: fullPath) else {
                // File disappeared
                completed.append(fileName)
                continue
            }

            if currentSize == pending.lastSize {
                pending.stableCount += 1
            } else {
                pending.lastSize = currentSize
                pending.stableCount = 0
            }

            pendingFiles[fileName] = pending

            if pending.stableCount >= 3 && currentSize > 0 {
                // File is stable — process it
                completed.append(fileName)
                onNewFile(fullPath, path)
            } else if Date().timeIntervalSince(pending.detectedAt) > 1800 {
                // Timeout — skip
                completed.append(fileName)
                CaptureLog.info("FileMonitor: timeout waiting for \(fileName)")
            }
        }

        for name in completed {
            pendingFiles.removeValue(forKey: name)
        }

        if pendingFiles.isEmpty {
            debounceTimer?.invalidate()
            debounceTimer = nil
        }
    }

    private func contentsOfDirectory() -> [String]? {
        try? FileManager.default.contentsOfDirectory(atPath: path)
    }

    private func fileSize(at path: String) -> Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        return attrs[.size] as? Int64
    }
}

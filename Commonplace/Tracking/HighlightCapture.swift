import AppKit

extension Notification.Name {
    /// Posted after a new highlight (copy, screenshot, recording, etc.) is saved to the database.
    static let highlightDidSave = Notification.Name("highlightDidSave")

    /// Posted after a user-driven edit mutates an existing highlight
    /// (tag add/remove, note add/remove, userNote update). Observers
    /// should refresh their cached state for the affected row.
    /// userInfo:
    ///   - "highlightId": String — the row that changed
    ///   - "change": String — one of "tags", "notes", "userNote"
    static let highlightDataDidChange = Notification.Name("highlightDataDidChange")

    /// Posted after a highlight and all its associated data are permanently deleted.
    /// userInfo: ["highlightId": String]
    static let highlightDidDelete = Notification.Name("highlightDidDelete")
}

final class HighlightCapture {
    static let shared = HighlightCapture()

    private let db = DatabaseManager.shared

    // MARK: - Recording Capture

    func captureFromRecording(result: ScreenRecordingCapture.RecordingResult) {
        let entryId = UUID().uuidString
        let fileURL = URL(fileURLWithPath: result.filePath)
        let filename = fileURL.lastPathComponent
        let appName = result.context.sourceAppName ?? "Recording"

        let highlight = Highlight(
            id: entryId,
            timestamp: Date().timeIntervalSince1970,
            contentText: result.filePath,
            sourceApp: appName,
            sourceUrl: result.context.sourceUrl,
            userNote: nil,
            highlightType: "recording",
            screenshotId: nil,
            recordingId: result.recordingId,
            fileId: nil,
            windowTitle: result.context.windowTitle,
            bundleId: result.context.bundleId,
            contentHash: nil,
            documentPath: result.filePath,
            contentType: nil,
            displayName: result.context.displayName,
            displayResolution: result.context.displayResolution,
            appearanceMode: result.context.appearanceMode,
            wifiNetwork: result.context.wifiNetwork
        )
        db.insertHighlight(highlight)
        NotificationCenter.default.post(name: .highlightDidSave, object: nil)

        let entry = AnnotationEntry(
            id: entryId,
            content: result.filePath,
            timestamp: Date().timeIntervalSince1970,
            sourceApp: appName,
            type: "recording",
            annotation: nil
        )
        AnnotationStore.shared.save(entry)

        let durationStr = String(format: "%.0fs", result.duration)
        let sizeStr = RecordingRecord.formatFileSize(result.fileSize)
        let toastContent = "\(filename) · \(durationStr) · \(sizeStr)"

        if let thumbImage = NSImage(contentsOfFile: result.thumbnailPath) {
            CopyToastController.shared.show(
                image: thumbImage,
                content: toastContent,
                filePath: result.filePath,
                badgeLabel: "Recording",
                entryId: entryId,
                sourceUrl: result.context.sourceUrl,
                sourceApp: appName,
                windowTitle: result.context.windowTitle
            ) { [weak self] id, note in
                AnnotationStore.shared.updateAnnotation(id: id, note: note)
                self?.db.addNoteToHighlight(highlightId: entryId, body: note)
            }
        } else {
            CopyToastController.shared.show(
                content: toastContent,
                entryId: entryId,
                sourceUrl: result.context.sourceUrl,
                sourceApp: appName,
                windowTitle: result.context.windowTitle
            ) { [weak self] id, note in
                AnnotationStore.shared.updateAnnotation(id: id, note: note)
                self?.db.addNoteToHighlight(highlightId: entryId, body: note)
            }
        }

        CaptureLog.info("Saved recording: \(result.filePath), duration: \(String(format: "%.1f", result.duration))s")
    }

    // MARK: - Copy Capture

    func captureFromCopy(content: String, sourceApp: String?, entryId: String, context: CaptureContext) {
        captureAndShow(content: content, type: "copy", sourceApp: sourceApp, entryId: entryId, context: context)
    }

    func captureFromUserScreenshot(filePath: String, image: NSImage, screenshotId: Int64?, context: CaptureContext, badgeLabel: String = "Screenshot") {
        let entryId = UUID().uuidString
        let filename = URL(fileURLWithPath: filePath).lastPathComponent
        let appName = context.sourceAppName

        let highlightId = saveHighlight(
            content: filePath, type: "screenshot", sourceApp: appName,
            entryId: entryId, screenshotId: screenshotId, context: context
        )

        let entry = AnnotationEntry(
            id: entryId,
            content: filePath,
            timestamp: Date().timeIntervalSince1970,
            sourceApp: appName,
            type: "screenshot",
            annotation: nil
        )
        AnnotationStore.shared.save(entry)

        CopyToastController.shared.show(image: image, content: filename, filePath: filePath, badgeLabel: badgeLabel, entryId: entryId, sourceUrl: context.sourceUrl, sourceApp: appName, windowTitle: context.windowTitle) { [weak self] id, note in
            AnnotationStore.shared.updateAnnotation(id: id, note: note)
            self?.db.addNoteToHighlight(highlightId: highlightId, body: note)
        }
    }

    private func captureAndShow(content: String, type: String, sourceApp: String?, entryId: String, context: CaptureContext) {
        let highlightId = saveHighlight(
            content: content, type: type, sourceApp: sourceApp,
            entryId: entryId, screenshotId: nil, context: context
        )

        let entry = AnnotationEntry(
            id: entryId,
            content: content,
            timestamp: Date().timeIntervalSince1970,
            sourceApp: sourceApp,
            type: type,
            annotation: nil
        )
        AnnotationStore.shared.save(entry)

        CopyToastController.shared.show(content: content, entryId: entryId, sourceUrl: context.sourceUrl, sourceApp: sourceApp, windowTitle: context.windowTitle) { [weak self] id, note in
            AnnotationStore.shared.updateAnnotation(id: id, note: note)
            self?.db.addNoteToHighlight(highlightId: highlightId, body: note)
        }

        // If the user copied a URL that points to a file (PDF, image, video…),
        // download it in the background and attach it to this highlight. The
        // highlight stays type "copy" — the detail view decides to show a file
        // preview when fileId gets populated.
        if type == "copy" && URLFileDownloader.isLikelyFileURL(content) {
            Task.detached(priority: .utility) {
                await URLFileDownloader.shared.downloadIfFile(
                    urlString: content,
                    attachTo: highlightId
                )
            }
        }
    }

    @discardableResult
    private func saveHighlight(content: String, type: String, sourceApp: String?, entryId: String, screenshotId: Int64?, context: CaptureContext) -> String {
        let hash = (type != "screenshot") ? CaptureContext.contentHash(for: content) : nil
        let cType = (type != "screenshot") ? CaptureContext.contentType(for: content) : nil

        let highlight = Highlight(
            id: entryId,
            timestamp: Date().timeIntervalSince1970,
            contentText: content,
            sourceApp: sourceApp,
            sourceUrl: context.sourceUrl,
            userNote: nil,
            highlightType: type,
            screenshotId: screenshotId,
            recordingId: nil,
            fileId: nil,
            windowTitle: context.windowTitle,
            bundleId: context.bundleId,
            contentHash: hash,
            documentPath: context.documentPath,
            contentType: cType,
            displayName: context.displayName,
            displayResolution: context.displayResolution,
            appearanceMode: context.appearanceMode,
            wifiNetwork: context.wifiNetwork
        )
        db.insertHighlight(highlight)

        CaptureLog.info("Saved highlight: \(type), id: \(entryId), window: \(context.windowTitle ?? "nil"), bundle: \(context.bundleId ?? "nil")")

        NotificationCenter.default.post(name: .highlightDidSave, object: nil)
        return entryId
    }

    // MARK: - File Detection

    func captureFromFileDetection(fileRecord: FileRecord, thumbnailImage: NSImage?, tagIds: [String] = []) {
        let entryId = UUID().uuidString
        let filePath = fileRecord.filePath
        let fileName = fileRecord.fileName

        let highlight = Highlight(
            id: entryId,
            timestamp: fileRecord.timestamp,
            contentText: filePath,
            sourceApp: nil,
            sourceUrl: nil,
            userNote: nil,
            highlightType: "file",
            screenshotId: nil,
            recordingId: nil,
            fileId: fileRecord.id,
            windowTitle: fileName,
            bundleId: nil,
            contentHash: nil,
            documentPath: filePath,
            contentType: fileRecord.contentType,
            displayName: nil,
            displayResolution: nil,
            appearanceMode: nil,
            wifiNetwork: nil
        )
        db.insertHighlight(highlight)
        for tagId in tagIds {
            db.addTag(tagId, toHighlight: entryId)
        }
        NotificationCenter.default.post(name: .highlightDidSave, object: nil)

        let entry = AnnotationEntry(
            id: entryId,
            content: filePath,
            timestamp: fileRecord.timestamp,
            sourceApp: nil,
            type: "file",
            annotation: nil
        )
        AnnotationStore.shared.save(entry)

        let sizeStr = fileRecord.formattedFileSize
        let typeStr = fileRecord.contentType ?? fileRecord.fileExtension?.uppercased() ?? "File"
        let toastContent = "\(fileName) · \(sizeStr) · \(typeStr)"

        if let thumbImage = thumbnailImage {
            CopyToastController.shared.show(
                image: thumbImage,
                content: toastContent,
                filePath: filePath,
                badgeLabel: "File",
                entryId: entryId
            ) { [weak self] id, note in
                AnnotationStore.shared.updateAnnotation(id: id, note: note)
                self?.db.addNoteToHighlight(highlightId: entryId, body: note)
            }
        } else {
            CopyToastController.shared.show(
                content: toastContent,
                entryId: entryId
            ) { [weak self] id, note in
                AnnotationStore.shared.updateAnnotation(id: id, note: note)
                self?.db.addNoteToHighlight(highlightId: entryId, body: note)
            }
        }

        CaptureLog.info("Captured file: \(fileName) (\(sizeStr)) from \(fileRecord.sourceFolder)")
    }

    // MARK: - Manual Add (+ tile in Browse)

    /// User typed or pasted text into the Browse "+" tile. Saves as a "note"
    /// highlight with minimal context (no source app, no window title — user-
    /// initiated, not observed), then applies any tagIds that represent the
    /// current Browse filter so the new item appears in the space the user
    /// was viewing.
    @discardableResult
    func captureFromUserAdd(text: String, tagIds: [String]) -> String {
        let highlightId = UUID().uuidString
        let highlight = Highlight(
            id: highlightId,
            timestamp: Date().timeIntervalSince1970,
            contentText: text,
            sourceApp: nil,
            sourceUrl: nil,
            userNote: nil,
            highlightType: "note",
            screenshotId: nil,
            recordingId: nil,
            fileId: nil,
            windowTitle: nil,
            bundleId: nil,
            contentHash: CaptureContext.contentHash(for: text),
            documentPath: nil,
            contentType: CaptureContext.contentType(for: text),
            displayName: nil,
            displayResolution: nil,
            appearanceMode: nil,
            wifiNetwork: nil
        )
        db.insertHighlight(highlight)
        for tagId in tagIds {
            db.addTag(tagId, toHighlight: highlightId)
        }
        NotificationCenter.default.post(name: .highlightDidSave, object: nil)
        return highlightId
    }

    /// User pasted a URL into the Browse "+" tile. Saves as a "copy" highlight
    /// (so the Browse grid renders it via LinkCard and link-preview fetch
    /// kicks in). Also triggers URLFileDownloader when the URL looks like a
    /// direct file link, matching captureFromCopy's behavior for clipboard URLs.
    @discardableResult
    func captureFromUserAddURL(urlString: String, tagIds: [String]) -> String {
        let highlightId = UUID().uuidString
        let highlight = Highlight(
            id: highlightId,
            timestamp: Date().timeIntervalSince1970,
            contentText: urlString,
            sourceApp: nil,
            sourceUrl: nil,
            userNote: nil,
            highlightType: "copy",
            screenshotId: nil,
            recordingId: nil,
            fileId: nil,
            windowTitle: nil,
            bundleId: nil,
            contentHash: CaptureContext.contentHash(for: urlString),
            documentPath: nil,
            contentType: "url",
            displayName: nil,
            displayResolution: nil,
            appearanceMode: nil,
            wifiNetwork: nil
        )
        db.insertHighlight(highlight)
        for tagId in tagIds {
            db.addTag(tagId, toHighlight: highlightId)
        }
        NotificationCenter.default.post(name: .highlightDidSave, object: nil)

        if URLFileDownloader.isLikelyFileURL(urlString) {
            Task.detached(priority: .utility) {
                await URLFileDownloader.shared.downloadIfFile(
                    urlString: urlString, attachTo: highlightId
                )
            }
        }

        return highlightId
    }
}

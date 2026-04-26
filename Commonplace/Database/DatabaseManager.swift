import Foundation
import GRDB

final class DatabaseManager {
    static let shared = DatabaseManager()

    private(set) var dbQueue: DatabaseQueue?
    private(set) var isDegraded: Bool = false

    private static let oldDesktopURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Desktop/capture", isDirectory: true)

    private static func migrateFromDesktopIfNeeded() {
        let fm = FileManager.default

        // Skip if old location doesn't exist or new location already has a database
        guard fm.fileExists(atPath: oldDesktopURL.path),
              !fm.fileExists(atPath: appSupportURL.appendingPathComponent("capture.sqlite").path)
        else { return }

        // Move each item from old directory to new
        if let contents = try? fm.contentsOfDirectory(at: oldDesktopURL, includingPropertiesForKeys: nil) {
            for item in contents {
                let dest = appSupportURL.appendingPathComponent(item.lastPathComponent)
                try? fm.moveItem(at: item, to: dest)
            }
        }

        // Remove old directory if empty
        try? fm.removeItem(at: oldDesktopURL)
    }

    private init() {
        Self.migrateFromDesktopIfNeeded()

        let dbDirectory = Self.appSupportURL
        try? FileManager.default.createDirectory(at: dbDirectory, withIntermediateDirectories: true)
        let dbFile = dbDirectory.appendingPathComponent("capture.sqlite")

        // Remove stale WAL/SHM files that can cause "invalid reuse" errors
        // after a crash left the database in a dirty state.
        Self.cleanStaleLockFiles(for: dbFile)

        // Safety backup before migrations — protects against data loss if a migration fails
        DatabaseBackupManager.shared.backupNow(label: "pre-migrate")

        if let queue = Self.openAndMigrate(path: dbFile.path) {
            self.dbQueue = queue
            rewriteScreenshotPaths(
                from: Self.oldDesktopURL.path,
                to: Self.appSupportURL.path
            )
            CaptureLog.info("Database initialized at \(dbFile.path)")
        } else {
            // First attempt failed — back up the corrupt database and try fresh
            CaptureLog.error("Database initialization failed — attempting recovery")
            if let recovered = Self.attemptRecovery() {
                self.dbQueue = recovered
                CaptureLog.info("Database recovered successfully after backup")
            } else {
                self.isDegraded = true
                CaptureLog.error("Database recovery failed — running in degraded mode (no persistence)")
            }
        }
    }

    /// Open the database and run all migrations. Returns nil on any failure.
    private static func openAndMigrate(path: String) -> DatabaseQueue? {
        do {
            let queue = try DatabaseQueue(path: path)

            // Fix FK orphans before migrations run. The v13 dedup migration can
            // leave behind highlight_note rows pointing at deleted highlights,
            // which causes GRDB's FK integrity check to fail on later migrations.
            try queue.write { db in
                let tables = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table'")
                if tables.contains("highlight_note") && tables.contains("highlight") {
                    try db.execute(sql: "DELETE FROM highlight_note WHERE highlightId NOT IN (SELECT id FROM highlight)")
                }
                if tables.contains("highlight_tag") && tables.contains("highlight") {
                    try db.execute(sql: "DELETE FROM highlight_tag WHERE highlightId NOT IN (SELECT id FROM highlight)")
                }
                if tables.contains("highlight_tag") && tables.contains("tag") {
                    try db.execute(sql: "DELETE FROM highlight_tag WHERE tagId NOT IN (SELECT id FROM tag)")
                }
            }

            var migrator = DatabaseMigrator()
            AppMigrations.registerMigrations(&migrator)
            try migrator.migrate(queue)
            return queue
        } catch {
            CaptureLog.error("Database open/migrate failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Remove stale -wal and -shm files that can prevent the database from opening
    /// after a crash. SQLite will recreate them as needed.
    private static func cleanStaleLockFiles(for dbFile: URL) {
        let fm = FileManager.default
        for ext in ["-wal", "-shm"] {
            let lockFile = URL(fileURLWithPath: dbFile.path + ext)
            if fm.fileExists(atPath: lockFile.path) {
                try? fm.removeItem(at: lockFile)
                CaptureLog.info("Removed stale lock file: \(lockFile.lastPathComponent)")
            }
        }
    }

    private static func attemptRecovery() -> DatabaseQueue? {
        let dbFile = appSupportURL.appendingPathComponent("capture.sqlite")
        let backupFile = appSupportURL.appendingPathComponent("capture.sqlite.bak")
        let fm = FileManager.default

        // Back up corrupt file
        try? fm.removeItem(at: backupFile)
        try? fm.moveItem(at: dbFile, to: backupFile)
        CaptureLog.info("Backed up corrupt database to capture.sqlite.bak")

        // Also move WAL/SHM files
        for ext in ["-wal", "-shm"] {
            let src = appSupportURL.appendingPathComponent("capture.sqlite\(ext)")
            let dst = appSupportURL.appendingPathComponent("capture.sqlite\(ext).bak")
            try? fm.removeItem(at: dst)
            try? fm.moveItem(at: src, to: dst)
        }

        // Try fresh database
        do {
            let queue = try DatabaseQueue(path: dbFile.path)
            var migrator = DatabaseMigrator()
            AppMigrations.registerMigrations(&migrator)
            try migrator.migrate(queue)
            return queue
        } catch {
            CaptureLog.error("Fresh database creation also failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func rewriteScreenshotPaths(from oldBase: String, to newBase: String) {
        guard let dbQueue else { return }
        try? dbQueue.write { db in
            try db.execute(sql: """
                UPDATE screenshot SET filePath = REPLACE(filePath, ?, ?)
                WHERE filePath LIKE ?
                """, arguments: [oldBase, newBase, oldBase + "%"])
            try db.execute(sql: """
                UPDATE highlight SET contentText = REPLACE(contentText, ?, ?)
                WHERE highlightType = 'screenshot' AND contentText LIKE ?
                """, arguments: [oldBase, newBase, oldBase + "%"])
        }
    }

    static let appSupportURL: URL = {
        let url = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                   ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("com.dubberly.Capture", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    // MARK: - Daily Maintenance

    func performDailyMaintenanceIfNeeded() {
        let key = "lastMaintenanceDate"
        let today = ScreenshotCapture.dayString()
        guard UserDefaults.standard.string(forKey: key) != today else { return }
        UserDefaults.standard.set(today, forKey: key)
        performDailyMaintenance()
    }

    /// One-time backfill: link orphan highlights (where highlightType is
    /// screenshot/recording/file but the FK is NULL) to their typed-table
    /// row by matching `highlight.contentText` to `filePath`. Necessary
    /// because the record structs previously conformed to `PersistableRecord`
    /// instead of `MutablePersistableRecord`, so `didInsert` never populated
    /// the id on the caller's instance and the FK was written as NULL.
    func backfillMissingForeignKeys() {
        guard let dbQueue else { return }
        let key = "highlightForeignKeyBackfillV1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }

        do {
            var totalLinked = 0
            try dbQueue.write { db in
                // Files
                let fileLinked = try db.execute(sql: """
                    UPDATE highlight
                    SET fileId = (
                        SELECT id FROM file_record WHERE file_record.filePath = highlight.contentText LIMIT 1
                    )
                    WHERE highlightType = 'file' AND (fileId IS NULL OR fileId = '')
                    """)
                _ = fileLinked

                // Recordings
                try db.execute(sql: """
                    UPDATE highlight
                    SET recordingId = (
                        SELECT id FROM recording WHERE recording.filePath = highlight.contentText LIMIT 1
                    )
                    WHERE highlightType = 'recording' AND (recordingId IS NULL OR recordingId = '')
                    """)

                // Screenshots
                try db.execute(sql: """
                    UPDATE highlight
                    SET screenshotId = (
                        SELECT id FROM screenshot WHERE screenshot.filePath = highlight.contentText LIMIT 1
                    )
                    WHERE highlightType = 'screenshot' AND (screenshotId IS NULL OR screenshotId = '')
                    """)

                totalLinked = try Int.fetchOne(db, sql: """
                    SELECT
                        (SELECT COUNT(*) FROM highlight WHERE highlightType = 'file' AND fileId IS NOT NULL) +
                        (SELECT COUNT(*) FROM highlight WHERE highlightType = 'recording' AND recordingId IS NOT NULL) +
                        (SELECT COUNT(*) FROM highlight WHERE highlightType = 'screenshot' AND screenshotId IS NOT NULL)
                    """) ?? 0
            }
            UserDefaults.standard.set(true, forKey: key)
            CaptureLog.info("Highlight FK backfill complete — \(totalLinked) highlights now linked")
        } catch {
            CaptureLog.error("Highlight FK backfill failed: \(error.localizedDescription)")
        }
    }

    private func performDailyMaintenance() {
        guard let dbQueue else { return }

        // WAL checkpoint
        do {
            try dbQueue.write { db in
                try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
            }
            CaptureLog.info("WAL checkpoint completed")
        } catch {
            CaptureLog.error("WAL checkpoint failed: \(error.localizedDescription)")
        }

        // Integrity check
        do {
            let result = try dbQueue.read { db in
                try String.fetchOne(db, sql: "PRAGMA integrity_check")
            }
            if result == "ok" {
                CaptureLog.info("Database integrity check passed")
            } else {
                CaptureLog.warning("Database integrity check: \(result ?? "unknown")")
            }
        } catch {
            CaptureLog.error("Database integrity check failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Disk Management

    func screenshotDiskUsage() -> Int64 {
        let screenshotsDir = ScreenshotCapture.screenshotsBaseURL
        guard let enumerator = FileManager.default.enumerator(
            at: screenshotsDir, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    func cleanupOldScreenshots(olderThanDays days: Int = 90) {
        guard let dbQueue else { return }
        let cutoffTimestamp = Date().addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970

        let oldRecords: [ScreenshotRecord] = (try? dbQueue.read { db in
            try ScreenshotRecord
                .filter(Column("timestamp") < cutoffTimestamp)
                .fetchAll(db)
        }) ?? []

        let fm = FileManager.default
        var deletedFiles = 0
        for record in oldRecords {
            if fm.fileExists(atPath: record.filePath) {
                try? fm.removeItem(atPath: record.filePath)
                deletedFiles += 1
            }
        }

        do {
            try dbQueue.write { db in
                try db.execute(sql: "DELETE FROM screenshot WHERE timestamp < ?", arguments: [cutoffTimestamp])
                try db.execute(sql: "DELETE FROM highlight WHERE highlightType = 'screenshot' AND timestamp < ?", arguments: [cutoffTimestamp])
            }
            CaptureLog.info("Cleaned up \(deletedFiles) screenshot files and \(oldRecords.count) DB records older than \(days) days")
        } catch {
            CaptureLog.error("Failed to clean up old screenshots: \(error.localizedDescription)")
        }
    }

    // MARK: - Screenshots

    func insertScreenshot(_ record: inout ScreenshotRecord) {
        guard let dbQueue else {
            CaptureLog.error("Cannot insert screenshot: database unavailable (degraded mode)")
            return
        }
        do {
            try dbQueue.write { db in
                try record.insert(db)
            }
        } catch {
            CaptureLog.error("Failed to insert screenshot: \(error.localizedDescription)")
        }
    }

    func screenshots(for dayString: String) -> [ScreenshotRecord] {
        (try? dbQueue?.read { db in
            try ScreenshotRecord
                .filter(Column("dayString") == dayString)
                .order(Column("timestamp").asc)
                .fetchAll(db)
        }) ?? []
    }

    func screenshot(byId id: Int64) -> ScreenshotRecord? {
        try? dbQueue?.read { db in
            try ScreenshotRecord.fetchOne(db, key: id)
        }
    }

    // MARK: - Highlights

    func insertHighlight(_ highlight: Highlight) {
        guard let dbQueue else {
            CaptureLog.error("Cannot insert highlight: database unavailable (degraded mode)")
            return
        }
        do {
            try dbQueue.write { db in
                try highlight.insert(db)
            }
        } catch {
            CaptureLog.error("Failed to insert highlight: \(error.localizedDescription)")
        }
    }

    func todayHighlights() -> [Highlight] {
        let startOfDay = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        return (try? dbQueue?.read { db in
            try Highlight
                .filter(Column("timestamp") >= startOfDay)
                .order(Column("timestamp").desc)
                .fetchAll(db)
        }) ?? []
    }

    func highlight(byId id: String) -> Highlight? {
        try? dbQueue?.read { db in
            try Highlight.fetchOne(db, key: id)
        }
    }

    func recentHighlights(limit: Int = 50) -> [Highlight] {
        (try? dbQueue?.read { db in
            try Highlight
                .order(Column("timestamp").desc)
                .limit(limit)
                .fetchAll(db)
        }) ?? []
    }

    func updateHighlightNote(id: String, note: String) {
        guard let dbQueue else { return }
        do {
            try dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE highlight SET userNote = ? WHERE id = ?",
                    arguments: [note, id]
                )
            }
            NotificationCenter.default.post(
                name: .highlightDataDidChange,
                object: nil,
                userInfo: ["highlightId": id, "change": "userNote"]
            )
        } catch {
            CaptureLog.error("Failed to update highlight note: \(error.localizedDescription)")
        }
    }

    /// Attach a downloaded FileRecord to an existing highlight. Used by URLFileDownloader
    /// to link a file it fetched back to the original URL-copy highlight.
    /// `contentType` is optional: pass the file's category (e.g. "pdf"); if nil, existing value is preserved.
    func updateHighlightFileLink(id: String, fileId: Int64, contentType: String?) {
        guard let dbQueue else { return }
        do {
            try dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE highlight SET fileId = ?, contentType = COALESCE(?, contentType) WHERE id = ?",
                    arguments: [fileId, contentType, id]
                )
            }
        } catch {
            CaptureLog.error("Failed to update highlight file link: \(error.localizedDescription)")
        }
    }

    func highlights(for dayString: String) -> [Highlight] {
        guard let dbQueue else { return [] }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        guard let dayDate = formatter.date(from: dayString) else { return [] }
        let startOfDay = Calendar.current.startOfDay(for: dayDate).timeIntervalSince1970
        let endOfDay = startOfDay + 86400
        return (try? dbQueue.read { db in
            try Highlight
                .filter(Column("timestamp") >= startOfDay && Column("timestamp") < endOfDay)
                .order(Column("timestamp").desc)
                .fetchAll(db)
        }) ?? []
    }

    func searchAll(query: String) -> [Highlight] {
        let tokens = query.lowercased()
            .split(separator: " ")
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return [] }

        // Each token must match at least one field (AND across tokens, OR across fields).
        // Fields: contentText, userNote, sourceApp, sourceUrl, windowTitle,
        //         bundleId, documentPath, OCR text, sub-notes.
        // For typo tolerance, also try patterns with each character dropped.
        var clauses: [String] = []
        var args: [String] = []

        for token in tokens {
            // Generate fuzzy variants: original + each single-char-deleted version
            var patterns: [String] = ["%\(token)%"]
            if token.count >= 4 {
                for i in token.indices {
                    var variant = token
                    variant.remove(at: i)
                    patterns.append("%\(variant)%")
                }
            }

            var tokenClauses: [String] = []
            for _ in patterns {
                let fieldMatch = """
                    (h.contentText LIKE ? COLLATE NOCASE
                     OR h.userNote LIKE ? COLLATE NOCASE
                     OR h.sourceApp LIKE ? COLLATE NOCASE
                     OR h.sourceUrl LIKE ? COLLATE NOCASE
                     OR h.windowTitle LIKE ? COLLATE NOCASE
                     OR h.bundleId LIKE ? COLLATE NOCASE
                     OR h.documentPath LIKE ? COLLATE NOCASE
                     OR EXISTS (SELECT 1 FROM screenshot s WHERE s.id = h.screenshotId AND s.ocrText LIKE ? COLLATE NOCASE)
                     OR EXISTS (SELECT 1 FROM highlight_note hn WHERE hn.highlightId = h.id AND hn.body LIKE ? COLLATE NOCASE)
                     OR EXISTS (SELECT 1 FROM file_record f WHERE f.id = h.fileId AND f.fileName LIKE ? COLLATE NOCASE)
                     OR EXISTS (SELECT 1 FROM highlight_tag ht JOIN tag t ON t.id = ht.tagId WHERE ht.highlightId = h.id AND t.name LIKE ? COLLATE NOCASE))
                    """
                tokenClauses.append(fieldMatch)
            }

            clauses.append("(" + tokenClauses.joined(separator: " OR ") + ")")
            for p in patterns {
                // 11 fields per pattern (including tag name)
                args.append(contentsOf: Array(repeating: p, count: 11))
            }
        }

        let where_ = clauses.joined(separator: " AND ")
        let sql = """
            SELECT h.* FROM highlight h
            WHERE \(where_)
            ORDER BY h.timestamp DESC
            LIMIT 200
            """

        return (try? dbQueue?.read { db in
            try Highlight.fetchAll(db, sql: sql, arguments: StatementArguments(args))
        }) ?? []
    }

    // MARK: - Highlight Notes

    func notesForHighlight(id: String) -> [HighlightNote] {
        (try? dbQueue?.read { db in
            try HighlightNote
                .filter(Column("highlightId") == id)
                .order(Column("createdAt").asc)
                .fetchAll(db)
        }) ?? []
    }

    func addNoteToHighlight(highlightId: String, body: String) {
        guard let dbQueue else { return }
        let note = HighlightNote(
            id: UUID().uuidString,
            highlightId: highlightId,
            body: body,
            createdAt: Date().timeIntervalSince1970
        )
        do {
            try dbQueue.write { db in
                try note.insert(db)
                try db.execute(
                    sql: "UPDATE highlight SET userNote = ? WHERE id = ?",
                    arguments: [body, highlightId]
                )
            }
            NotificationCenter.default.post(
                name: .highlightDataDidChange,
                object: nil,
                userInfo: ["highlightId": highlightId, "change": "notes"]
            )
        } catch {
            CaptureLog.error("Failed to add note to highlight: \(error.localizedDescription)")
        }
    }

    func deleteNote(id: String, highlightId: String) {
        guard let dbQueue else { return }
        do {
            try dbQueue.write { db in
                try db.execute(sql: "DELETE FROM highlight_note WHERE id = ?", arguments: [id])
                let latestBody = try String.fetchOne(db, sql: """
                    SELECT body FROM highlight_note
                    WHERE highlightId = ?
                    ORDER BY createdAt DESC LIMIT 1
                    """, arguments: [highlightId])
                try db.execute(
                    sql: "UPDATE highlight SET userNote = ? WHERE id = ?",
                    arguments: [latestBody, highlightId]
                )
            }
            NotificationCenter.default.post(
                name: .highlightDataDidChange,
                object: nil,
                userInfo: ["highlightId": highlightId, "change": "notes"]
            )
        } catch {
            CaptureLog.error("Failed to delete note: \(error.localizedDescription)")
        }
    }

    /// Permanently removes a highlight and all associated data:
    /// - highlight_note and highlight_tag rows (via CASCADE)
    /// - screenshot / recording / file_record rows and their managed files on disk
    /// Desktop screenshots (captureType="desktop") reference the user's original
    /// file and are never deleted from disk.
    func deleteHighlight(id: String) {
        guard let dbQueue else { return }

        // Fetch linked record IDs before deleting the highlight row
        let h = highlight(byId: id)

        do {
            try dbQueue.write { db in
                // screenshot row
                if let sid = h?.screenshotId {
                    if let rec = try ScreenshotRecord.fetchOne(db, sql: "SELECT * FROM screenshot WHERE id = ?", arguments: [sid]) {
                        if rec.captureType != "desktop" {
                            try? FileManager.default.removeItem(atPath: rec.filePath)
                        }
                        try db.execute(sql: "DELETE FROM screenshot WHERE id = ?", arguments: [sid])
                    }
                }

                // recording row
                if let rid = h?.recordingId {
                    if let rec = try RecordingRecord.fetchOne(db, sql: "SELECT * FROM recording WHERE id = ?", arguments: [rid]) {
                        try? FileManager.default.removeItem(atPath: rec.filePath)
                        try? FileManager.default.removeItem(atPath: rec.thumbnailPath)
                        try db.execute(sql: "DELETE FROM recording WHERE id = ?", arguments: [rid])
                    }
                }

                // file_record row — only delete managed copies (inside app support)
                if let fid = h?.fileId {
                    if let rec = try FileRecord.fetchOne(db, sql: "SELECT * FROM file_record WHERE id = ?", arguments: [fid]) {
                        let appSupport = Self.appSupportURL.path
                        if rec.filePath.hasPrefix(appSupport) {
                            try? FileManager.default.removeItem(atPath: rec.filePath)
                        }
                        if let thumb = rec.thumbnailPath {
                            try? FileManager.default.removeItem(atPath: thumb)
                        }
                        try db.execute(sql: "DELETE FROM file_record WHERE id = ?", arguments: [fid])
                    }
                }

                // highlight row (CASCADE deletes highlight_note + highlight_tag)
                try db.execute(sql: "DELETE FROM highlight WHERE id = ?", arguments: [id])
            }

            NotificationCenter.default.post(
                name: .highlightDidDelete,
                object: nil,
                userInfo: ["highlightId": id]
            )
            CaptureLog.info("Deleted highlight \(id)")
        } catch {
            CaptureLog.error("Failed to delete highlight \(id): \(error.localizedDescription)")
        }
    }

    func noteCountsForHighlights(ids: [String]) -> [String: Int] {
        guard let dbQueue, !ids.isEmpty else { return [:] }
        return (try? dbQueue.read { db in
            let placeholders = ids.map { _ in "?" }.joined(separator: ",")
            let rows = try Row.fetchAll(db, sql: """
                SELECT highlightId, COUNT(*) as cnt
                FROM highlight_note
                WHERE highlightId IN (\(placeholders))
                GROUP BY highlightId
                """, arguments: StatementArguments(ids))
            var result: [String: Int] = [:]
            for row in rows {
                if let hid: String = row["highlightId"],
                   let cnt: Int = row["cnt"] {
                    result[hid] = cnt
                }
            }
            return result
        }) ?? [:]
    }

    func allHighlightsPaginated(offset: Int, limit: Int) -> [Highlight] {
        (try? dbQueue?.read { db in
            try Highlight
                .order(Column("timestamp").desc)
                .limit(limit, offset: offset)
                .fetchAll(db)
        }) ?? []
    }

    func highlightsByTypePaginated(type: String, offset: Int, limit: Int) -> [Highlight] {
        (try? dbQueue?.read { db in
            try Highlight
                .filter(Column("highlightType") == type)
                .order(Column("timestamp").desc)
                .limit(limit, offset: offset)
                .fetchAll(db)
        }) ?? []
    }

    // MARK: - Pattern Queries

    func appFacets() -> [(appName: String, bundleId: String?, count: Int)] {
        guard let dbQueue else { return [] }
        return (try? dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT sourceApp, MAX(bundleId) as bundleId, COUNT(*) as cnt
                FROM highlight
                WHERE sourceApp IS NOT NULL
                  AND sourceApp != 'Screenshot'
                GROUP BY sourceApp
                ORDER BY cnt DESC
                """)
            return rows.compactMap { row -> (String, String?, Int)? in
                guard let app: String = row["sourceApp"],
                      let cnt: Int = row["cnt"] else { return nil }
                let bid: String? = row["bundleId"]
                return (app, bid, cnt)
            }
        }) ?? []
    }

    func typeCounts() -> [String: Int] {
        guard let dbQueue else { return [:] }
        return (try? dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT highlightType, COUNT(*) as cnt FROM highlight GROUP BY highlightType
                """)
            var result: [String: Int] = [:]
            for row in rows {
                if let type: String = row["highlightType"], let cnt: Int = row["cnt"] {
                    result[type] = cnt
                }
            }
            return result
        }) ?? [:]
    }

    func tagHighlightCounts() -> [String: Int] {
        guard let dbQueue else { return [:] }
        return (try? dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT tagId, COUNT(*) as cnt FROM highlight_tag GROUP BY tagId
                """)
            var result: [String: Int] = [:]
            for row in rows {
                if let tagId: String = row["tagId"], let cnt: Int = row["cnt"] {
                    result[tagId] = cnt
                }
            }
            return result
        }) ?? [:]
    }

    func annotatedHighlightCount() -> Int {
        (try? dbQueue?.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(DISTINCT h.id) FROM highlight h
                WHERE EXISTS (SELECT 1 FROM highlight_note hn WHERE hn.highlightId = h.id)
                   OR (h.userNote IS NOT NULL AND h.userNote != '')
                """)
        } ?? 0) ?? 0
    }

    func annotatedHighlightsPaginated(offset: Int, limit: Int) -> [Highlight] {
        (try? dbQueue?.read { db in
            try Highlight.fetchAll(db, sql: """
                SELECT DISTINCT h.* FROM highlight h
                LEFT JOIN highlight_note hn ON hn.highlightId = h.id
                WHERE hn.id IS NOT NULL
                   OR (h.userNote IS NOT NULL AND h.userNote != '')
                ORDER BY h.timestamp DESC
                LIMIT ? OFFSET ?
                """, arguments: [limit, offset])
        }) ?? []
    }

    func videoHighlightCount() -> Int {
        (try? dbQueue?.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM highlight
                WHERE highlightType = 'file' AND contentType = 'video'
                """)
        } ?? 0) ?? 0
    }

    func videoHighlightsPaginated(offset: Int, limit: Int) -> [Highlight] {
        (try? dbQueue?.read { db in
            try Highlight.fetchAll(db, sql: """
                SELECT * FROM highlight
                WHERE highlightType = 'file' AND contentType = 'video'
                ORDER BY timestamp DESC
                LIMIT ? OFFSET ?
                """, arguments: [limit, offset])
        }) ?? []
    }

    func fileExcludingVideoCount() -> Int {
        (try? dbQueue?.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM highlight
                WHERE highlightType = 'file' AND (contentType IS NULL OR contentType != 'video')
                """)
        } ?? 0) ?? 0
    }

    func fileExcludingVideoPaginated(offset: Int, limit: Int) -> [Highlight] {
        (try? dbQueue?.read { db in
            try Highlight.fetchAll(db, sql: """
                SELECT * FROM highlight
                WHERE highlightType = 'file' AND (contentType IS NULL OR contentType != 'video')
                ORDER BY timestamp DESC
                LIMIT ? OFFSET ?
                """, arguments: [limit, offset])
        }) ?? []
    }

    func linkHighlightCount() -> Int {
        (try? dbQueue?.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM highlight
                WHERE contentType = 'url'
                   OR (highlightType = 'copy' AND (contentText LIKE 'http://%' OR contentText LIKE 'https://%'))
                """)
        } ?? 0) ?? 0
    }

    func linkHighlightsPaginated(offset: Int, limit: Int) -> [Highlight] {
        (try? dbQueue?.read { db in
            try Highlight.fetchAll(db, sql: """
                SELECT * FROM highlight
                WHERE contentType = 'url'
                   OR (highlightType = 'copy' AND (contentText LIKE 'http://%' OR contentText LIKE 'https://%'))
                ORDER BY timestamp DESC
                LIMIT ? OFFSET ?
                """, arguments: [limit, offset])
        }) ?? []
    }

    func pruneEmptyTags() {
        guard let dbQueue else { return }
        try? dbQueue.write { db in
            try db.execute(sql: """
                DELETE FROM tag WHERE id NOT IN (SELECT DISTINCT tagId FROM highlight_tag)
                """)
        }
    }

    func highlightsForApp(sourceApp: String, offset: Int, limit: Int) -> [Highlight] {
        (try? dbQueue?.read { db in
            try Highlight
                .filter(Column("sourceApp") == sourceApp)
                .order(Column("timestamp").desc)
                .limit(limit, offset: offset)
                .fetchAll(db)
        }) ?? []
    }

    func allHighlightsChronological(offset: Int, limit: Int) -> [Highlight] {
        (try? dbQueue?.read { db in
            try Highlight
                .order(Column("timestamp").asc)
                .limit(limit, offset: offset)
                .fetchAll(db)
        }) ?? []
    }

    // MARK: - Related Captures

    func relatedHighlights(to highlight: Highlight, limit: Int = 10) -> [Highlight] {
        guard let dbQueue else { return [] }

        // Collect candidates from 3 signals, deduped, excluding the source highlight
        var seen = Set<String>([highlight.id])
        var results: [Highlight] = []

        func addIfNew(_ items: [Highlight]) {
            for item in items where !seen.contains(item.id) {
                seen.insert(item.id)
                results.append(item)
            }
        }

        // 1. Same source URL
        if let url = highlight.sourceUrl, !url.isEmpty {
            let sameUrl = (try? dbQueue.read { db in
                try Highlight.fetchAll(db, sql: """
                    SELECT * FROM highlight
                    WHERE sourceUrl = ? AND id != ?
                    ORDER BY timestamp DESC LIMIT ?
                    """, arguments: [url, highlight.id, limit])
            }) ?? []
            addIfNew(sameUrl)
        }

        // 2. Same app + window title
        if let app = highlight.sourceApp, let wt = highlight.windowTitle, !wt.isEmpty {
            let sameWindow = (try? dbQueue.read { db in
                try Highlight.fetchAll(db, sql: """
                    SELECT * FROM highlight
                    WHERE sourceApp = ? AND windowTitle = ? AND id != ?
                    ORDER BY timestamp DESC LIMIT ?
                    """, arguments: [app, wt, highlight.id, limit])
            }) ?? []
            addIfNew(sameWindow)
        }

        // 3. Same time window (±5 minutes)
        let window: Double = 300
        let sameTime = (try? dbQueue.read { db in
            try Highlight.fetchAll(db, sql: """
                SELECT * FROM highlight
                WHERE timestamp BETWEEN ? AND ? AND id != ?
                ORDER BY ABS(timestamp - ?) ASC LIMIT ?
                """, arguments: [
                    highlight.timestamp - window,
                    highlight.timestamp + window,
                    highlight.id,
                    highlight.timestamp,
                    limit
                ])
        }) ?? []
        addIfNew(sameTime)

        return Array(results.prefix(limit))
    }

    // MARK: - Annotation Labels

    func frequentAnnotationLabels(limit: Int = 5) -> [String] {
        guard let dbQueue else { return ["reference", "todo", "important"] }

        // Frequent short notes (reused as tags)
        let frequentNotes: [String] = (try? dbQueue.read { db in
            try String.fetchAll(db, sql: """
                SELECT userNote FROM highlight
                WHERE userNote IS NOT NULL AND userNote != '' AND LENGTH(userNote) < 20
                GROUP BY userNote
                ORDER BY COUNT(*) DESC
                LIMIT ?
                """, arguments: [limit])
        }) ?? []

        // Top source apps as fallback chips
        let topApps: [String] = (try? dbQueue.read { db in
            try String.fetchAll(db, sql: """
                SELECT sourceApp FROM highlight
                WHERE sourceApp IS NOT NULL
                GROUP BY sourceApp
                ORDER BY COUNT(*) DESC
                LIMIT 3
                """)
        }) ?? []

        // Merge, deduplicate, return up to limit
        var seen = Set<String>()
        var result: [String] = []
        for label in frequentNotes + topApps {
            let lower = label.lowercased()
            if !seen.contains(lower) {
                seen.insert(lower)
                result.append(label)
            }
            if result.count >= limit { break }
        }

        // Fallback for empty databases
        if result.isEmpty {
            return ["reference", "todo", "important"]
        }
        return result
    }

    // MARK: - Recordings

    func insertRecording(_ record: inout RecordingRecord) {
        guard let dbQueue else { return }
        do {
            try dbQueue.write { db in
                try record.insert(db)
            }
        } catch {
            CaptureLog.error("Failed to insert recording: \(error.localizedDescription)")
        }
    }

    func recording(byId id: Int64) -> RecordingRecord? {
        try? dbQueue?.read { db in
            try RecordingRecord.fetchOne(db, key: id)
        }
    }

    // MARK: - File Records

    func insertFileRecord(_ record: inout FileRecord) {
        guard let dbQueue else {
            CaptureLog.error("Cannot insert file record: database unavailable (degraded mode)")
            return
        }
        do {
            try dbQueue.write { db in
                try record.insert(db)
            }
        } catch {
            CaptureLog.error("Failed to insert file record: \(error.localizedDescription)")
        }
    }

    func fileRecord(byId id: Int64) -> FileRecord? {
        try? dbQueue?.read { db in
            try FileRecord.fetchOne(db, key: id)
        }
    }

    func fileRecordByPath(_ filePath: String) -> FileRecord? {
        try? dbQueue?.read { db in
            try FileRecord
                .filter(Column("filePath") == filePath)
                .fetchOne(db)
        }
    }

    /// Look up a file that was previously downloaded from the given URL.
    /// Used by URLFileDownloader to dedup re-copies of the same link.
    /// Also verifies the persisted file still exists on disk — if it was
    /// deleted out of band, returns nil so the caller re-downloads.
    func fileRecord(byOriginalUrl originalUrl: String) -> FileRecord? {
        let record = try? dbQueue?.read { db in
            try FileRecord
                .filter(Column("originalUrl") == originalUrl)
                .fetchOne(db)
        }
        guard let record, FileManager.default.fileExists(atPath: record.filePath) else {
            return nil
        }
        return record
    }

    func updateFileRecordThumbnail(id: Int64, thumbnailPath: String) {
        try? dbQueue?.write { db in
            try db.execute(
                sql: "UPDATE file_record SET thumbnailPath = ? WHERE id = ?",
                arguments: [thumbnailPath, id]
            )
        }
    }

    // MARK: - Link Previews

    func insertLinkPreview(_ preview: inout LinkPreview) {
        guard let dbQueue else { return }
        do {
            try dbQueue.write { db in
                try preview.upsert(db)
            }
        } catch {
            CaptureLog.error("Failed to upsert link_preview: \(error.localizedDescription)")
        }
    }

    func linkPreview(forURL url: String) -> LinkPreview? {
        try? dbQueue?.read { db in
            try LinkPreview.fetchOne(db, key: url)
        }
    }

    /// Distinct URL strings from `highlight.contentText` that do not yet have
    /// a successfully-cached link_preview row. Used by `LinkPreviewStore` to
    /// throttle a background backfill of historical copies.
    func distinctURLCopiesNeedingPreview() -> [String] {
        (try? dbQueue?.read { db in
            try String.fetchAll(db, sql: """
                SELECT DISTINCT h.contentText
                FROM highlight h
                LEFT JOIN link_preview p ON p.url = h.contentText
                WHERE (h.contentType = 'url'
                       OR h.contentText LIKE 'http://%'
                       OR h.contentText LIKE 'https://%')
                  AND (p.url IS NULL OR p.fetchError IS NOT NULL)
                """)
        }) ?? []
    }

    // MARK: - Clipboard Entries

    func insertClipboardEntry(_ entry: ClipboardEntryRecord) {
        guard let dbQueue else {
            CaptureLog.error("Cannot insert clipboard entry: database unavailable (degraded mode)")
            return
        }
        do {
            try dbQueue.write { db in try entry.insert(db) }
        } catch {
            CaptureLog.error("Failed to insert clipboard entry: \(error.localizedDescription)")
        }
    }

    /// Layer 2 clipboard dedup safety net. Returns true if a `highlight` row of
    /// type `"copy"` with the same `contentHash` was written within the last
    /// `withinSeconds`. Used by `ClipboardMonitor` to swallow rapid-fire
    /// duplicate copies when its in-memory guard has been lost (app restart,
    /// out-of-process clipboard bump, etc.). 30s is the V1 default.
    func recentCopyHighlightExists(contentHash: String, withinSeconds: Double = 30.0) -> Bool {
        guard let dbQueue, !contentHash.isEmpty else { return false }
        let threshold = Date().timeIntervalSince1970 - withinSeconds
        return (try? dbQueue.read { db in
            try Bool.fetchOne(db, sql: """
                SELECT EXISTS (
                    SELECT 1 FROM highlight
                    WHERE highlightType = 'copy'
                      AND contentHash = ?
                      AND timestamp > ?
                    LIMIT 1
                )
                """, arguments: [contentHash, threshold])
        }) ?? false
    }

    // MARK: - Tags

    func findOrCreateTag(name: String) -> Tag? {
        guard let dbQueue else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        do {
            return try dbQueue.write { db in
                if let existing = try Tag.fetchOne(db, sql: "SELECT * FROM tag WHERE name = ?", arguments: [trimmed]) {
                    return existing
                }
                let now = Date().timeIntervalSince1970
                let tag = Tag(id: UUID().uuidString, name: trimmed, color: nil, emoji: nil, createdAt: now, updatedAt: now)
                try tag.insert(db)
                return tag
            }
        } catch {
            CaptureLog.error("Failed to find/create tag: \(error.localizedDescription)")
            return nil
        }
    }

    func allTags() -> [Tag] {
        (try? dbQueue?.read { db in
            try Tag.fetchAll(db, sql: """
                SELECT t.* FROM tag t
                LEFT JOIN highlight_tag ht ON ht.tagId = t.id
                GROUP BY t.id
                ORDER BY MAX(ht.createdAt) DESC, t.updatedAt DESC
                """)
        }) ?? []
    }

    func deleteTag(id: String) {
        guard let dbQueue else { return }
        do {
            try dbQueue.write { db in
                try db.execute(sql: "DELETE FROM tag WHERE id = ?", arguments: [id])
            }
        } catch {
            CaptureLog.error("Failed to delete tag: \(error.localizedDescription)")
        }
    }

    func renameTag(id: String, newName: String) {
        guard let dbQueue else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return }
        do {
            try dbQueue.write { db in
                try db.execute(sql: "UPDATE tag SET name = ?, updatedAt = ? WHERE id = ?",
                               arguments: [trimmed, Date().timeIntervalSince1970, id])
            }
        } catch {
            CaptureLog.error("Failed to rename tag: \(error.localizedDescription)")
        }
    }

    func addTag(_ tagId: String, toHighlight highlightId: String) {
        guard let dbQueue else { return }
        do {
            try dbQueue.write { db in
                try db.execute(sql: """
                    INSERT OR IGNORE INTO highlight_tag (tagId, highlightId, createdAt)
                    VALUES (?, ?, ?)
                    """, arguments: [tagId, highlightId, Date().timeIntervalSince1970])
            }
            NotificationCenter.default.post(
                name: .highlightDataDidChange,
                object: nil,
                userInfo: ["highlightId": highlightId, "change": "tags"]
            )
        } catch {
            CaptureLog.error("Failed to add tag to highlight: \(error.localizedDescription)")
        }
    }

    func removeTag(_ tagId: String, fromHighlight highlightId: String) {
        guard let dbQueue else { return }
        do {
            try dbQueue.write { db in
                try db.execute(sql: "DELETE FROM highlight_tag WHERE tagId = ? AND highlightId = ?",
                               arguments: [tagId, highlightId])
            }
            NotificationCenter.default.post(
                name: .highlightDataDidChange,
                object: nil,
                userInfo: ["highlightId": highlightId, "change": "tags"]
            )
        } catch {
            CaptureLog.error("Failed to remove tag from highlight: \(error.localizedDescription)")
        }
    }

    func highlightsForTag(tagId: String) -> [Highlight] {
        (try? dbQueue?.read { db in
            try Highlight.fetchAll(db, sql: """
                SELECT h.* FROM highlight h
                JOIN highlight_tag ht ON ht.highlightId = h.id
                WHERE ht.tagId = ?
                ORDER BY h.timestamp DESC
                """, arguments: [tagId])
        }) ?? []
    }

    func highlightsForTagPaginated(tagId: String, offset: Int, limit: Int) -> [Highlight] {
        (try? dbQueue?.read { db in
            try Highlight.fetchAll(db, sql: """
                SELECT h.* FROM highlight h
                JOIN highlight_tag ht ON ht.highlightId = h.id
                WHERE ht.tagId = ?
                ORDER BY h.timestamp DESC
                LIMIT ? OFFSET ?
                """, arguments: [tagId, limit, offset])
        }) ?? []
    }

    func setTagEmoji(id: String, emoji: String?) {
        try? dbQueue?.write { db in
            try db.execute(sql: "UPDATE tag SET emoji = ?, updatedAt = ? WHERE id = ?",
                           arguments: [emoji, Date().timeIntervalSince1970, id])
        }
    }

    func setTagPublished(id: String, published: Bool) {
        try? dbQueue?.write { db in
            try db.execute(sql: "UPDATE tag SET isPublished = ? WHERE id = ?",
                           arguments: [published, id])
        }
    }

    func publishedTags() -> [Tag] {
        (try? dbQueue?.read { db in
            try Tag.fetchAll(db, sql: "SELECT * FROM tag WHERE isPublished = 1 ORDER BY name")
        }) ?? []
    }

    func tagsForHighlight(id: String) -> [Tag] {
        (try? dbQueue?.read { db in
            try Tag.fetchAll(db, sql: """
                SELECT t.* FROM tag t
                JOIN highlight_tag ht ON ht.tagId = t.id
                WHERE ht.highlightId = ?
                ORDER BY t.name
                """, arguments: [id])
        }) ?? []
    }

    func tagsForHighlights(ids: [String]) -> [String: [Tag]] {
        guard let dbQueue, !ids.isEmpty else { return [:] }
        return (try? dbQueue.read { db in
            let placeholders = ids.map { _ in "?" }.joined(separator: ",")
            let rows = try Row.fetchAll(db, sql: """
                SELECT t.*, ht.highlightId
                FROM tag t
                JOIN highlight_tag ht ON ht.tagId = t.id
                WHERE ht.highlightId IN (\(placeholders))
                ORDER BY t.name
                """, arguments: StatementArguments(ids))
            var result: [String: [Tag]] = [:]
            for row in rows {
                guard let hid: String = row["highlightId"] else { continue }
                let tag = Tag(
                    id: row["id"],
                    name: row["name"],
                    color: row["color"],
                    createdAt: row["createdAt"],
                    updatedAt: row["updatedAt"]
                )
                result[hid, default: []].append(tag)
            }
            return result
        }) ?? [:]
    }

    func tagsMatching(prefix: String, limit: Int = 10) -> [Tag] {
        let pattern = "\(prefix.lowercased())%"
        return (try? dbQueue?.read { db in
            try Tag.fetchAll(db, sql: "SELECT * FROM tag WHERE name LIKE ? ORDER BY name LIMIT ?",
                             arguments: [pattern, limit])
        }) ?? []
    }

    func popularTags(limit: Int = 5) -> [Tag] {
        (try? dbQueue?.read { db in
            try Tag.fetchAll(db, sql: """
                SELECT t.* FROM tag t
                JOIN highlight_tag ht ON ht.tagId = t.id
                GROUP BY t.id
                ORDER BY COUNT(*) DESC
                LIMIT ?
                """, arguments: [limit])
        }) ?? []
    }
}

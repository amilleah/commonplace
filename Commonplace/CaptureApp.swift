import SwiftUI

@main
struct CaptureApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // No visible windows — the status item and BrowseWindow are managed by AppDelegate
        Settings { EmptyView() }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Prime accessory activation policy explicitly. LSUIElement=YES sets
        // this at Info.plist level, but SwiftUI's @main lifecycle can leave
        // the Carbon event target un-primed until setActivationPolicy is
        // called from code — without this, RegisterEventHotKey-based hotkeys
        // (ctrl+cmd+a) silently don't fire until the app is activated once.
        NSApp.setActivationPolicy(.accessory)

        // Initialize logger first
        _ = CaptureLog.shared
        CaptureLog.info("Commonplace app launching")

        // Initialize database (now with crash protection)
        let db = DatabaseManager.shared
        if db.isDegraded {
            CaptureLog.error("Running in degraded mode — no database persistence")
        } else {
            CaptureLog.info("Database initialized successfully")
        }

        if AppEnvironment.isRunningUITests {
            CaptureLog.info("UI test mode detected — skipping production capture services")
            BrowseWindowController.shared.show()
            return
        }

        // Start rolling database backups (every 30 minutes + on launch)
        DatabaseBackupManager.shared.backupNow(label: "launch")
        DatabaseBackupManager.shared.startPeriodicBackups()

        // One-time backfill of missing highlight → typed-record foreign keys
        db.backfillMissingForeignKeys()

        // Fetch link-preview metadata for any historical URL copies in the
        // background (throttled; idempotent across launches).
        LinkPreviewStore.shared.backfillExistingURLs()

        // Daily maintenance (WAL checkpoint + integrity check)
        db.performDailyMaintenanceIfNeeded()

        // Screenshot disk usage check
        let diskUsage = db.screenshotDiskUsage()
        let diskUsageMB = diskUsage / (1024 * 1024)
        CaptureLog.info("Screenshot disk usage: \(diskUsageMB) MB")
        if diskUsage > 2 * 1024 * 1024 * 1024 { // 2 GB
            CaptureLog.warning("Screenshot storage exceeds 2 GB (\(diskUsageMB) MB) — consider cleanup")
        }

        // Permissions: single source of truth for live state. The setup wizard
        // drives the user through granting; no system prompts fire here.
        PermissionsMonitor.shared.start()
        PermissionsWindowController.shared.startWatchingForRevocation()

        // Menu bar status item — click opens Browse, right-click shows menu
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Commonplace")
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.target = self
        }

        // Start each subsystem independently so one failure doesn't block the rest
        ClipboardMonitor.shared.start()
        CaptureLog.info("Clipboard monitor started")

        BrowseWindowController.shared.registerHotkey()
        CaptureLog.info("Browse hotkey registered")

        // Register as macOS Services provider (right-click → Clip to Capture)
        NSApp.servicesProvider = ClipService.shared
        NSUpdateDynamicServices()
        CaptureLog.info("Clip service registered")

        // Wire clipboard copy → highlight capture (with context)
        ClipboardMonitor.shared.onCopyWithContent = { content, sourceApp, entryId, context in
            HighlightCapture.shared.captureFromCopy(
                content: content, sourceApp: sourceApp,
                entryId: entryId, context: context
            )
        }

        FileMonitor.shared.start()
        CaptureLog.info("File monitor started")

        CaptureLog.info("All systems started")

        // First-run: show permissions setup if needed
        PermissionsWindowController.shared.showIfNeeded()
    }

    @objc private func statusItemClicked() {
        guard let event = NSApp.currentEvent else {
            BrowseWindowController.shared.show()
            return
        }

        if event.type == .rightMouseUp {
            showStatusMenu()
        } else {
            BrowseWindowController.shared.show()
        }
    }

    private func showStatusMenu() {
        let menu = NSMenu()

        menu.addItem(withTitle: "Open Commonplace", action: #selector(openBrowse), keyEquivalent: "")
            .target = self

        menu.addItem(.separator())

        menu.addItem(withTitle: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
            .target = self

        menu.addItem(.separator())

        menu.addItem(withTitle: "Quit Commonplace", action: #selector(quitApp), keyEquivalent: "q")
            .target = self

        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        // Clear the menu after it closes so left-click still works
        DispatchQueue.main.async { self.statusItem?.menu = nil }
    }

    @objc private func openBrowse() {
        BrowseWindowController.shared.show()
    }

    @objc private func openSettings() {
        BrowseWindowController.shared.showSettings()
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        if !AppEnvironment.isRunningUITests {
            FileMonitor.shared.stop()
            ClipboardMonitor.shared.stop()
        }

        // Tear down all window controllers and hotkey monitors
        BrowseWindowController.shared.teardown()
        CopyToastController.shared.teardown()
        DatabaseBackupManager.shared.stop()

        CaptureLog.info("Commonplace app terminating")
    }
}

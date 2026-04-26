import SwiftUI
import AppKit
import Carbon.HIToolbox

final class BrowseWindowController: NSObject, NSWindowDelegate, ManagedWindowController {
    static let shared = BrowseWindowController()

    private var window: NSWindow?
    private var toggleHotKey: CarbonHotKey?

    /// Posted when the browse window becomes visible.
    static let windowDidShowNotification = Notification.Name("BrowseWindowDidShow")

    /// Posted to open a specific highlight's detail view. UserInfo contains ["highlightId": String].
    static let showHighlightDetailNotification = Notification.Name("BrowseWindowShowHighlightDetail")

    /// Posted to open the Browse window with the Settings panel showing.
    static let showSettingsNotification = Notification.Name("BrowseWindowShowSettings")

    /// Posted to open the Browse window filtered to a specific tag/collection.
    static let showTagFilterNotification = Notification.Name("BrowseWindowShowTagFilter")

    func registerHotkey() {
        // Carbon RegisterEventHotKey — fires system-wide without Accessibility
        // permission, unlike NSEvent global monitors.
        toggleHotKey = CarbonHotKey(
            keyCode: UInt32(kVK_ANSI_A),
            modifiers: UInt32(cmdKey | controlKey)
        ) { [weak self] in
            DispatchQueue.main.async { self?.toggle() }
        }
        if toggleHotKey == nil {
            CaptureLog.warning("[BrowseWindowController] Failed to register Ctrl+Cmd+A — combo may be in use by another app")
        }
    }

    func toggle() {
        if let window = window, window.isVisible, window.isKeyWindow {
            dismiss()
        } else {
            show()
        }
    }

    func show() {
        // Create the window once. After that, just show/hide it.
        // The SwiftUI view hierarchy is never destroyed, preventing
        // the use-after-free crash that occurs during NSHostingController teardown.
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: true
            )
            w.title = "Commonplace"
            w.minSize = NSSize(width: 400, height: 300)
            w.isMovableByWindowBackground = false
            w.delegate = self
            w.collectionBehavior = [.moveToActiveSpace]
            let hc = NSHostingController(rootView: RootContentView())
            hc.sizingOptions = []
            w.contentViewController = hc

            // 70% of screen, centered
            if let screen = NSScreen.main?.visibleFrame {
                let width = screen.width * 0.7
                let height = screen.height * 0.7
                let x = screen.midX - width / 2
                let y = screen.midY - height / 2
                w.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
            } else {
                w.center()
            }
            window = w
        }

        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Tell BrowseView to refresh its data
        NotificationCenter.default.post(name: Self.windowDidShowNotification, object: nil)
    }

    /// Opens the browse window and shows a specific highlight's detail view.
    func showHighlight(_ highlightId: String) {
        show()
        // Give SwiftUI a moment to set up, then post the detail notification
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            NotificationCenter.default.post(
                name: Self.showHighlightDetailNotification,
                object: nil,
                userInfo: ["highlightId": highlightId]
            )
            // Re-activate after the toast dismiss animation to ensure the window is on top
            self?.window?.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func showSettings() {
        show()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NotificationCenter.default.post(name: Self.showSettingsNotification, object: nil)
        }
    }

    func dismiss() {
        // Hide — don't close. Window and SwiftUI hierarchy stay alive.
        window?.orderOut(nil)
    }

    // Intercept the title bar close button: hide instead of close.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        dismiss()
        return false
    }

    func teardown() {
        toggleHotKey?.unregister()
        toggleHotKey = nil
        // Only on app quit: actually close and release
        window?.delegate = nil
        window?.close()
        window = nil
    }
}

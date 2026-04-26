import Foundation
import Combine
import AppKit
import ApplicationServices
import CoreGraphics
import ScreenCaptureKit

// Live permission state. SwiftUI views observe this; AppKit listeners subscribe
// to `.permissionsDidChange`. On app activation the state is re-polled; while
// the app is active, a slow background poll catches changes that System
// Settings can't announce directly.
//
// Screen recording truth: `CGPreflightScreenCaptureAccess()` caches its answer
// per-process and can go stale after the user toggles the setting without the
// system killing the app (common on debug builds). We probe
// `SCShareableContent` as the authoritative check — if it returns displays,
// we have permission regardless of what preflight claims.
@MainActor
final class PermissionsMonitor: ObservableObject {
    static let shared = PermissionsMonitor()

    @Published private(set) var screenRecordingGranted: Bool
    @Published private(set) var accessibilityGranted: Bool

    var allGranted: Bool { screenRecordingGranted && accessibilityGranted }

    private var pollTimer: Timer?
    private var activationObserver: NSObjectProtocol?
    private var resignObserver: NSObjectProtocol?
    private var screenProbeInFlight = false

    private init() {
        self.screenRecordingGranted = CGPreflightScreenCaptureAccess()
        self.accessibilityGranted = AXIsProcessTrusted()
    }

    func start() {
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.refresh()
                self.startPolling()
            }
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.stopPolling() }
        }
        refresh()
        if NSApp.isActive { startPolling() }
    }

    func refresh() {
        let nextAX = AXIsProcessTrusted()
        let axChanged = nextAX != accessibilityGranted
        accessibilityGranted = nextAX

        let preflight = CGPreflightScreenCaptureAccess()
        if preflight && !screenRecordingGranted {
            applyScreenState(true)
        }

        probeScreenRecording()

        if axChanged {
            NotificationCenter.default.post(name: .permissionsDidChange, object: nil)
        }
    }

    // Authoritative screen-recording check. SCShareableContent only returns
    // displays when the process is genuinely authorized — if preflight says
    // "yes" but this throws, preflight is stale (and vice versa).
    private func probeScreenRecording() {
        guard !screenProbeInFlight else { return }
        screenProbeInFlight = true
        Task.detached { [weak self] in
            let granted: Bool
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(
                    false, onScreenWindowsOnly: true
                )
                granted = !content.displays.isEmpty
            } catch {
                granted = false
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.screenProbeInFlight = false
                self.applyScreenState(granted)
            }
        }
    }

    private func applyScreenState(_ granted: Bool) {
        guard granted != screenRecordingGranted else { return }
        screenRecordingGranted = granted
        NotificationCenter.default.post(name: .permissionsDidChange, object: nil)
    }

    private func startPolling() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
}

extension Notification.Name {
    static let permissionsDidChange = Notification.Name("permissionsDidChange")
}

import AppKit
import ApplicationServices
import IOKit.hid

/// Tracks the two TCC permissions the scroll feature needs:
///   • Accessibility   — to create an *active* event tap that modifies events.
///   • Input Monitoring — to observe input events at the session level.
/// Keep Awake needs neither, so it always works regardless of this state.
@MainActor
@Observable
final class PermissionsManager {
    private(set) var accessibilityGranted = false
    private(set) var inputMonitoringGranted = false

    /// Both permissions present — the precondition for running the scroll tap.
    var allGranted: Bool { accessibilityGranted && inputMonitoringGranted }

    /// Invoked whenever the grant state actually changes (e.g. the user grants or
    /// revokes a permission). The model uses this to start/stop the scroll tap.
    var onChange: (() -> Void)?

    /// macOS only ever shows the Input Monitoring prompt once per app; after that
    /// a request silently does nothing, so we remember and deep-link instead.
    private let didRequestInputMonitoringKey = "didRequestInputMonitoring"
    private var monitorTask: Task<Void, Never>?

    init() {
        refresh()
    }

    /// Re-read the current grant state (cheap, no prompts). Fires `onChange` only
    /// when something actually flipped.
    func refresh() {
        let accessibility = AXIsProcessTrusted()
        let inputMonitoring = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        guard accessibility != accessibilityGranted || inputMonitoring != inputMonitoringGranted else { return }
        accessibilityGranted = accessibility
        inputMonitoringGranted = inputMonitoring
        onChange?()
    }

    // MARK: Requests

    /// Show the system Accessibility prompt (first time) and surface the pane.
    func requestAccessibility() {
        // `kAXTrustedCheckOptionPrompt` is imported as a non-concurrency-safe
        // global; its value is the stable string "AXTrustedCheckOptionPrompt".
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Request Input Monitoring. The OS prompts only once ever; thereafter we
    /// deep-link to System Settings so the user can grant it manually.
    func requestInputMonitoring() {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: didRequestInputMonitoringKey) {
            openSettings(.inputMonitoring)
        } else {
            defaults.set(true, forKey: didRequestInputMonitoringKey)
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }
    }

    /// Request whatever is still missing, in one call.
    func requestMissing() {
        if !accessibilityGranted { requestAccessibility() }
        if !inputMonitoringGranted { requestInputMonitoring() }
    }

    // MARK: System Settings deep links

    enum Pane {
        case accessibility, inputMonitoring
        var urlString: String {
            switch self {
            case .accessibility:
                return "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            case .inputMonitoring:
                return "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
            }
        }
    }

    func openSettings(_ pane: Pane) {
        if let url = URL(string: pane.urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Monitoring

    /// While the scroll feature is enabled, poll once a second so that a grant
    /// (e.g. the user flipping the System Settings switch) starts the tap, and a
    /// revocation stops it — both via `onChange`. Cheap; only runs while needed.
    func startMonitoring() {
        guard monitorTask == nil else { return }
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                self.refresh()
            }
        }
    }

    func stopMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
    }
}

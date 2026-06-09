import AppKit
import ApplicationServices

/// Tracks the single TCC permission the scroll feature needs: **Accessibility**,
/// which lets us create an event tap that observes and modifies scroll events.
///
/// Mouse/scroll/gesture taps do *not* require Input Monitoring — that permission
/// gates keyboard monitoring — so we don't ask for it. Keep Awake needs nothing.
@MainActor
@Observable
final class PermissionsManager {
    private(set) var accessibilityGranted = false

    /// Invoked whenever the grant state actually changes (granted or revoked).
    /// The model uses this to start/stop the scroll tap.
    var onChange: (() -> Void)?

    private var monitorTask: Task<Void, Never>?

    init() {
        refresh()
    }

    /// Re-read the current grant state (cheap, no prompt). Fires `onChange` only
    /// when it actually flips.
    func refresh() {
        let trusted = AXIsProcessTrusted()
        guard trusted != accessibilityGranted else { return }
        accessibilityGranted = trusted
        onChange?()
    }

    // MARK: Requests

    /// Show the system Accessibility prompt. A no-op (returns true, no prompt) if
    /// the process is already trusted.
    func requestAccessibility() {
        // `kAXTrustedCheckOptionPrompt` is imported as a non-concurrency-safe
        // global; its value is the stable string "AXTrustedCheckOptionPrompt".
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Deep-link straight to the Accessibility pane (the reliable path once the
    /// one-shot system prompt has already been shown).
    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Monitoring

    /// Poll *only while the grant is pending* — to catch the user flipping the
    /// System Settings switch — then stop. Nothing to watch once granted, so the
    /// process isn't kept awake in steady state. Capped so an "enabled but never
    /// granted" state can't poll forever; the menu's grant action restarts it.
    func startMonitoring() {
        guard monitorTask == nil, !accessibilityGranted else { return }
        monitorTask = Task { [weak self] in
            for _ in 0..<240 {                       // ~120s at 500ms
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, !Task.isCancelled else { return }
                self.refresh()
                if self.accessibilityGranted { break }
            }
            self?.monitorTask = nil
        }
    }

    func stopMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
    }
}

import SwiftUI
import AppKit
import Observation

/// The single source of truth for the whole app and the only writer of side
/// effects. SwiftUI scenes read it; feature controllers are owned and driven by
/// it. Everything here runs on the main actor — the menu UI, the IOKit power
/// assertion, and (later) the event-tap run loop all live on the main thread.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    // MARK: Keep Awake
    /// Whether a power assertion is currently held. Transient by design — a mode
    /// the user turns on deliberately for a session, not restored on next launch.
    private(set) var isKeepingAwake = false
    /// Which preset is active (for menu checkmarks), or nil when off.
    private(set) var keepAwakeDuration: KeepAwakeDuration?

    // MARK: Scroll reversal (persisted)
    private(set) var reverseEnabled = false
    private(set) var reverseMouse = true
    private(set) var reverseTrackpad = false

    // MARK: System
    /// Mirrors `SMAppService` state; the OS is the source of truth.
    private(set) var startAtLogin = false
    /// Whether the menu-bar icon is hidden. Re-shown by reopening the app.
    private(set) var hideIcon = false
    /// Convenience for `MenuBarExtra(isInserted:)`.
    var showIcon: Bool { !hideIcon }

    // MARK: Controllers
    private let keepAwake = KeepAwakeController()
    private let scrollTap = ScrollTap()
    let permissions = PermissionsManager()

    /// Both TCC permissions present — the precondition for running the scroll tap.
    var permissionsOK: Bool { permissions.allGranted }

    private init() {}

    /// One-time setup, called from the app delegate after launch.
    func start() {
        // Agent app: no Dock icon, no app-switcher entry. `LSUIElement` already
        // does this for the bundled app; setting it explicitly keeps the policy
        // correct even when the binary is launched directly.
        NSApp.setActivationPolicy(.accessory)

        Defaults.registerDefaults()
        reverseEnabled = Defaults.reverseEnabled
        reverseMouse = Defaults.reverseMouse
        reverseTrackpad = Defaults.reverseTrackpad
        hideIcon = Defaults.hideIcon
        startAtLogin = LaunchAtLogin.isEnabled

        // Start/stop the tap whenever permissions change (granted via the system
        // prompt, or revoked at runtime).
        permissions.onChange = { [weak self] in self?.updateScrollTapRunning() }
        permissions.refresh()

        // Rebuild the (potentially dead) taps after the Mac wakes from sleep,
        // rather than relaunching the whole app like the legacy version did.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleWake() }
        }

        // If reversal was left on from a previous session, resume monitoring and
        // (if permitted) start the tap immediately.
        if reverseEnabled { permissions.startMonitoring() }
        applyScrollConfig()
    }

    // MARK: Keep Awake intent

    func startKeepAwake(_ duration: KeepAwakeDuration) {
        keepAwakeDuration = duration
        isKeepingAwake = true
        if let seconds = duration.seconds {
            keepAwake.enable(forDuration: seconds) { [weak self] in
                self?.syncKeepAwakeOff()
            }
        } else {
            keepAwake.enable()
        }
    }

    func stopKeepAwake() {
        keepAwake.disable()
        syncKeepAwakeOff()
    }

    func setKeepAwake(_ on: Bool) {
        on ? startKeepAwake(.indefinite) : stopKeepAwake()
    }

    private func syncKeepAwakeOff() {
        isKeepingAwake = false
        keepAwakeDuration = nil
    }

    // MARK: Scroll intent (persisted; effects wired in M5)

    func setReverseEnabled(_ v: Bool) {
        reverseEnabled = v
        Defaults.reverseEnabled = v
        if v {
            if !permissions.allGranted { permissions.requestMissing() }
            permissions.startMonitoring()   // picks up a later grant or revocation
        } else {
            permissions.stopMonitoring()
        }
        applyScrollConfig()
    }
    func setReverseMouse(_ v: Bool) {
        reverseMouse = v
        Defaults.reverseMouse = v
        applyScrollConfig()
    }
    func setReverseTrackpad(_ v: Bool) {
        reverseTrackpad = v
        Defaults.reverseTrackpad = v
        applyScrollConfig()
    }

    /// Push current settings into the tap and start/stop it as appropriate.
    private func applyScrollConfig() {
        scrollTap.config = ReverseConfig(
            enabled: reverseEnabled,
            reverseMouse: reverseMouse,
            reverseTrackpad: reverseTrackpad
        )
        updateScrollTapRunning()
    }

    private func updateScrollTapRunning() {
        if reverseEnabled && permissionsOK {
            scrollTap.start()
        } else {
            scrollTap.stop()
        }
    }

    /// Rebuild the taps after waking from sleep. We deliberately do *not* force
    /// `reverseEnabled` off on permission revocation: the user's intent is kept,
    /// the tap is stopped (via `onChange`), the menu shows "Grant Scroll
    /// Permissions…", and reversal auto-resumes once the grant returns.
    func handleWake() {
        permissions.refresh()
        scrollTap.rebuildAfterWake()
    }

    // MARK: System intent

    func setStartAtLogin(_ v: Bool) {
        LaunchAtLogin.set(v)
        startAtLogin = LaunchAtLogin.isEnabled   // re-read; OS is authoritative
    }

    func setHideIcon(_ v: Bool) {
        hideIcon = v
        Defaults.hideIcon = v
    }

    /// Make the menu-bar icon visible again. Called when the app is reopened, so a
    /// hidden icon can never lock the user out.
    func revealIcon() {
        if hideIcon { setHideIcon(false) }
    }

    // MARK: Menu-bar glyph

    /// Reflects the keep-awake mode so the user can see at a glance that sleep is
    /// being held. (Proper custom artwork lands in M7.)
    var menuBarSymbolName: String {
        isKeepingAwake ? "computermouse.fill" : "computermouse"
    }
}

import AppKit
import Observation

/// The single source of truth for the whole app and the only writer of side
/// effects. SwiftUI scenes read it; feature controllers are owned and driven by
/// it. Everything here runs on the main actor — the menu UI, the IOKit power
/// assertion, and the event-tap run loop all live on the main thread.
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
    /// When a timed Keep Awake will end (nil when indefinite or off). Internal —
    /// the menu reads `keepAwakeRemainingMinutes`, not this.
    @ObservationIgnored private var keepAwakeExpiry: Date?
    /// Whole minutes left on a timed Keep Awake, shown in the menu (nil otherwise).
    private(set) var keepAwakeRemainingMinutes: Int?
    @ObservationIgnored private var countdownTask: Task<Void, Never>?

    // MARK: Scroll reversal (persisted) — two independent toggles, no master switch.
    private(set) var reverseMouse = false
    private(set) var reverseTrackpad = false
    /// The tap should run when either source is being reversed.
    var anyReverseEnabled: Bool { reverseMouse || reverseTrackpad }

    // MARK: Safari navigation (persisted)
    /// Map the mouse back/forward side buttons to Safari Back/Forward.
    private(set) var safariNavButtons = false

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
    private let safariNav = SafariNavController()
    private let updateChecker = UpdateChecker()
    private let permissions = PermissionsManager()

    /// Accessibility granted — the precondition for running the event taps.
    var permissionsOK: Bool { permissions.accessibilityGranted }
    /// A tap feature is enabled but Accessibility isn't granted yet.
    var needsAccessibilityGrant: Bool {
        (anyReverseEnabled || safariNavButtons) && !permissionsOK
    }

    private init() {}

    /// One-time setup, called from the app delegate after launch.
    func start() {
        // Agent app: no Dock icon, no app-switcher entry. `LSUIElement` already
        // does this for the bundled app; setting it explicitly keeps the policy
        // correct even when the binary is launched directly.
        NSApp.setActivationPolicy(.accessory)

        Defaults.registerDefaults()
        reverseMouse = Defaults.reverseMouse
        reverseTrackpad = Defaults.reverseTrackpad
        safariNavButtons = Defaults.safariNavButtons
        hideIcon = Defaults.hideIcon
        startAtLogin = LaunchAtLogin.isEnabled

        // Start/stop the taps whenever permissions change (granted via the system
        // prompt, or revoked at runtime).
        permissions.onChange = { [weak self] in self?.reconcileTaps() }
        permissions.refresh()

        // Rebuild the (potentially dead) taps after the Mac wakes from sleep.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleWake() }
        }

        // TCC has no change notification, so instead of a standing timer we
        // re-check permissions exactly when the menu opens — the only moment a
        // stale value is visible. Catches a runtime revocation (menu then offers
        // "Grant Scroll Permissions…") and a late grant (tap starts), at zero
        // idle cost.
        NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.permissions.refresh() }
        }

        // If a tap feature was left on from a previous session, watch for a grant
        // only if one is still pending; otherwise the taps just start immediately.
        if (anyReverseEnabled || safariNavButtons) && !permissions.accessibilityGranted {
            permissions.startMonitoring()
        }
        reconcileTaps()
    }

    // MARK: Keep Awake intent

    func startKeepAwake(_ duration: KeepAwakeDuration) {
        keepAwakeDuration = duration
        isKeepingAwake = true
        if let seconds = duration.seconds {
            keepAwakeExpiry = Date().addingTimeInterval(seconds)
            startCountdown()
            keepAwake.enable(forDuration: seconds) { [weak self] in
                self?.syncKeepAwakeOff()
            }
        } else {
            keepAwakeExpiry = nil
            keepAwakeRemainingMinutes = nil
            stopCountdown()
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
        keepAwakeExpiry = nil
        keepAwakeRemainingMinutes = nil
        stopCountdown()
    }

    // MARK: Keep Awake countdown
    // Ticks only while a timed session is active — and during keep-awake the Mac
    // is held awake anyway, so a slow timer here costs nothing meaningful.

    private func startCountdown() {
        stopCountdown()
        updateRemainingMinutes()
        countdownTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self, !Task.isCancelled else { return }
                self.updateRemainingMinutes()
            }
        }
    }

    private func stopCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
    }

    private func updateRemainingMinutes() {
        guard let expiry = keepAwakeExpiry else { keepAwakeRemainingMinutes = nil; return }
        let remaining = expiry.timeIntervalSinceNow
        let minutes = remaining > 0 ? Int((remaining / 60).rounded(.up)) : 0
        if keepAwakeRemainingMinutes != minutes { keepAwakeRemainingMinutes = minutes }
    }

    /// "Keep Awake", or "Keep Awake — 1 hr 29 min left" during a timed session.
    var keepAwakeMenuLabel: String {
        guard let total = keepAwakeRemainingMinutes, total > 0 else { return "Keep Awake" }
        let hours = total / 60
        let minutes = total % 60
        let time: String
        if hours == 0 {
            time = "\(minutes) min"
        } else if minutes == 0 {
            time = "\(hours) hr"
        } else {
            time = "\(hours) hr \(minutes) min"
        }
        return "Keep Awake — \(time) left"
    }

    // MARK: Input feature intent (persisted)

    func setReverseMouse(_ v: Bool) {
        reverseMouse = v
        Defaults.reverseMouse = v
        featureSettingsChanged()
    }

    func setReverseTrackpad(_ v: Bool) {
        reverseTrackpad = v
        Defaults.reverseTrackpad = v
        featureSettingsChanged()
    }

    func setSafariNavButtons(_ v: Bool) {
        safariNavButtons = v
        Defaults.safariNavButtons = v
        featureSettingsChanged()
    }

    /// Common handling after any tap feature toggles: request Accessibility the
    /// first time one is enabled, watch for the grant until it lands, and
    /// reconcile the taps.
    private func featureSettingsChanged() {
        if anyReverseEnabled || safariNavButtons {
            if !permissions.accessibilityGranted {
                permissions.requestAccessibility()   // system prompt
                permissions.startMonitoring()         // watch only until it lands
            }
        } else {
            permissions.stopMonitoring()
        }
        reconcileTaps()
    }

    /// Open Accessibility settings and resume watching for the grant (used by the
    /// menu's "Grant Accessibility Access…" action — the reliable path after the
    /// one-shot system prompt has already been shown).
    func requestAccessibilityGrant() {
        permissions.openAccessibilitySettings()
        permissions.startMonitoring()
    }

    /// Push current settings into the taps and start/stop each as appropriate.
    private func reconcileTaps() {
        scrollTap.config = ReverseConfig(
            enabled: anyReverseEnabled,
            reverseMouse: reverseMouse,
            reverseTrackpad: reverseTrackpad
        )
        let permitted = permissionsOK
        if anyReverseEnabled && permitted { scrollTap.start() } else { scrollTap.stop() }
        if safariNavButtons && permitted { safariNav.start() } else { safariNav.stop() }
    }

    /// Rebuild the taps after waking from sleep. We deliberately do *not* turn the
    /// reverse toggles off on permission revocation: the user's intent is kept,
    /// the tap is stopped (via `onChange`), the menu shows "Grant Accessibility
    /// Access…", and reversal auto-resumes once the grant returns.
    func handleWake() {
        permissions.refresh()
        scrollTap.rebuildAfterWake()
        safariNav.rebuildAfterWake()
    }

    // MARK: Updates

    func checkForUpdates() {
        updateChecker.checkForUpdates()
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
    /// being held.
    var menuBarSymbolName: String {
        isKeepingAwake ? "computermouse.fill" : "computermouse"
    }
}

import AppKit
@preconcurrency import CoreGraphics

/// Translates a mouse's back/forward side buttons (buttons 3 and 4) into Safari's
/// Back/Forward shortcuts (⌘← / ⌘→) — but **only while Safari is frontmost**.
/// Every other app is left completely alone: its button events pass straight
/// through, and we make no decisions about them.
///
/// ⌘-arrow is used rather than ⌘[ / ⌘] because the arrow key codes are identical
/// on every keyboard layout.
@MainActor
final class SafariNavController {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var safariIsFrontmost = false
    private let keySource = CGEventSource(stateID: .hidSystemState)

    private static let safariBundleID = "com.apple.Safari"
    private static let leftArrow: CGKeyCode = 123    // kVK_LeftArrow
    private static let rightArrow: CGKeyCode = 124   // kVK_RightArrow
    private static let backButton: Int64 = 3
    private static let forwardButton: Int64 = 4

    var isRunning: Bool { tap != nil }

    init() {
        safariIsFrontmost = Self.isSafariFront()
        // Cache the frontmost app so the hot path is a plain bool, not a lookup.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.safariIsFrontmost = Self.isSafariFront() }
        }
    }

    private static func isSafariFront() -> Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == safariBundleID
    }

    // MARK: Lifecycle

    func start() {
        guard tap == nil else { return }
        let mask = (CGEventMask(1) << CGEventType.otherMouseDown.rawValue)
                 | (CGEventMask(1) << CGEventType.otherMouseUp.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: safariNavCallback,
            userInfo: refcon
        ) else {
            NSLog("MacSanity: could not create Safari-nav tap (missing permissions?)")
            return
        }
        tap = port
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil
        tap = nil
    }

    func rebuildAfterWake() {
        guard isRunning else { return }
        stop()
        start()
    }

    // MARK: Hot path (main run loop, via the C trampoline)

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .otherMouseDown, .otherMouseUp:
            // Only Safari. For anything else we do nothing — the event flows on.
            guard safariIsFrontmost else { return Unmanaged.passUnretained(event) }
            let button = event.getIntegerValueField(.mouseEventButtonNumber)
            guard button == Self.backButton || button == Self.forwardButton else {
                return Unmanaged.passUnretained(event)
            }
            if type == .otherMouseDown {
                postCmdArrow(back: button == Self.backButton)
            }
            return nil   // swallow the side-button event (both down and up)

        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func postCmdArrow(back: Bool) {
        let key = back ? Self.leftArrow : Self.rightArrow
        for keyDown in [true, false] {
            let e = CGEvent(keyboardEventSource: keySource, virtualKey: key, keyDown: keyDown)
            e?.flags = .maskCommand
            e?.post(tap: .cghidEventTap)
        }
    }
}

/// Top-level C trampoline. Runs on the main run loop (the source is installed
/// there), so assuming main-actor isolation is sound.
private func safariNavCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let controller = Unmanaged<SafariNavController>.fromOpaque(refcon).takeUnretainedValue()
    return MainActor.assumeIsolated { controller.handle(type: type, event: event) }
}

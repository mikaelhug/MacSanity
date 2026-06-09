import AppKit
@preconcurrency import CoreGraphics
import CMacSanitySPI
import MacSanityCore

/// Snapshot of the reversal settings read by the hot path — plain scalars, so the
/// scroll callback never touches UserDefaults, the model, or the main actor's
/// observable state.
struct ReverseConfig {
    var enabled = false
    var reverseMouse = false
    var reverseTrackpad = false
}

/// Owns the two session-level event taps and the scroll hot path.
///
///  • A *passive* listen-only tap on gesture events counts fingers on the trackpad.
///  • An *active* tap on scroll-wheel events reverses them when appropriate.
///
/// Both taps run on the main run loop, so all state here is touched on the main
/// thread; the C trampoline below enters via `MainActor.assumeIsolated`.
@MainActor
final class ScrollTap {
    var config = ReverseConfig()

    private var activeTap: CFMachPort?
    private var passiveTap: CFMachPort?
    private var activeSource: CFRunLoopSource?
    private var passiveSource: CFRunLoopSource?

    private let touch = ScrollTouchTracker()
    private var lastSource: ScrollSource = .mouse

    var isRunning: Bool { activeTap != nil }

    // MARK: Lifecycle

    func start() {
        guard activeTap == nil else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        let scrollMask = CGEventMask(1) << UInt64(CGEventType.scrollWheel.rawValue)
        guard let active = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .defaultTap,
            eventsOfInterest: scrollMask,
            callback: scrollTapCallback,
            userInfo: refcon
        ) else {
            NSLog("MacSanity: could not create scroll tap (missing permissions?)")
            return
        }

        let gestureMask = CGEventMask(1) << UInt64(NSEvent.EventType.gesture.rawValue)
        let passive = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: gestureMask,
            callback: scrollTapCallback,
            userInfo: refcon
        )

        let runLoop = CFRunLoopGetMain()

        activeTap = active
        activeSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, active, 0)
        CFRunLoopAddSource(runLoop, activeSource, .commonModes)
        CGEvent.tapEnable(tap: active, enable: true)

        if let passive {
            passiveTap = passive
            passiveSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, passive, 0)
            CFRunLoopAddSource(runLoop, passiveSource, .commonModes)
            CGEvent.tapEnable(tap: passive, enable: true)
        }
    }

    func stop() {
        let runLoop = CFRunLoopGetMain()
        if let activeSource { CFRunLoopRemoveSource(runLoop, activeSource, .commonModes) }
        if let passiveSource { CFRunLoopRemoveSource(runLoop, passiveSource, .commonModes) }
        if let activeTap { CFMachPortInvalidate(activeTap) }
        if let passiveTap { CFMachPortInvalidate(passiveTap) }
        activeSource = nil
        passiveSource = nil
        activeTap = nil
        passiveTap = nil
    }

    /// After waking from sleep the taps can be dead; rebuild them if we were running.
    func rebuildAfterWake() {
        guard isRunning else { return }
        stop()
        start()
    }

    // MARK: Hot path (main run loop, via the C trampoline)

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent> {
        switch type {
        case .scrollWheel:
            handleScroll(event)
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            reEnable()
        default:
            if type.rawValue == UInt32(NSEvent.EventType.gesture.rawValue) {
                handleGesture(event)
            }
        }
        return Unmanaged.passUnretained(event)
    }

    private func handleGesture(_ event: CGEvent) {
        // The only per-event NSEvent allocation, and only on (low-frequency) gesture
        // events — there is no public CGEvent field for the touch count.
        guard let ns = NSEvent(cgEvent: event) else { return }
        let count = ns.touches(matching: .touching, in: nil).count
        touch.recordTouch(count: count, atNs: touch.nowNs())
    }

    private func handleScroll(_ event: CGEvent) {
        let cfg = config
        guard cfg.enabled else { return }

        // Read everything straight from CGEvent fields — no NSEvent allocation.
        let continuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
        let isNormalPhase = event.getIntegerValueField(.scrollWheelEventMomentumPhase) == 0

        let now = touch.nowNs()
        let touching = touch.consumeTouching()
        let elapsed = now >= touch.lastTouchTimeNs ? now - touch.lastTouchTimeNs : .max

        let source = ScrollClassifier.classify(
            continuous: continuous,
            touching: touching,
            touchElapsedNs: elapsed,
            isNormalPhase: isNormalPhase,
            last: lastSource
        )
        lastSource = source

        let reverse = (source == .mouse) ? cfg.reverseMouse : cfg.reverseTrackpad
        guard reverse else { return }

        // Minimal scope: reverse the vertical axis, leave horizontal natural.
        MSReverseScroll(event, true, false)
    }

    private func reEnable() {
        if let activeTap { CGEvent.tapEnable(tap: activeTap, enable: true) }
        if let passiveTap { CGEvent.tapEnable(tap: passiveTap, enable: true) }
    }
}

/// Top-level C trampoline for both taps. It runs on the main run loop (that's
/// where the sources are installed), so assuming main-actor isolation is sound.
private func scrollTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<ScrollTap>.fromOpaque(refcon).takeUnretainedValue()
    return MainActor.assumeIsolated {
        tap.handle(type: type, event: event)
    }
}

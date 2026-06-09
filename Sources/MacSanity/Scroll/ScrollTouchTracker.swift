import Foundation

/// Tracks recent multi-finger touches reported by the passive gesture tap, so the
/// scroll tap can distinguish trackpad input from mouse input. Touched only from
/// the main run loop (both taps live there), so it needs no locking.
final class ScrollTouchTracker {
    private(set) var touching: Int = 0
    private(set) var lastTouchTimeNs: UInt64 = 0

    /// Monotonic uptime in nanoseconds. Doesn't advance while the Mac is asleep,
    /// which is exactly what we want for "time since last touch".
    func nowNs() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    }

    /// Record fingers seen on the trackpad. Only 2+ matters for detection.
    func recordTouch(count: Int, atNs now: UInt64) {
        guard count >= 2 else { return }
        lastTouchTimeNs = now
        touching = max(touching, count)
    }

    /// Read and clear the touch count for the next scroll event.
    func consumeTouching() -> Int {
        defer { touching = 0 }
        return touching
    }
}

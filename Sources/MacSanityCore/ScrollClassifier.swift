/// Where a scroll event came from.
public enum ScrollSource: Equatable, Sendable {
    case mouse
    case trackpad
}

/// Decides whether a scroll event is from a mouse or a trackpad. Pure and
/// side-effect-free, so it is unit tested without any hardware or permissions.
/// Lives in its own library target precisely so the tests never have to link the
/// GUI app.
public enum ScrollClassifier {
    /// Two-plus fingers count as "trackpad" only if seen this recently (ns).
    public static let touchRecencyNs: UInt64 = 222_000_000          // 222 ms
    /// In a normal (non-momentum) phase, no touch for this long (ns) means mouse.
    public static let normalPhaseStaleNs: UInt64 = 333_000_000      // 333 ms

    /// - Parameters:
    ///   - continuous: `kCGScrollWheelEventIsContinuous` — false for discrete wheels.
    ///   - touching: fingers seen on the passive gesture tap since the last event.
    ///   - touchElapsedNs: time since the last 2+ finger touch.
    ///   - isNormalPhase: true when not in a momentum/transition phase.
    ///   - last: the previously detected source (used to break ties).
    public static func classify(
        continuous: Bool,
        touching: Int,
        touchElapsedNs: UInt64,
        isNormalPhase: Bool,
        last: ScrollSource
    ) -> ScrollSource {
        // 1. Discrete wheel ticks only ever come from a mouse.
        if !continuous { return .mouse }
        // 2. Two-plus fingers on the pad just now → trackpad.
        if touching >= 2 && touchElapsedNs < touchRecencyNs { return .trackpad }
        // 3. Actively scrolling with no recent touch → mouse.
        if isNormalPhase && touchElapsedNs > normalPhaseStaleNs { return .mouse }
        // 4. Ambiguous → assume the same device as last time.
        return last
    }
}

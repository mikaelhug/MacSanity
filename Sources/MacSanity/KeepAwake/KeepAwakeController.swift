import Foundation
import IOKit
import IOKit.pwr_mgt

/// How long Keep Awake should stay on.
enum KeepAwakeDuration: Hashable {
    case indefinite
    case interval(Int)   // total seconds

    /// Number of seconds, or nil for indefinite.
    var seconds: TimeInterval? {
        switch self {
        case .indefinite: return nil
        case .interval(let s): return TimeInterval(s)
        }
    }
}

/// Prevents the display (and therefore the system) from idle-sleeping by holding
/// a single IOKit power assertion. A held assertion needs no renewal timer — it
/// stays in effect until released.
@MainActor
final class KeepAwakeController {
    private var assertionID: IOPMAssertionID = IOPMAssertionID(0)
    private var hasAssertion = false
    private var expiryTask: Task<Void, Never>?

    private static let assertionReason = "MacSanity is keeping your Mac awake" as CFString

    /// Hold the assertion until explicitly disabled.
    func enable() {
        cancelExpiry()
        createAssertionIfNeeded()
    }

    /// Hold the assertion for a fixed duration, then auto-release.
    /// `onExpire` runs on the main actor when the timer fires (not when the
    /// caller releases early), letting the model sync its own state back.
    func enable(forDuration seconds: TimeInterval, onExpire: @escaping @MainActor () -> Void) {
        createAssertionIfNeeded()
        cancelExpiry()
        expiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.disable()
            onExpire()
        }
    }

    /// Release the assertion (and cancel any pending auto-release).
    func disable() {
        cancelExpiry()
        guard hasAssertion else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = IOPMAssertionID(0)
        hasAssertion = false
    }

    // MARK: - Private

    private func createAssertionIfNeeded() {
        guard !hasAssertion else { return }
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            Self.assertionReason,
            &id
        )
        if result == kIOReturnSuccess {
            assertionID = id
            hasAssertion = true
        }
    }

    private func cancelExpiry() {
        expiryTask?.cancel()
        expiryTask = nil
    }
}

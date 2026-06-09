// Standalone checks for ScrollClassifier. Run with `swift run ClassifierCheck`.
// Exits 0 if all pass, 1 otherwise. (Used in place of XCTest, which isn't
// available with Command Line Tools.)

import Foundation
import MacSanityCore

var failures = 0
@MainActor func check(_ name: String, _ got: ScrollSource, _ want: ScrollSource) {
    if got == want {
        print("PASS  \(name)")
    } else {
        print("FAIL  \(name): got \(got), want \(want)")
        failures += 1
    }
}

// 1. Discrete (non-continuous) input is always a mouse.
check("discreteIsAlwaysMouse",
      ScrollClassifier.classify(continuous: false, touching: 5, touchElapsedNs: 0,
                                isNormalPhase: true, last: .trackpad), .mouse)

// 2. Continuous with 2+ recent fingers → trackpad.
check("recentMultiTouchIsTrackpad",
      ScrollClassifier.classify(continuous: true, touching: 2, touchElapsedNs: 10_000_000,
                                isNormalPhase: true, last: .mouse), .trackpad)

// 2b. A 2-finger touch older than the 333 ms stale threshold, in a normal phase,
// is treated as a mouse (rule 3). (400 ms is past both the 222 ms recency window
// and the 333 ms stale threshold.)
check("staleMultiTouchBecomesMouse",
      ScrollClassifier.classify(continuous: true, touching: 2, touchElapsedNs: 400_000_000,
                                isNormalPhase: true, last: .trackpad), .mouse)

// 2c. In the gap between the two thresholds (222–333 ms), with no other signal,
// the classifier holds the previous source — neither rule 2 nor rule 3 fires.
check("betweenThresholdsKeepsLast",
      ScrollClassifier.classify(continuous: true, touching: 2, touchElapsedNs: 300_000_000,
                                isNormalPhase: true, last: .trackpad), .trackpad)

// 3. Continuous, normal phase, no recent touch → mouse.
check("continuousNoTouchNormalPhaseIsMouse",
      ScrollClassifier.classify(continuous: true, touching: 0, touchElapsedNs: 1_000_000_000,
                                isNormalPhase: true, last: .trackpad), .mouse)

// 4. Ambiguous (continuous, no touch, momentum phase) → keep last source.
check("ambiguousKeepsLastTrackpad",
      ScrollClassifier.classify(continuous: true, touching: 0, touchElapsedNs: 1_000_000_000,
                                isNormalPhase: false, last: .trackpad), .trackpad)
check("ambiguousKeepsLastMouse",
      ScrollClassifier.classify(continuous: true, touching: 0, touchElapsedNs: 1_000_000_000,
                                isNormalPhase: false, last: .mouse), .mouse)

// A single finger is not enough to call it a trackpad.
check("singleTouchIsNotTrackpad",
      ScrollClassifier.classify(continuous: true, touching: 1, touchElapsedNs: 10_000_000,
                                isNormalPhase: false, last: .mouse), .mouse)

// Boundary: exactly at the recency window is NOT recent (strict <).
check("recencyBoundaryIsExclusive",
      ScrollClassifier.classify(continuous: true, touching: 2,
                                touchElapsedNs: ScrollClassifier.touchRecencyNs,
                                isNormalPhase: false, last: .mouse), .mouse)

if failures == 0 {
    print("\nAll classifier checks passed.")
} else {
    print("\n\(failures) classifier check(s) FAILED.")
    exit(1)
}

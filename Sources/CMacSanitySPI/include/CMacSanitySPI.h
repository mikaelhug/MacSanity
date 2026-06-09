//  CMacSanitySPI.h
//
//  The one C entry point Swift needs for scroll reversal. The private SPI
//  declarations it relies on (CGEventCopyIOHIDEvent + IOHIDEvent get/set float)
//  are kept inside the .c file so they never leak into the Swift module surface.

#ifndef CMacSanitySPI_h
#define CMacSanitySPI_h

#include <CoreGraphics/CoreGraphics.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Reverse the scroll deltas on a CGEvent, in place.
///
/// Flips both the CGEvent delta fields (Delta, then FixedPt and Point — the order
/// macOS expects, since it recomputes the latter two from Delta) and the values
/// on the underlying IOHIDEvent, so apps reading either path see the reversal.
/// Memory management of the copied IOHIDEvent is handled internally.
void MSReverseScroll(CGEventRef event, bool reverseVertical, bool reverseHorizontal);

#ifdef __cplusplus
}
#endif

#endif /* CMacSanitySPI_h */

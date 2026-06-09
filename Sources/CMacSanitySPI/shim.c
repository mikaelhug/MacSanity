//  shim.c — scroll reversal implemented in C.
//
//  Keeping this in C means the private SPI symbols and the +1 IOHIDEvent
//  ownership stay confined here, and Swift sees only MSReverseScroll().

#include "CMacSanitySPI.h"
#include <CoreFoundation/CoreFoundation.h>
#include <stdint.h>

// ---- Private SPI (resolved at link time from CoreGraphics / IOKit) ----

typedef struct __IOHIDEvent *IOHIDEventRef;
typedef uint32_t IOHIDEventField;
typedef double   IOHIDFloat;   // macOS is 64-bit only.

// Scroll field selectors: (eventType << 16) | axis ; kIOHIDEventTypeScroll == 6,
// axis 0 = X (horizontal), axis 1 = Y (vertical).
enum { kMSIOHIDEventTypeScroll = 6 };
static const IOHIDEventField kMSScrollFieldX = (kMSIOHIDEventTypeScroll << 16) | 0;
static const IOHIDEventField kMSScrollFieldY = (kMSIOHIDEventTypeScroll << 16) | 1;

extern IOHIDFloat IOHIDEventGetFloatValue(IOHIDEventRef event, IOHIDEventField field);
extern void       IOHIDEventSetFloatValue(IOHIDEventRef event, IOHIDEventField field, IOHIDFloat value);
extern IOHIDEventRef CGEventCopyIOHIDEvent(CGEventRef event);

void MSReverseScroll(CGEventRef event, bool reverseVertical, bool reverseHorizontal) {
    // CGEvent fields. DeltaAxis must be written first: macOS recomputes Point (8x)
    // and FixedPt (1x) from it, so writing Delta last would clobber smooth scroll.
    if (reverseVertical) {
        int64_t delta = CGEventGetIntegerValueField(event, kCGScrollWheelEventDeltaAxis1);
        double  fixed = CGEventGetDoubleValueField(event,  kCGScrollWheelEventFixedPtDeltaAxis1);
        int64_t point = CGEventGetIntegerValueField(event, kCGScrollWheelEventPointDeltaAxis1);
        CGEventSetIntegerValueField(event, kCGScrollWheelEventDeltaAxis1,        -delta);
        CGEventSetDoubleValueField(event,  kCGScrollWheelEventFixedPtDeltaAxis1, -fixed);
        CGEventSetIntegerValueField(event, kCGScrollWheelEventPointDeltaAxis1,   -point);
    }
    if (reverseHorizontal) {
        int64_t delta = CGEventGetIntegerValueField(event, kCGScrollWheelEventDeltaAxis2);
        double  fixed = CGEventGetDoubleValueField(event,  kCGScrollWheelEventFixedPtDeltaAxis2);
        int64_t point = CGEventGetIntegerValueField(event, kCGScrollWheelEventPointDeltaAxis2);
        CGEventSetIntegerValueField(event, kCGScrollWheelEventDeltaAxis2,        -delta);
        CGEventSetDoubleValueField(event,  kCGScrollWheelEventFixedPtDeltaAxis2, -fixed);
        CGEventSetIntegerValueField(event, kCGScrollWheelEventPointDeltaAxis2,   -point);
    }

    // Underlying IOHIDEvent. CGEventCopyIOHIDEvent returns +1 — release when done.
    IOHIDEventRef hid = CGEventCopyIOHIDEvent(event);
    if (hid) {
        if (reverseVertical) {
            IOHIDFloat y = IOHIDEventGetFloatValue(hid, kMSScrollFieldY);
            IOHIDEventSetFloatValue(hid, kMSScrollFieldY, -y);
        }
        if (reverseHorizontal) {
            // Uses the horizontal field — the legacy app had a bug here, flipping
            // X by the vertical multiplier.
            IOHIDFloat x = IOHIDEventGetFloatValue(hid, kMSScrollFieldX);
            IOHIDEventSetFloatValue(hid, kMSScrollFieldX, -x);
        }
        CFRelease(hid);
    }
}

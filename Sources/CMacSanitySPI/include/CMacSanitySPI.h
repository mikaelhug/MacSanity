//  CMacSanitySPI.h
//
//  The one C entry point Swift needs for scroll reversal. The private SPI
//  declarations it relies on (CGEventCopyIOHIDEvent + IOHIDEvent get/set float)
//  are kept inside the .c file so they never leak into the Swift module surface.

#ifndef CMacSanitySPI_h
#define CMacSanitySPI_h

#include <CoreGraphics/CoreGraphics.h>
#include <IOKit/IOKitLib.h>
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Reverse the scroll deltas on a CGEvent, in place.
///
/// Flips both the CGEvent delta fields (Delta, then FixedPt and Point — the order
/// macOS expects, since it recomputes the latter two from Delta) and the values
/// on the underlying IOHIDEvent, so apps reading either path see the reversal.
/// Memory management of the copied IOHIDEvent is handled internally.
void MSReverseScroll(CGEventRef _Nonnull event, bool reverseVertical, bool reverseHorizontal);

// ---- DDC/CI over the Apple Silicon display coprocessor (see ddc.c) ----

/// Create an AV service for a `DCPAVServiceProxy` registry entry. Returns a +1
/// CF object (release with CFRelease), or NULL if the service can't be opened.
CFTypeRef _Nullable MSAVServiceCreate(io_service_t service) CF_RETURNS_RETAINED;

/// Write a DDC/CI packet (the bytes *after* the 0x51 source address) to the
/// monitor at I2C address 0x37. Returns true when the transfer was accepted.
/// NB: success only means the bytes went out — DDC writes carry no reply.
bool MSDDCWrite(CFTypeRef _Nonnull avService, const uint8_t * _Nonnull packet, uint32_t length);

/// Read a DDC/CI reply of `length` bytes from I2C address 0x37.
bool MSDDCRead(CFTypeRef _Nonnull avService, uint8_t * _Nonnull out, uint32_t length);

/// CoreDisplay's per-display info dictionary (contains "IODisplayLocation", the
/// framebuffer's IOService path). Resolved at runtime; NULL if unavailable.
CFDictionaryRef _Nullable MSCopyDisplayInfoDictionary(CGDirectDisplayID display) CF_RETURNS_RETAINED;

#ifdef __cplusplus
}
#endif

#endif /* CMacSanitySPI_h */

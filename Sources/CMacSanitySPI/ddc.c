//  ddc.c — DDC/CI transport for external displays on Apple Silicon.
//
//  External displays hang off the display coprocessor (DCP); each one exposes a
//  `DCPAVServiceProxy` whose IOAVService can perform raw I2C transfers on the
//  display's DDC channel (DisplayPort AUX / HDMI DDC). These IOAVService symbols
//  are exported by IOKit but absent from the public SDK headers, so — like the
//  scroll SPI in shim.c — they stay confined to this file.

#include "CMacSanitySPI.h"
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>

typedef CFTypeRef IOAVServiceRef;

extern IOAVServiceRef IOAVServiceCreateWithService(CFAllocatorRef allocator, io_service_t service);
extern IOReturn IOAVServiceReadI2C(IOAVServiceRef service, uint32_t chipAddress, uint32_t offset,
                                   void *outputBuffer, uint32_t outputBufferSize);
extern IOReturn IOAVServiceWriteI2C(IOAVServiceRef service, uint32_t chipAddress, uint32_t dataAddress,
                                    void *inputBuffer, uint32_t inputBufferSize);

// DDC/CI: the monitor listens at 7-bit I2C address 0x37; host packets start with
// the source address 0x51, which IOAVService takes as the "data address".
enum { kMSDDCChipAddress = 0x37, kMSDDCHostAddress = 0x51 };

CFTypeRef MSAVServiceCreate(io_service_t service) {
    return IOAVServiceCreateWithService(kCFAllocatorDefault, service);
}

bool MSDDCWrite(CFTypeRef avService, const uint8_t *packet, uint32_t length) {
    return IOAVServiceWriteI2C((IOAVServiceRef)avService, kMSDDCChipAddress, kMSDDCHostAddress,
                               (void *)packet, length) == kIOReturnSuccess;
}

bool MSDDCRead(CFTypeRef avService, uint8_t *out, uint32_t length) {
    return IOAVServiceReadI2C((IOAVServiceRef)avService, kMSDDCChipAddress, 0,
                              out, length) == kIOReturnSuccess;
}

typedef CFDictionaryRef (*MSCoreDisplayInfoFn)(CGDirectDisplayID);

CFDictionaryRef MSCopyDisplayInfoDictionary(CGDirectDisplayID display) {
    static MSCoreDisplayInfoFn fn = NULL;
    static bool resolved = false;
    if (!resolved) {   // main-thread only (display discovery runs on the main actor)
        void *handle = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY);
        if (handle) fn = (MSCoreDisplayInfoFn)dlsym(handle, "CoreDisplay_DisplayCreateInfoDictionary");
        resolved = true;
    }
    return fn ? fn(display) : NULL;
}

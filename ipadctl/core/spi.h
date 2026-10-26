// spi.h - private iOS symbols used by ipadctl, resolved at runtime.
//
// Everything here is resolved with dlopen/dlsym in spi_load() so the binary
// links only against public SDK frameworks, and a missing symbol on some
// future iOS shows up as a clear error instead of a dyld abort.
#pragma once

#import <CoreFoundation/CoreFoundation.h>
#import <IOKit/IOReturn.h>
#import <IOSurface/IOSurfaceRef.h>
#include <mach/mach.h>
#include <stdbool.h>
#include <stdint.h>

// ---- IOKit HID (IOHIDEvent.h / IOHIDEventSystemClient.h are not in the iOS SDK)

typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
typedef double IOHIDFloat;  // arm64: double

enum {
    kIPCHIDTransducerHand = 3,  // kIOHIDDigitizerTransducerTypeHand
};

// IOHIDDigitizerEventMask bits
enum {
    kIPCDigRange = 1u << 0,
    kIPCDigTouch = 1u << 1,
    kIPCDigPosition = 1u << 2,
    kIPCDigIdentity = 1u << 5,
    kIPCDigAttribute = 1u << 6,
    kIPCDigCancel = 1u << 7,
};

// IOHIDEventField values. Field = (eventType << 16) | index.
enum {
    kIPCFieldIsBuiltIn = 0x00004,                  // kIOHIDEventFieldIsBuiltIn
    kIPCFieldDigMajorRadius = 0xB0014,             // kIOHIDEventFieldDigitizerMajorRadius
    kIPCFieldDigMinorRadius = 0xB0015,             // kIOHIDEventFieldDigitizerMinorRadius
    kIPCFieldDigIsDisplayIntegrated = 0xB0019,     // kIOHIDEventFieldDigitizerIsDisplayIntegrated
};

typedef struct {
    // IOKit
    IOHIDEventSystemClientRef (*IOHIDEventSystemClientCreate)(CFAllocatorRef);
    void (*IOHIDEventSystemClientDispatchEvent)(IOHIDEventSystemClientRef, IOHIDEventRef);
    IOHIDEventRef (*IOHIDEventCreateDigitizerEvent)(CFAllocatorRef, uint64_t ts, uint32_t transducer,
                                                    uint32_t index, uint32_t identity, uint32_t eventMask,
                                                    uint32_t buttonMask, IOHIDFloat x, IOHIDFloat y,
                                                    IOHIDFloat z, IOHIDFloat tipPressure,
                                                    IOHIDFloat barrelPressure, Boolean range, Boolean touch,
                                                    uint32_t options);
    IOHIDEventRef (*IOHIDEventCreateDigitizerFingerEvent)(CFAllocatorRef, uint64_t ts, uint32_t index,
                                                          uint32_t identity, uint32_t eventMask,
                                                          IOHIDFloat x, IOHIDFloat y, IOHIDFloat z,
                                                          IOHIDFloat tipPressure, IOHIDFloat twist,
                                                          Boolean range, Boolean touch, uint32_t options);
    IOHIDEventRef (*IOHIDEventCreateKeyboardEvent)(CFAllocatorRef, uint64_t ts, uint32_t page,
                                                   uint32_t usage, Boolean down, uint32_t options);
    void (*IOHIDEventAppendEvent)(IOHIDEventRef parent, IOHIDEventRef child, uint32_t options);
    void (*IOHIDEventSetIntegerValue)(IOHIDEventRef, uint32_t field, CFIndex value);
    void (*IOHIDEventSetFloatValue)(IOHIDEventRef, uint32_t field, IOHIDFloat value);
    void (*IOHIDEventSetSenderID)(IOHIDEventRef, uint64_t sender);

    // QuartzCore: render the composited display into a caller-owned IOSurface.
    void (*CARenderServerRenderDisplay)(mach_port_t server, CFStringRef display, IOSurfaceRef dst,
                                        int32_t x, int32_t y);

    // IOSurfaceAccelerator (hardware 2D scaler / blitter). Optional.
    IOReturn (*IOSurfaceAcceleratorCreate)(CFAllocatorRef, CFDictionaryRef, void **accelOut);
    IOReturn (*IOSurfaceAcceleratorTransferSurface)(void *accel, IOSurfaceRef src, IOSurfaceRef dst,
                                                    CFDictionaryRef options, void *cropRects,
                                                    void *completion, void *refcon);

    // SpringBoardServices. Optional.
    CFStringRef (*SBSCopyFrontmostApplicationDisplayIdentifier)(void);
} ipc_spi_t;

extern ipc_spi_t SPI;

// Resolve everything. Returns false (and prints which symbol) if a required
// symbol is missing. Optional symbols are left NULL.
bool spi_load(void);

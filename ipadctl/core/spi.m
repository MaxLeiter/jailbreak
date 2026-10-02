#import "spi.h"

#include <dlfcn.h>
#include <stdio.h>

ipc_spi_t SPI;

static void *open_fw(const char *path) {
    void *h = dlopen(path, RTLD_NOW | RTLD_GLOBAL);
    if (!h) fprintf(stderr, "spi: dlopen %s failed: %s\n", path, dlerror());
    return h;
}

#define RESOLVE(handle, name, required)                                              \
    do {                                                                             \
        *(void **)&SPI.name = (handle) ? dlsym((handle), #name) : NULL;              \
        if (!SPI.name && (required)) {                                               \
            fprintf(stderr, "spi: missing required symbol %s\n", #name);             \
            ok = false;                                                              \
        }                                                                            \
    } while (0)

bool spi_load(void) {
    static bool loaded, result;
    if (loaded) return result;
    loaded = true;
    bool ok = true;

    void *iokit = open_fw("/System/Library/Frameworks/IOKit.framework/IOKit");
    void *qc = open_fw("/System/Library/Frameworks/QuartzCore.framework/QuartzCore");
    void *accel = open_fw("/System/Library/PrivateFrameworks/IOSurfaceAccelerator.framework/IOSurfaceAccelerator");
    void *sbs = open_fw("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices");
    // FrontBoardServices only provides ObjC classes (FBSOrientationObserver);
    // loading it is enough for NSClassFromString to find them.
    open_fw("/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices");

    RESOLVE(iokit, IOHIDEventSystemClientCreate, true);
    RESOLVE(iokit, IOHIDEventSystemClientDispatchEvent, true);
    RESOLVE(iokit, IOHIDEventCreateDigitizerEvent, true);
    RESOLVE(iokit, IOHIDEventCreateDigitizerFingerEvent, true);
    RESOLVE(iokit, IOHIDEventCreateKeyboardEvent, true);
    RESOLVE(iokit, IOHIDEventAppendEvent, true);
    RESOLVE(iokit, IOHIDEventSetIntegerValue, true);
    RESOLVE(iokit, IOHIDEventSetFloatValue, true);
    RESOLVE(iokit, IOHIDEventSetSenderID, true);

    RESOLVE(qc, CARenderServerRenderDisplay, true);

    RESOLVE(accel, IOSurfaceAcceleratorCreate, false);
    RESOLVE(accel, IOSurfaceAcceleratorTransferSurface, false);

    RESOLVE(sbs, SBSCopyFrontmostApplicationDisplayIdentifier, false);

    result = ok;
    return ok;
}

// HushBFUWake: injected into UserEventAgent.
//
// Bug (iOS 17, see tweaks/_research/calaccessd-bfu-wakes.md): before first
// unlock calaccessd is not running, so UserEventAgent's com.apple.alarm plugin
// keeps firing a stale "com.apple.calaccessd.alarmEngine.alarm.name"
// registration, re-arms it ~60 s out, and calls IOPMRequestSysWake() each time.
// Result: a full system wake about once a minute for as long as the device
// stays BFU.
//
// Fix: hook IOPMRequestSysWake (exported C, IOKit). Skip the wake request only
// when its "scheduledby" requestor names a user-invisible calaccessd alarm AND
// the device has not been unlocked since boot. Everything else calls through.
//
// Static evidence (17.6.1, iPad7,12):
// - com.apple.alarm plugin @0x2bd0..0x2c14 builds the dict with exactly three
//   keys: "time" (CFDate), "scheduledby" (CFString: "com.apple.alarm.user-visible"
//   or "com.apple.alarm.user-invisible", then "-", then the event name), and
//   "UserVisible" (CFBoolean), then calls IOPMRequestSysWake(dict).
// - IOKit's IOPMRequestSysWake @0x18ffc434c takes one CFDictionaryRef, reads
//   "time", "scheduledby", "leeway", "UserVisible", returns IOReturn.
// - MKBDeviceUnlockedSinceBoot @0x1b51da71c returns 1 once unlocked since boot,
//   0 before, and a negative MKB error code if the AppleKeyStore query fails.
//
// UserEventAgent is KeepAlive and critical: a crash here would crash-loop it.
// No ObjC, no allocations in the hook, no per-call logging, and every
// unexpected input falls through to the original.

#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <os/log.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <substrate.h>

#include "HushShared.h"

#define HUSH_BFU_LOADED "com.max.hush.bfuwake.loaded"
#define HUSH_BFU_SUPPRESSED "com.max.hush.bfuwake.suppressed"

#define HUSH_IOKIT_PATH "/System/Library/Frameworks/IOKit.framework/Versions/A/IOKit"
#define HUSH_MKB_PATH "/System/Library/PrivateFrameworks/MobileKeyBag.framework/MobileKeyBag"

// IOReturn values (IOKit/IOReturn.h is not in the SDK's public headers).
#define HUSH_kIOReturnSuccess 0
#define HUSH_kIOReturnError ((int)0xe00002bc)

typedef int (*hush_syswake_fn)(CFDictionaryRef description);
typedef int (*hush_mkb_unlocked_fn)(void);

static hush_syswake_fn orig_IOPMRequestSysWake;
static hush_mkb_unlocked_fn hush_MKBDeviceUnlockedSinceBoot;
static int hush_loaded_token = NOTIFY_TOKEN_INVALID;
static int hush_suppressed_token = NOTIFY_TOKEN_INVALID;
static _Atomic uint64_t hush_suppressed_count;

// True only for a CFDictionary whose "scheduledby" is a CFString containing
// both "com.apple.calaccessd." and "user-invisible". Pure CF reads on a
// dictionary the caller owns; nothing is retained or created.
static bool hush_is_calaccessd_invisible_wake(CFDictionaryRef description) {
    if (description == NULL || CFGetTypeID(description) != CFDictionaryGetTypeID()) {
        return false;
    }
    CFTypeRef by = CFDictionaryGetValue(description, CFSTR("scheduledby"));
    if (by == NULL || CFGetTypeID(by) != CFStringGetTypeID()) {
        return false;
    }
    CFStringRef requestor = (CFStringRef)by;
    CFRange all = CFRangeMake(0, CFStringGetLength(requestor));
    return CFStringFindWithOptions(requestor, CFSTR("com.apple.calaccessd."), all, 0, NULL) &&
           CFStringFindWithOptions(requestor, CFSTR("user-invisible"), all, 0, NULL);
}

// True only when MobileKeyBag positively reports "not unlocked since boot".
// Missing symbol, an error (negative), or 1 all mean "unlocked": never suppress.
// Not cached here on purpose; it is checked on every matching call.
static bool hush_device_is_bfu(void) {
    hush_mkb_unlocked_fn unlocked_since_boot = hush_MKBDeviceUnlockedSinceBoot;
    if (unlocked_since_boot == NULL) {
        return false;
    }
    return unlocked_since_boot() == 0;
}

static int hush_IOPMRequestSysWake(CFDictionaryRef description) {
    // Requestor check first: it is pure CF. The keybag query only runs for
    // the calaccessd alarm's own requests.
    if (hush_is_calaccessd_invisible_wake(description) && hush_device_is_bfu()) {
        uint64_t total = atomic_fetch_add_explicit(&hush_suppressed_count, 1, memory_order_relaxed) + 1;
        hush_publish(hush_suppressed_token, HUSH_BFU_SUPPRESSED, total);
        return HUSH_kIOReturnSuccess;
    }

    hush_syswake_fn orig = orig_IOPMRequestSysWake;
    if (orig == NULL) {
        // Only reachable in the instant between the patch going live and the
        // trampoline pointer being stored (the ctor runs before main, so no
        // caller should exist yet). Report failure rather than jump to NULL.
        return HUSH_kIOReturnError;
    }
    return orig(description);
}

__attribute__((constructor)) static void hush_bfuwake_init(void) {
    if (!hush_module_enabled(CFSTR("BFUWake"))) {
        return;
    }

    void *target = dlsym(RTLD_DEFAULT, "IOPMRequestSysWake");
    if (target == NULL) {
        void *iokit = dlopen(HUSH_IOKIT_PATH, RTLD_LAZY);
        if (iokit != NULL) {
            target = dlsym(iokit, "IOPMRequestSysWake");
        }
    }
    if (target == NULL) {
        os_log(OS_LOG_DEFAULT, "Hush: BFUWake not installed, IOPMRequestSysWake not found");
        return;
    }

    void *mkb = dlopen(HUSH_MKB_PATH, RTLD_LAZY);
    if (mkb != NULL) {
        hush_MKBDeviceUnlockedSinceBoot = (hush_mkb_unlocked_fn)dlsym(mkb, "MKBDeviceUnlockedSinceBoot");
    }

    hush_suppressed_token = hush_notify_token(HUSH_BFU_SUPPRESSED);

    MSHookFunction(target, (void *)hush_IOPMRequestSysWake, (void **)&orig_IOPMRequestSysWake);
    if (orig_IOPMRequestSysWake == NULL) {
        os_log(OS_LOG_DEFAULT, "Hush: BFUWake MSHookFunction(IOPMRequestSysWake) failed");
        return;
    }

    hush_loaded_token = hush_notify_token(HUSH_BFU_LOADED);
    hush_publish(hush_loaded_token, HUSH_BFU_LOADED, 1);
    os_log(OS_LOG_DEFAULT, "Hush: BFUWake hooked IOPMRequestSysWake (MKBDeviceUnlockedSinceBoot %{public}s)",
           hush_MKBDeviceUnlockedSinceBoot != NULL ? "resolved" : "MISSING, will never suppress");
}

// HushWiFiScan: injected into wifid.
//
// Bug (iOS 17, see tweaks/_research/wifid-scancache.md): while Settings > Wi-Fi
// is open, configd keeps pulling wifid's whole scan cache, which wifid serves
// by concatenating every retained scan with no BSSID de-dupe (7,383 records
// for ~250 unique BSSIDs measured). Every one of those records is fed through
// -[WiFiScanObserver ingestScanResults:ofType:clientName:directed:], whose
// consumers then spend seconds of CPU per cycle re-ingesting networks they
// already saw.
//
// Fix: in that method, collapse large result arrays to one record per BSSID
// (the record with the smallest AGE) before calling the original. Normal-sized
// scans, and anything that does not look exactly as expected, pass through
// untouched.
//
// Static evidence (wifid, 17.6.1 iPad7,12):
// - -[WiFiScanObserver ingestScanResults:ofType:clientName:directed:] @0x10001c6ec
//   wraps each element with -[WiFiScanObserverNetwork initWithWiFiNetworkRef:
//   (struct __WiFiNetwork *)] and adds it to an NSMutableSet. That class does
//   not override -isEqual:/-hash, so the set de-dupes nothing.
// - The elements are wifid's own private CF type, registered by
//   _CFRuntimeRegisterClass(&data_1002148f8) @0x1000bb9cc with className
//   "WiFiNetwork". wifid does not link MobileWiFi.
// - WiFiNetworkCreate (@0x10002ac4c) calls _CFRuntimeCreateInstance with 0x10
//   extra bytes and stores the record CFMutableDictionary at +0x10.
//   WiFiNetworkGetProperty (sub_10002b648) is CFDictionaryGetValue(*(ref+0x10), key);
//   the BSSID getter (sub_10001ea90) and AGE getter (sub_1000174d4) both go
//   through it.
//
// Reading +0x10 is a private-layout dependency. Layout verified on 17.6.1
// only, so the read is enabled on iOS 17.x only. Every element must pass all
// of these guards or the whole call goes to %orig unchanged: the CF type is
// named "WiFiNetwork"; the +0x10 field is non-NULL, 8-byte aligned, and owned
// by a malloc zone; that field is a CFDictionary; its BSSID is a CFString.

#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#include <malloc/malloc.h>
#include <os/log.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <sys/sysctl.h>

#include "HushShared.h"

#define HUSH_WIFI_LOADED "com.max.hush.wifiscan.loaded"
#define HUSH_WIFI_DROPPED "com.max.hush.wifiscan.dropped"

// Arrays smaller than this go straight to %orig. Keeps normal scans on the
// untouched path; only the bloated cache pulls are de-duped.
#define HUSH_DEDUPE_MIN_COUNT 64

// Offset of the record CFDictionary inside wifid's private __WiFiNetwork
// object (16-byte CFRuntimeBase, then the record pointer).
// Layout verified on 17.6.1 only.
#define HUSH_WIFINETWORK_RECORD_OFFSET 0x10

@interface WiFiScanObserver : NSObject
- (void)ingestScanResults:(id)results ofType:(unsigned long long)type clientName:(id)name directed:(BOOL)directed;
@end

// Set once in the ctor, before the hook goes live. False on any iOS major
// other than 17: the hook stays installed but always passes through.
static bool hush_layout_enabled;

// wifid's WiFiNetwork CFTypeID, learned by name from the first element that
// matches. 0 is _kCFRuntimeNotATypeID, so it doubles as "not learned yet".
static _Atomic CFTypeID hush_wifinetwork_type;

static int hush_loaded_token = NOTIFY_TOKEN_INVALID;
static int hush_dropped_token = NOTIFY_TOKEN_INVALID;
static _Atomic uint64_t hush_dropped_count;

// Per unique BSSID: which input index we keep, and that record's AGE.
typedef struct {
    NSUInteger index;
    double age;
    bool has_age;
} hush_slot;

static int hush_os_major(void) {
    char version[32] = {0};
    size_t len = sizeof(version) - 1;
    if (sysctlbyname("kern.osproductversion", version, &len, NULL, 0) != 0) {
        return 0;
    }
    return atoi(version);
}

static bool hush_is_wifinetwork(CFTypeRef element) {
    CFTypeID type = CFGetTypeID(element);
    CFTypeID known = atomic_load_explicit(&hush_wifinetwork_type, memory_order_relaxed);
    if (known != 0) {
        return type == known;
    }
    CFStringRef name = CFCopyTypeIDDescription(type);
    if (name == NULL) {
        return false;
    }
    bool match = CFStringCompare(name, CFSTR("WiFiNetwork"), 0) == kCFCompareEqualTo;
    CFRelease(name);
    if (match) {
        atomic_store_explicit(&hush_wifinetwork_type, type, memory_order_relaxed);
    }
    return match;
}

// Returns the record dictionary of a WiFiNetwork element (borrowed, not
// retained), or NULL if the field fails any sanity check. The caller has
// already confirmed the element's CF type.
static CFDictionaryRef hush_record_of(CFTypeRef network) {
    const void *field = *(const void *const *)((const char *)network + HUSH_WIFINETWORK_RECORD_OFFSET);
    if (field == NULL || ((uintptr_t)field & 7) != 0) {
        return NULL;
    }
    if (malloc_zone_from_ptr(field) == NULL) {
        return NULL;
    }
    if (CFGetTypeID((CFTypeRef)field) != CFDictionaryGetTypeID()) {
        return NULL;
    }
    return (CFDictionaryRef)field;
}

// Returns a de-duplicated copy of `results` (one entry per BSSID, the one with
// the smallest AGE; a missing AGE or a tie keeps the later occurrence; BSSIDs
// stay in first-seen order), or nil to mean "call the original unchanged".
// The returned array holds the same element objects (retained by the array),
// never copies. Returned +1 so nothing lands in wifid's autorelease pools.
static NSArray *hush_dedupe(id results, NSUInteger *dropped_out) __attribute__((ns_returns_retained));
static NSArray *hush_dedupe(id results, NSUInteger *dropped_out) {
    if (!hush_layout_enabled) {
        return nil;
    }
    if (![results isKindOfClass:[NSArray class]]) {
        return nil;
    }
    NSArray *input = (NSArray *)results;
    NSUInteger count = input.count;
    if (count < HUSH_DEDUPE_MIN_COUNT) {
        return nil;
    }

    hush_slot *slots = calloc(count, sizeof(*slots));
    // BSSID -> slot number. Keys are retained by the dictionary; values are
    // plain integers (NULL value callbacks), so slot 0 is stored as NULL and
    // presence is tested with GetValueIfPresent.
    CFMutableDictionaryRef slot_for_bssid =
        CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, NULL);
    NSUInteger unique = 0;
    bool ok = (slots != NULL && slot_for_bssid != NULL);

    for (NSUInteger i = 0; ok && i < count; i++) {
        CFTypeRef element = (__bridge CFTypeRef)[input objectAtIndex:i];
        if (!hush_is_wifinetwork(element)) {
            ok = false;
            break;
        }
        CFDictionaryRef record = hush_record_of(element);
        if (record == NULL) {
            ok = false;
            break;
        }
        CFTypeRef bssid = CFDictionaryGetValue(record, CFSTR("BSSID"));
        if (bssid == NULL || CFGetTypeID(bssid) != CFStringGetTypeID()) {
            ok = false;
            break;
        }

        double age = 0;
        bool has_age = false;
        CFTypeRef age_value = CFDictionaryGetValue(record, CFSTR("AGE"));
        if (age_value != NULL && CFGetTypeID(age_value) == CFNumberGetTypeID()) {
            has_age = CFNumberGetValue((CFNumberRef)age_value, kCFNumberDoubleType, &age);
        }

        const void *existing = NULL;
        if (CFDictionaryGetValueIfPresent(slot_for_bssid, bssid, &existing)) {
            hush_slot *slot = &slots[(NSUInteger)(uintptr_t)existing];
            // Smallest AGE wins. If either AGE is missing, or they tie, the
            // later occurrence wins.
            if (!(has_age && slot->has_age) || age <= slot->age) {
                slot->index = i;
                slot->age = age;
                slot->has_age = has_age;
            }
        } else {
            CFDictionarySetValue(slot_for_bssid, bssid, (const void *)(uintptr_t)unique);
            slots[unique].index = i;
            slots[unique].age = age;
            slots[unique].has_age = has_age;
            unique++;
        }
    }

    NSArray *deduped = nil;
    if (ok && unique < count) {
        NSMutableArray *out = [[NSMutableArray alloc] initWithCapacity:unique];
        for (NSUInteger s = 0; s < unique; s++) {
            [out addObject:[input objectAtIndex:slots[s].index]];
        }
        deduped = out;
        *dropped_out = count - unique;
    }

    if (slot_for_bssid != NULL) {
        CFRelease(slot_for_bssid);
    }
    free(slots);
    return deduped;
}

%hook WiFiScanObserver

- (void)ingestScanResults:(id)results ofType:(unsigned long long)type clientName:(id)name directed:(BOOL)directed {
    NSUInteger dropped = 0;
    NSArray *deduped = hush_dedupe(results, &dropped);
    if (deduped == nil) {
        %orig;
        return;
    }

    %orig(deduped, type, name, directed);

    uint64_t total = atomic_fetch_add_explicit(&hush_dropped_count, (uint64_t)dropped, memory_order_relaxed) + dropped;
    hush_publish(hush_dropped_token, HUSH_WIFI_DROPPED, total);
}

%end

%ctor {
    if (!hush_module_enabled(CFSTR("WiFiScan"))) {
        return;
    }
    Class observer = objc_getClass("WiFiScanObserver");
    if (observer == Nil) {
        return;
    }
    if (class_getInstanceMethod(observer, @selector(ingestScanResults:ofType:clientName:directed:)) == NULL) {
        os_log(OS_LOG_DEFAULT, "Hush: WiFiScan not installed, ingestScanResults:ofType:clientName:directed: missing");
        return;
    }

    hush_layout_enabled = (hush_os_major() == 17);
    hush_dropped_token = hush_notify_token(HUSH_WIFI_DROPPED);

    %init;

    hush_loaded_token = hush_notify_token(HUSH_WIFI_LOADED);
    hush_publish(hush_loaded_token, HUSH_WIFI_LOADED, 1);
    os_log(OS_LOG_DEFAULT, "Hush: WiFiScan hooked -[WiFiScanObserver ingestScanResults:...] (de-dupe %{public}s)",
           hush_layout_enabled ? "on" : "off, not iOS 17");
}

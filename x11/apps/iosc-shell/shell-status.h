/*
 * shell-status.h — device status for the iosc shell clients (battery, device
 * name, clock/date strings). Header-only, `static`, no Wayland, no cairo.
 *
 * All the iOS-private bits go through dlopen so we need no private headers and
 * every probe degrades cleanly (battery hides, device name falls back):
 *   - battery:     IOKit IOPSCopyPowerSourcesInfo / ...List / ...Description
 *   - network:     SystemConfiguration SCNetworkReachability. Wi-Fi renders
 *                  arcs; cellular renders signal bars; no route hides it.
 *   - device name: libMobileGestalt MGCopyAnswer("UserAssignedDeviceName")
 *                  (same pattern as wayland/xios-session-identity.c)
 *
 * The layout headers never call these — they take a filled model — so the
 * off-device preview never needs this file.
 */
#ifndef SHELL_STATUS_H
#define SHELL_STATUS_H

#include <stdio.h>
#include <string.h>
#include <time.h>

enum st_network_kind {
    ST_NET_NONE = 0,
    ST_NET_WIFI = 1,
    ST_NET_CELLULAR = 2,
};

#ifdef __APPLE__
#include <dlfcn.h>
#include <netinet/in.h>
#include <CoreFoundation/CoreFoundation.h>

/* ------------------------------------------------------------- battery ---- */
/* Fills *pct (0..100) and *charging; returns 1 on success, 0 if power-source
 * info is unavailable (caller hides the indicator). */
static int st_battery(int *pct, int *charging)
{
    typedef CFTypeRef  (*ps_info_fn)(void);
    typedef CFArrayRef (*ps_list_fn)(CFTypeRef);
    typedef CFDictionaryRef (*ps_desc_fn)(CFTypeRef, CFTypeRef);
    static void *iokit;
    static ps_info_fn ps_info; static ps_list_fn ps_list; static ps_desc_fn ps_desc;

    if (!iokit) {
        iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit",
                       RTLD_LAZY | RTLD_GLOBAL);
        if (!iokit) return 0;
        ps_info = (ps_info_fn)dlsym(iokit, "IOPSCopyPowerSourcesInfo");
        ps_list = (ps_list_fn)dlsym(iokit, "IOPSCopyPowerSourcesList");
        ps_desc = (ps_desc_fn)dlsym(iokit, "IOPSGetPowerSourceDescription");
    }
    if (!ps_info || !ps_list || !ps_desc) return 0;

    CFTypeRef info = ps_info();
    if (!info) return 0;
    CFArrayRef list = ps_list(info);
    int ok = 0;
    if (list && CFArrayGetCount(list) > 0) {
        CFDictionaryRef d = ps_desc(info, CFArrayGetValueAtIndex(list, 0));
        if (d) {
            int cur = -1, max = 100;
            CFNumberRef n;
            if ((n = CFDictionaryGetValue(d, CFSTR("Current Capacity"))))
                CFNumberGetValue(n, kCFNumberIntType, &cur);
            if ((n = CFDictionaryGetValue(d, CFSTR("Max Capacity"))))
                CFNumberGetValue(n, kCFNumberIntType, &max);
            if (cur >= 0 && max > 0) {
                *pct = cur * 100 / max;
                if (*pct > 100) *pct = 100;
                CFBooleanRef b = CFDictionaryGetValue(d, CFSTR("Is Charging"));
                *charging = (b && CFBooleanGetValue(b)) ? 1 : 0;
                ok = 1;
            }
        }
    }
    if (list) CFRelease(list);
    CFRelease(info);
    return ok;
}

/* --------------------------------------------------------------- Wi-Fi ---- */
/* 1 when the default route is up over a non-cellular interface (Wi-Fi on an
 * iPad); 0 when Wi-Fi is off / airplane mode / no network (caller hides the
 * glyph). SystemConfiguration via dlopen, same degrade-by-hiding pattern as
 * st_battery. */
static enum st_network_kind st_network(void)
{
    typedef CFTypeRef (*reach_create_fn)(CFAllocatorRef, const struct sockaddr *);
    typedef Boolean   (*reach_flags_fn)(CFTypeRef, uint32_t *);
    static void *sc;
    static reach_create_fn reach_create; static reach_flags_fn reach_flags;

    if (!sc) {
        sc = dlopen("/System/Library/Frameworks/SystemConfiguration.framework/"
                    "SystemConfiguration", RTLD_LAZY | RTLD_GLOBAL);
        if (!sc) return ST_NET_NONE;
        reach_create = (reach_create_fn)dlsym(sc, "SCNetworkReachabilityCreateWithAddress");
        reach_flags  = (reach_flags_fn)dlsym(sc, "SCNetworkReachabilityGetFlags");
    }
    if (!reach_create || !reach_flags) return ST_NET_NONE;

    struct sockaddr_in zero;
    memset(&zero, 0, sizeof zero);
    zero.sin_len = sizeof zero;
    zero.sin_family = AF_INET;
    CFTypeRef ref = reach_create(NULL, (const struct sockaddr *)&zero);
    if (!ref) return ST_NET_NONE;
    uint32_t fl = 0;
    Boolean ok = reach_flags(ref, &fl);
    CFRelease(ref);
    if (!ok) return ST_NET_NONE;
    /* kSCNetworkReachabilityFlags: Reachable = 1<<1,
     * ConnectionRequired = 1<<2, IsWWAN = 1<<18 (stable ABI constants). */
    if (!(fl & (1u << 1)) || (fl & (1u << 2))) return ST_NET_NONE;
    return (fl & (1u << 18)) ? ST_NET_CELLULAR : ST_NET_WIFI;
}

/* ---------------------------------------------------------- device name --- */
/* "Max's iPad" via MobileGestalt; falls back to `fallback`. Fills out[]. */
static void st_device_name(char *out, size_t n, const char *fallback)
{
    typedef CFStringRef (*mg_copy_answer_fn)(CFStringRef);
    void *handle = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_LAZY | RTLD_GLOBAL);
    snprintf(out, n, "%s", fallback);
    if (!handle) return;
    mg_copy_answer_fn MGCopyAnswer = (mg_copy_answer_fn)dlsym(handle, "MGCopyAnswer");
    if (!MGCopyAnswer) return;   /* leave handle open: process-lifetime */

    CFStringRef key = CFStringCreateWithCString(NULL, "UserAssignedDeviceName",
                                                kCFStringEncodingUTF8);
    if (!key) return;
    CFStringRef ans = MGCopyAnswer(key);
    if (ans && CFGetTypeID(ans) == CFStringGetTypeID()) {
        char buf[128] = {0};
        if (CFStringGetCString(ans, buf, sizeof buf, kCFStringEncodingUTF8) && buf[0])
            snprintf(out, n, "%s", buf);
    }
    if (ans) CFRelease(ans);
    CFRelease(key);
}

#else  /* !__APPLE__ — host-side compile safety only; clients are iOS-only */
static int st_battery(int *pct, int *charging){ (void)pct;(void)charging; return 0; }
static enum st_network_kind st_network(void){ return ST_NET_NONE; }
static void st_device_name(char *out, size_t n, const char *fallback)
{ snprintf(out, n, "%s", fallback); }
#endif

/* ------------------------------------------------------- clock + dates ---- */

static void st_clock(char *out, size_t n)
{
    time_t t = time(NULL); struct tm tm; localtime_r(&t, &tm);
    snprintf(out, n, "%d:%02d", tm.tm_hour, tm.tm_min);
}

/* "Tue Jul 1" (panel) */
static void st_date_short(char *out, size_t n)
{
    time_t t = time(NULL); struct tm tm; localtime_r(&t, &tm);
    char mon[8], day[8];
    strftime(day, sizeof day, "%a", &tm);
    strftime(mon, sizeof mon, "%b", &tm);
    snprintf(out, n, "%s %s %d", day, mon, tm.tm_mday);
}

/* "Tuesday, July 1" (quick settings) */
static void st_date_long(char *out, size_t n)
{
    time_t t = time(NULL); struct tm tm; localtime_r(&t, &tm);
    char day[16], mon[16];
    strftime(day, sizeof day, "%A", &tm);
    strftime(mon, sizeof mon, "%B", &tm);
    snprintf(out, n, "%s, %s %d", day, mon, tm.tm_mday);
}

#endif /* SHELL_STATUS_H */

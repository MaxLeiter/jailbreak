// Shared helpers for both Hush modules: the per-module kill switch and the
// notify-state counters. Everything here runs inside critical system daemons
// (UserEventAgent, wifid), so every failure path degrades to "do nothing".
#pragma once

#include <CoreFoundation/CoreFoundation.h>
#include <fcntl.h>
#include <notify.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>

#define HUSH_PREFS_PATH "/var/jb/var/mobile/Library/Preferences/com.max.hush.plist"
#define HUSH_PREFS_MAX_BYTES (64 * 1024)

// Returns false only when the prefs file exists, parses as a dictionary, and
// sets `key` to NO (boolean false, or a number equal to 0). A missing,
// unreadable, oversized, or malformed file, or a missing key, means enabled.
// Read once per module, at ctor time. Plain file read, no cfprefsd round trip.
static inline bool hush_module_enabled(CFStringRef key) {
    int fd = open(HUSH_PREFS_PATH, O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        return true;
    }

    bool enabled = true;
    struct stat st;
    if (fstat(fd, &st) == 0 && S_ISREG(st.st_mode) && st.st_size > 0 &&
        st.st_size <= HUSH_PREFS_MAX_BYTES) {
        size_t want = (size_t)st.st_size;
        UInt8 *buf = malloc(want);
        if (buf != NULL) {
            size_t have = 0;
            while (have < want) {
                ssize_t got = read(fd, buf + have, want - have);
                if (got <= 0) {
                    break;
                }
                have += (size_t)got;
            }
            CFDataRef data = (have == want)
                ? CFDataCreateWithBytesNoCopy(kCFAllocatorDefault, buf, (CFIndex)have, kCFAllocatorNull)
                : NULL;
            if (data != NULL) {
                CFPropertyListRef plist = CFPropertyListCreateWithData(
                    kCFAllocatorDefault, data, kCFPropertyListImmutable, NULL, NULL);
                if (plist != NULL) {
                    if (CFGetTypeID(plist) == CFDictionaryGetTypeID()) {
                        CFTypeRef value = CFDictionaryGetValue((CFDictionaryRef)plist, key);
                        if (value != NULL) {
                            if (CFGetTypeID(value) == CFBooleanGetTypeID()) {
                                enabled = CFBooleanGetValue((CFBooleanRef)value);
                            } else if (CFGetTypeID(value) == CFNumberGetTypeID()) {
                                int64_t n = 1;
                                if (CFNumberGetValue((CFNumberRef)value, kCFNumberSInt64Type, &n) && n == 0) {
                                    enabled = false;
                                }
                            }
                        }
                    }
                    CFRelease(plist);
                }
                CFRelease(data);
            }
            free(buf);
        }
    }
    close(fd);
    return enabled;
}

// Registers (and keeps registered for the life of the process) a token for
// `name`. Keeping the registration alive is what keeps the name's state in
// notifyd, so a notify_get_state probe from another process can read it.
static inline int hush_notify_token(const char *name) {
    int token = NOTIFY_TOKEN_INVALID;
    if (notify_register_check(name, &token) != NOTIFY_STATUS_OK) {
        return NOTIFY_TOKEN_INVALID;
    }
    return token;
}

// Sets the 64-bit state on `token` (if it registered) and posts `name`.
// Both are fire-and-forget IPC to notifyd; failures are ignored.
static inline void hush_publish(int token, const char *name, uint64_t value) {
    if (token != NOTIFY_TOKEN_INVALID) {
        notify_set_state(token, value);
    }
    notify_post(name);
}

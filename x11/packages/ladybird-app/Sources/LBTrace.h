// LBTrace.h — dead-simple file-based boot tracer for on-device bring-up debugging.
// FrontBoard-launched apps have no accessible stdout without USB, so we append timestamped
// lines to /var/jb/tmp/ladybird-boot.log.
//
// SHIPPING DEFAULT: silent. Tracing is gated on a sentinel file so a release build writes
// nothing unless a debugger explicitly opts in. To enable on-device:
//     touch /var/jb/tmp/ladybird-trace        # then (re)launch the app
// and to silence again: rm /var/jb/tmp/ladybird-trace. The check is cached on first call
// so it costs one stat() per process, not one per trace line.
#pragma once
#include <stdio.h>
#include <stdarg.h>
#include <time.h>
#include <unistd.h>

#define LB_TRACE_SENTINEL "/var/jb/tmp/ladybird-trace"

static inline int lb_trace_enabled(void)
{
    static int cached = -1;
    if (cached < 0)
        cached = (access(LB_TRACE_SENTINEL, F_OK) == 0) ? 1 : 0;
    return cached;
}

static inline void lb_trace(char const* fmt, ...)
{
    if (!lb_trace_enabled())
        return;
    FILE* f = fopen("/var/jb/tmp/ladybird-boot.log", "a");
    if (!f)
        return;
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    fprintf(f, "[%ld.%03ld] ", (long)ts.tv_sec, ts.tv_nsec / 1000000);
    va_list ap;
    va_start(ap, fmt);
    vfprintf(f, fmt, ap);
    va_end(ap);
    fputc('\n', f);
    fclose(f);
}

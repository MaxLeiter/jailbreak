// LBTrace.h — dead-simple file-based boot tracer for on-device bring-up debugging.
// FrontBoard-launched apps have no accessible stdout without USB, so we append timestamped
// lines to /var/jb/tmp/ladybird-boot.log. Remove (or gate) once the app is validated.
#pragma once
#include <stdio.h>
#include <stdarg.h>
#include <time.h>

static inline void lb_trace(char const* fmt, ...)
{
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

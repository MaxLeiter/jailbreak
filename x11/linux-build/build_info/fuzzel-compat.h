/* fuzzel-compat.h — Darwin/iOS portability shim, force-included (-include) into every fuzzel TU.
 * fuzzel targets Linux/FreeBSD; the iOS 16 libc/SDK is missing a handful of glibc/Linux
 * extensions it uses. Everything here is either a trivial wrapper over the flagless POSIX
 * variant, or a type/decl the SDK simply doesn't provide at -miphoneos-version-min=16.0.
 * (threads.h + uchar.h shims are staged separately into build_base by build-wayland-apps.sh;
 * <linux/input-event-codes.h> likewise. shm.c already self-guards MAP_UNINITIALIZED/MFD_*.) */
#pragma once

#include <time.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdlib.h>
#include <errno.h>

/* reallocarray: absent from the iOS 16 SDK libSystem headers; provide the implementation
 * (realloc with the standard multiplication-overflow guard). static inline => no external
 * symbol. Used by xmalloc.c's xreallocarray(). */
static inline void *reallocarray(void *ptr, size_t nmemb, size_t size) {
    if (size != 0 && nmemb > (size_t)-1 / size) { errno = ENOMEM; return NULL; }
    return realloc(ptr, nmemb * size);
}

/* iOS has no POSIX interval timers, so <time.h> lacks struct itimerspec; epoll-shim's
 * <sys/timerfd.h> only uses it through pointers, but fuzzel (clipboard.c/wayland.c/match.c)
 * builds itimerspec values by hand, so provide the type. */
#ifndef __itimerspec_defined
#define __itimerspec_defined 1
struct itimerspec { struct timespec it_interval; struct timespec it_value; };
#endif

/* pipe2: glibc atomic-flag variant. Emulate with pipe() + fcntl (fuzzel only ever passes
 * O_CLOEXEC / O_CLOEXEC|O_NONBLOCK). */
static inline int _fuzzel_pipe2(int fds[2], int flags) {
    if (pipe(fds) != 0) return -1;
    if (flags & O_CLOEXEC)  { fcntl(fds[0], F_SETFD, FD_CLOEXEC); fcntl(fds[1], F_SETFD, FD_CLOEXEC); }
    if (flags & O_NONBLOCK) { fcntl(fds[0], F_SETFL, fcntl(fds[0], F_GETFL, 0) | O_NONBLOCK);
                              fcntl(fds[1], F_SETFL, fcntl(fds[1], F_GETFL, 0) | O_NONBLOCK); }
    return 0;
}
#define pipe2(fds, flags) _fuzzel_pipe2((fds), (flags))

/* mkostemp: glibc extension used by shm.c's non-memfd fallback (the Darwin path). Wrap
 * mkstemp + O_CLOEXEC. */
static inline int _fuzzel_mkostemp(char *tmpl, int flags) {
    int fd = mkstemp(tmpl);
    if (fd < 0) return -1;
    if (flags & O_CLOEXEC) fcntl(fd, F_SETFD, FD_CLOEXEC);
    return fd;
}
#define mkostemp(tmpl, flags) _fuzzel_mkostemp((tmpl), (flags))

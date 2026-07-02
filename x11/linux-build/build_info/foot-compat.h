/* foot-compat.h — Darwin/iOS portability shim, force-included (-include) into every foot TU.
 * foot targets Linux/FreeBSD; iOS libc is missing a handful of glibc/Linux extensions it uses.
 * Everything here is either a real libSystem symbol that the SDK simply doesn't prototype at
 * -miphoneos-version-min=16.0, or a trivial wrapper over the flagless POSIX variant. */
#pragma once

#include <time.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdlib.h>
#include <signal.h>
#include <errno.h>

/* Darwin has no POSIX real-time signals. foot only uses SIGRTMAX as an upper bound to size its
 * per-signal handler arrays (it registers handlers for standard signals only), so NSIG (32) is
 * a safe, sufficient value. */
#ifndef SIGRTMAX
#define SIGRTMAX NSIG
#endif
/* Note: deliberately NOT including <sys/socket.h> — doing so globally pulls libc send(), which
 * collides with foot's static send() Wayland callback in selection.c. accept4's socket types
 * are forward-declared below; TUs that actually do sockets (server.c) include socket.h themselves. */

/* reallocarray: absent from the iOS 16.5 SDK libSystem, so provide the implementation (realloc
 * with the standard multiplication-overflow guard). static inline => no external symbol needed. */
static inline void *reallocarray(void *ptr, size_t nmemb, size_t size) {
    if (size != 0 && nmemb > (size_t)-1 / size) { errno = ENOMEM; return NULL; }
    return realloc(ptr, nmemb * size);
}

/* iOS has no POSIX interval timers, so <time.h> lacks struct itimerspec; epoll-shim's
 * <sys/timerfd.h> only uses it through pointers, so foot's by-value uses are what break. */
#ifndef __itimerspec_defined
#define __itimerspec_defined 1
struct itimerspec { struct timespec it_interval; struct timespec it_value; };
#endif

/* Linux socket-creation flags (absent on Darwin); values only need to be distinct high bits. */
#ifndef SOCK_CLOEXEC
#define SOCK_CLOEXEC  0x10000000
#endif
#ifndef SOCK_NONBLOCK
#define SOCK_NONBLOCK 0x20000000
#endif

/* SO_DOMAIN (query a socket's address family) is Linux-only. foot references it solely to
 * validate a *passed-in* socket FD (systemd-style socket activation) — never on the normal
 * launch path where foot creates its own socket. Define it so the file compiles; if that rarely
 * used path ever runs, getsockopt() simply reports the option unsupported. */
#ifndef SO_DOMAIN
#define SO_DOMAIN 0x1029
#endif

/* pipe2/accept4/mkostemp: glibc atomic-flag variants. Emulate with the flagless call + fcntl
 * (close enough — foot only ever passes O_CLOEXEC/O_NONBLOCK / SOCK_CLOEXEC|SOCK_NONBLOCK). */
static inline int _foot_pipe2(int fds[2], int flags) {
    if (pipe(fds) != 0) return -1;
    if (flags & O_CLOEXEC)  { fcntl(fds[0], F_SETFD, FD_CLOEXEC); fcntl(fds[1], F_SETFD, FD_CLOEXEC); }
    if (flags & O_NONBLOCK) { fcntl(fds[0], F_SETFL, fcntl(fds[0], F_GETFL, 0) | O_NONBLOCK);
                              fcntl(fds[1], F_SETFL, fcntl(fds[1], F_GETFL, 0) | O_NONBLOCK); }
    return 0;
}
#define pipe2(fds, flags) _foot_pipe2((fds), (flags))

/* accept4: expressed as a statement-expression macro so `accept` resolves at the call site,
 * where the using TU (server.c) has included the real <sys/socket.h> (with its asm label). We
 * must not forward-declare accept ourselves — that triggers "asm label after first use". */
#define accept4(s, addr, len, flags) __extension__ ({                       \
    int _fd = accept((s), (addr), (len));                                   \
    if (_fd >= 0) {                                                         \
        if ((flags) & SOCK_CLOEXEC)  fcntl(_fd, F_SETFD, FD_CLOEXEC);       \
        if ((flags) & SOCK_NONBLOCK) fcntl(_fd, F_SETFL, fcntl(_fd, F_GETFL, 0) | O_NONBLOCK); \
    }                                                                       \
    _fd;                                                                    \
})

static inline int _foot_mkostemp(char *tmpl, int flags) {
    int fd = mkstemp(tmpl);
    if (fd < 0) return -1;
    if (flags & O_CLOEXEC) fcntl(fd, F_SETFD, FD_CLOEXEC);
    return fd;
}
#define mkostemp(tmpl, flags) _foot_mkostemp((tmpl), (flags))

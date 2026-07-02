/* mpv-compat.h — Darwin/iOS portability shim, force-included (-include) into every mpv C TU.
 * mpv targets Linux/macOS; the one glibc/Linux extension it uses unconditionally that the iOS
 * SDK's libSystem doesn't prototype is pipe2() (video/out/wayland_common.c, for the Wayland
 * display read pipe). memfd_create is already behind mpv's HAVE_MEMFD_CREATE meson gate (absent
 * on iOS -> mpv's shm_open fallback), and the mkostemp references resolve to mpv's own
 * osdep/io.c mp_mkostemps(), so pipe2 is the only shim needed. */
#pragma once

#include <fcntl.h>
#include <unistd.h>

/* pipe2: glibc atomic-flag variant. Emulate with pipe() + fcntl (mpv only ever passes
 * O_CLOEXEC / O_NONBLOCK). static inline => no external symbol, no clash (iOS declares no pipe2). */
static inline int _mpv_pipe2(int fds[2], int flags) {
    if (pipe(fds) != 0) return -1;
    if (flags & O_CLOEXEC)  { fcntl(fds[0], F_SETFD, FD_CLOEXEC); fcntl(fds[1], F_SETFD, FD_CLOEXEC); }
    if (flags & O_NONBLOCK) { fcntl(fds[0], F_SETFL, fcntl(fds[0], F_GETFL, 0) | O_NONBLOCK);
                              fcntl(fds[1], F_SETFL, fcntl(fds[1], F_GETFL, 0) | O_NONBLOCK); }
    return 0;
}
#define pipe2(fds, flags) _mpv_pipe2((fds), (flags))

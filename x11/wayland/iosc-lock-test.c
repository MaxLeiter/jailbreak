/*
 * iosc-lock-test.c — validates ext-session-lock-v1 against iosc.
 *
 * Locks the session, maps a dark-red fullscreen lock surface (white border),
 * reports every keyboard/lock event, then unlocks after 10 seconds and exits.
 * While locked every other window must vanish and all input must land here;
 * on unlock the desktop must come back exactly as it was.
 *
 * Expected: "LOCKED" -> "configure WxH" -> red screen -> (10s) -> "unlocking"
 * -> desktop restored -> exit 0. A second concurrent instance prints
 * "FINISHED (lock denied)" and exits 1.
 *
 * MIT. Standard libwayland-client boilerplate.
 */
#include <wayland-client.h>
#include "ext-session-lock-v1-client-protocol.h"

#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/mman.h>

#define LOCKED_SECONDS 10

static struct wl_compositor *compositor;
static struct wl_shm        *shm;
static struct wl_seat       *seat;
static struct wl_output     *output;
static struct ext_session_lock_manager_v1 *lock_mgr;

static struct ext_session_lock_v1 *lock;
static struct ext_session_lock_surface_v1 *lock_surface;
static struct wl_surface *surface;

static int locked = 0, denied = 0, painted = 0;

static int create_shm_file(size_t size)
{
    const char *dir = getenv("XDG_RUNTIME_DIR");
    if (!dir) dir = "/var/jb/tmp";
    char tmpl[256];
    snprintf(tmpl, sizeof(tmpl), "%s/iosc-shm-XXXXXX", dir);
    int fd = mkstemp(tmpl);
    if (fd < 0) { perror("mkstemp"); return -1; }
    unlink(tmpl);
    if (ftruncate(fd, (off_t)size) < 0) { perror("ftruncate"); close(fd); return -1; }
    return fd;
}

static struct wl_buffer *make_lock_frame(int w, int h)
{
    int stride = w * 4;
    size_t size = (size_t)stride * h;
    int fd = create_shm_file(size);
    if (fd < 0) return NULL;
    uint32_t *px = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (px == MAP_FAILED) { perror("mmap"); close(fd); return NULL; }
    for (int y = 0; y < h; y++)
        for (int x = 0; x < w; x++)
            px[y * w + x] = (x < 12 || y < 12 || x >= w - 12 || y >= h - 12)
                          ? 0x00ffffffu    /* white border */
                          : 0x00801020u;   /* dark red lock screen */
    struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, (int32_t)size);
    struct wl_buffer *buf = wl_shm_pool_create_buffer(pool, 0, w, h, stride,
                                                      WL_SHM_FORMAT_XRGB8888);
    wl_shm_pool_destroy(pool);
    munmap(px, size);
    close(fd);
    return buf;
}

/* ---- keyboard (proves input confinement) ---------------------------------- */

static void kbd_keymap(void *d, struct wl_keyboard *k, uint32_t fmt, int fd, uint32_t sz)
{ (void)d; (void)k; (void)fmt; (void)sz; close(fd); }
static void kbd_enter(void *d, struct wl_keyboard *k, uint32_t serial,
                      struct wl_surface *s, struct wl_array *keys)
{ (void)d; (void)k; (void)serial; (void)keys;
    fprintf(stderr, "lock-test: keyboard ENTER (%s)\n",
            s == surface ? "the lock surface, correct" : "UNEXPECTED surface"); }
static void kbd_leave(void *d, struct wl_keyboard *k, uint32_t serial, struct wl_surface *s)
{ (void)d; (void)k; (void)serial; (void)s;
    fprintf(stderr, "lock-test: keyboard LEAVE\n"); }
static void kbd_key(void *d, struct wl_keyboard *k, uint32_t serial, uint32_t t,
                    uint32_t key, uint32_t state)
{ (void)d; (void)k; (void)serial; (void)t;
    fprintf(stderr, "lock-test: key %u %s (typed at the lock screen)\n",
            key, state ? "down" : "up"); }
static void kbd_modifiers(void *d, struct wl_keyboard *k, uint32_t serial,
                          uint32_t dep, uint32_t lat, uint32_t lock_, uint32_t grp)
{ (void)d; (void)k; (void)serial; (void)dep; (void)lat; (void)lock_; (void)grp; }
static void kbd_repeat_info(void *d, struct wl_keyboard *k, int32_t rate, int32_t delay)
{ (void)d; (void)k; (void)rate; (void)delay; }
static const struct wl_keyboard_listener kbd_listener = {
    .keymap = kbd_keymap, .enter = kbd_enter, .leave = kbd_leave,
    .key = kbd_key, .modifiers = kbd_modifiers, .repeat_info = kbd_repeat_info,
};

/* ---- lock surface --------------------------------------------------------- */

static void lsurf_configure(void *d, struct ext_session_lock_surface_v1 *ls,
                            uint32_t serial, uint32_t w, uint32_t h)
{ (void)d;
    fprintf(stderr, "lock-test: configure %ux%u\n", w, h);
    ext_session_lock_surface_v1_ack_configure(ls, serial);
    struct wl_buffer *buf = make_lock_frame((int)w, (int)h);
    if (!buf) return;
    wl_surface_attach(surface, buf, 0, 0);
    wl_surface_damage(surface, 0, 0, (int)w, (int)h);
    wl_surface_commit(surface);
    painted = 1;
    fprintf(stderr, "lock-test: lock surface committed (screen should be red now)\n");
}
static const struct ext_session_lock_surface_v1_listener lsurf_listener = {
    .configure = lsurf_configure,
};

/* ---- lock object ---------------------------------------------------------- */

static void lock_locked(void *d, struct ext_session_lock_v1 *lk)
{ (void)d; (void)lk;
    locked = 1;
    fprintf(stderr, "lock-test: LOCKED\n");
    surface = wl_compositor_create_surface(compositor);
    lock_surface = ext_session_lock_v1_get_lock_surface(lock, surface, output);
    ext_session_lock_surface_v1_add_listener(lock_surface, &lsurf_listener, NULL);
    wl_surface_commit(surface);
}
static void lock_finished(void *d, struct ext_session_lock_v1 *lk)
{ (void)d;
    denied = 1;
    fprintf(stderr, "lock-test: FINISHED (lock denied or revoked)\n");
    ext_session_lock_v1_destroy(lk);
    lock = NULL;
}
static const struct ext_session_lock_v1_listener lock_listener = {
    .locked = lock_locked, .finished = lock_finished,
};

/* ---- registry ------------------------------------------------------------- */

static void reg_global(void *data, struct wl_registry *reg, uint32_t name,
                       const char *iface, uint32_t version)
{
    (void)data; (void)version;
    if (!strcmp(iface, "wl_compositor"))
        compositor = wl_registry_bind(reg, name, &wl_compositor_interface, 4);
    else if (!strcmp(iface, "wl_shm"))
        shm = wl_registry_bind(reg, name, &wl_shm_interface, 1);
    else if (!strcmp(iface, "wl_seat"))
        seat = wl_registry_bind(reg, name, &wl_seat_interface, 5);
    else if (!strcmp(iface, "wl_output") && !output)
        output = wl_registry_bind(reg, name, &wl_output_interface, 2);
    else if (!strcmp(iface, "ext_session_lock_manager_v1"))
        lock_mgr = wl_registry_bind(reg, name, &ext_session_lock_manager_v1_interface, 1);
}
static void reg_global_remove(void *d, struct wl_registry *r, uint32_t n)
{ (void)d; (void)r; (void)n; }
static const struct wl_registry_listener registry_listener = {
    .global = reg_global, .global_remove = reg_global_remove,
};

int main(void)
{
    struct wl_display *dpy = wl_display_connect(NULL);
    if (!dpy) { fprintf(stderr, "lock-test: wl_display_connect failed "
                                "(WAYLAND_DISPLAY + XDG_RUNTIME_DIR?)\n"); return 1; }
    struct wl_registry *reg = wl_display_get_registry(dpy);
    wl_registry_add_listener(reg, &registry_listener, NULL);
    wl_display_roundtrip(dpy);

    if (!compositor || !shm || !output || !lock_mgr) {
        fprintf(stderr, "lock-test: missing globals (compositor=%p shm=%p output=%p "
                        "lock_mgr=%p)\n", (void *)compositor, (void *)shm,
                (void *)output, (void *)lock_mgr);
        return 1;
    }
    if (seat) {
        struct wl_keyboard *kbd = wl_seat_get_keyboard(seat);
        wl_keyboard_add_listener(kbd, &kbd_listener, NULL);
    }

    lock = ext_session_lock_manager_v1_lock(lock_mgr);
    ext_session_lock_v1_add_listener(lock, &lock_listener, NULL);
    wl_display_roundtrip(dpy);   /* locked or finished arrives here */
    if (denied) return 1;

    /* Hold the lock for LOCKED_SECONDS while dispatching events, then unlock. */
    time_t until = time(NULL) + LOCKED_SECONDS;
    struct pollfd pfd = { .fd = wl_display_get_fd(dpy), .events = POLLIN };
    while (time(NULL) < until && !denied) {
        wl_display_dispatch_pending(dpy);
        wl_display_flush(dpy);
        if (poll(&pfd, 1, 500) > 0 && wl_display_dispatch(dpy) == -1) break;
    }

    if (lock && locked) {
        fprintf(stderr, "lock-test: unlocking\n");
        ext_session_lock_v1_unlock_and_destroy(lock);
        wl_display_roundtrip(dpy);   /* make sure the unlock lands */
        fprintf(stderr, "lock-test: PASS (unlocked; desktop should be back)\n");
    }
    wl_display_disconnect(dpy);
    return 0;
}

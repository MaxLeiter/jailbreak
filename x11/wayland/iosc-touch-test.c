/*
 * iosc-touch-test.c — validates wl_touch multitouch against iosc.
 *
 * Maps a green xdg_toplevel and prints every wl_touch event with its touch id
 * and surface-local coordinates. Drive it with real fingers (once the Xios app
 * sends IOSC_IN_TOUCH) or with the injector:
 *
 *   iosc-input-test -t 500 400
 *
 * Expected for the injector gesture: DOWN id=0 and DOWN id=1 (120px apart),
 * interleaved MOTION for both ids sliding 80px down, then UP for both —
 * proving the ids are tracked independently (real multitouch, not a tap).
 *
 * MIT. Standard libwayland-client boilerplate.
 */
#include <wayland-client.h>
#include "xdg-shell-client-protocol.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>

static struct wl_compositor *compositor;
static struct wl_shm        *shm;
static struct xdg_wm_base   *wm_base;
static struct wl_seat       *seat;
static struct wl_surface    *surface;

static int want_w = 700, want_h = 500;
static uint32_t seat_caps;

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

static void draw(void)
{
    int w = want_w, h = want_h, stride = w * 4;
    size_t size = (size_t)stride * h;
    int fd = create_shm_file(size);
    if (fd < 0) return;
    uint32_t *px = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (px == MAP_FAILED) { perror("mmap"); close(fd); return; }
    for (int y = 0; y < h; y++)
        for (int x = 0; x < w; x++)
            px[y * w + x] = (x < 10 || y < 10 || x >= w - 10 || y >= h - 10)
                          ? 0x00ffffffu : 0x00107030u;   /* green, white border */
    struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, (int32_t)size);
    struct wl_buffer *buf = wl_shm_pool_create_buffer(pool, 0, w, h, stride,
                                                      WL_SHM_FORMAT_XRGB8888);
    wl_shm_pool_destroy(pool);
    munmap(px, size);
    close(fd);
    wl_surface_attach(surface, buf, 0, 0);
    wl_surface_damage(surface, 0, 0, w, h);
    wl_surface_commit(surface);
}

/* ---- wl_touch -------------------------------------------------------------- */

static void tch_down(void *d, struct wl_touch *t, uint32_t serial, uint32_t time,
                     struct wl_surface *s, int32_t id, wl_fixed_t x, wl_fixed_t y)
{ (void)d; (void)t; (void)serial; (void)time; (void)s;
    fprintf(stderr, "touch-test: DOWN   id=%d at %.0f,%.0f\n",
            id, wl_fixed_to_double(x), wl_fixed_to_double(y)); }
static void tch_up(void *d, struct wl_touch *t, uint32_t serial, uint32_t time, int32_t id)
{ (void)d; (void)t; (void)serial; (void)time;
    fprintf(stderr, "touch-test: UP     id=%d\n", id); }
static void tch_motion(void *d, struct wl_touch *t, uint32_t time, int32_t id,
                       wl_fixed_t x, wl_fixed_t y)
{ (void)d; (void)t; (void)time;
    fprintf(stderr, "touch-test: MOTION id=%d at %.0f,%.0f\n",
            id, wl_fixed_to_double(x), wl_fixed_to_double(y)); }
static void tch_frame(void *d, struct wl_touch *t)
{ (void)d; (void)t; fprintf(stderr, "touch-test: FRAME\n"); }
static void tch_cancel(void *d, struct wl_touch *t)
{ (void)d; (void)t; fprintf(stderr, "touch-test: CANCEL (all ids dropped)\n"); }
static void tch_shape(void *d, struct wl_touch *t, int32_t id, wl_fixed_t maj, wl_fixed_t min)
{ (void)d; (void)t; (void)id; (void)maj; (void)min; }
static void tch_orientation(void *d, struct wl_touch *t, int32_t id, wl_fixed_t o)
{ (void)d; (void)t; (void)id; (void)o; }

static const struct wl_touch_listener touch_listener = {
    .down = tch_down, .up = tch_up, .motion = tch_motion,
    .frame = tch_frame, .cancel = tch_cancel,
    .shape = tch_shape, .orientation = tch_orientation,
};

/* ---- seat / registry / xdg boilerplate ------------------------------------- */

static void seat_capabilities(void *d, struct wl_seat *s, uint32_t caps)
{ (void)d; (void)s;
    seat_caps = caps;
    fprintf(stderr, "touch-test: seat caps: pointer=%d keyboard=%d TOUCH=%d\n",
            !!(caps & WL_SEAT_CAPABILITY_POINTER),
            !!(caps & WL_SEAT_CAPABILITY_KEYBOARD),
            !!(caps & WL_SEAT_CAPABILITY_TOUCH)); }
static void seat_name(void *d, struct wl_seat *s, const char *n)
{ (void)d; (void)s; (void)n; }
static const struct wl_seat_listener seat_listener = {
    .capabilities = seat_capabilities, .name = seat_name };

static void wm_base_ping(void *d, struct xdg_wm_base *b, uint32_t serial)
{ (void)d; xdg_wm_base_pong(b, serial); }
static const struct xdg_wm_base_listener wm_base_listener = { .ping = wm_base_ping };

static void reg_global(void *data, struct wl_registry *reg, uint32_t name,
                       const char *iface, uint32_t version)
{
    (void)data; (void)version;
    if (!strcmp(iface, "wl_compositor"))
        compositor = wl_registry_bind(reg, name, &wl_compositor_interface, 4);
    else if (!strcmp(iface, "wl_shm"))
        shm = wl_registry_bind(reg, name, &wl_shm_interface, 1);
    else if (!strcmp(iface, "wl_seat")) {
        seat = wl_registry_bind(reg, name, &wl_seat_interface, 5);
        wl_seat_add_listener(seat, &seat_listener, NULL);
    } else if (!strcmp(iface, "xdg_wm_base")) {
        wm_base = wl_registry_bind(reg, name, &xdg_wm_base_interface, 1);
        xdg_wm_base_add_listener(wm_base, &wm_base_listener, NULL);
    }
}
static void reg_global_remove(void *d, struct wl_registry *r, uint32_t n)
{ (void)d; (void)r; (void)n; }
static const struct wl_registry_listener registry_listener = {
    .global = reg_global, .global_remove = reg_global_remove,
};

static void xsurf_configure(void *d, struct xdg_surface *xs, uint32_t serial)
{ (void)d; xdg_surface_ack_configure(xs, serial); draw(); }
static const struct xdg_surface_listener xsurf_listener = { .configure = xsurf_configure };

static void top_configure(void *d, struct xdg_toplevel *t, int32_t w, int32_t h,
                          struct wl_array *states)
{ (void)d; (void)t; (void)states;
    if (w > 0 && h > 0) { want_w = w; want_h = h; } }
static void top_close(void *d, struct xdg_toplevel *t){ (void)d; (void)t; exit(0); }
static const struct xdg_toplevel_listener top_listener = {
    .configure = top_configure, .close = top_close,
};

int main(void)
{
    struct wl_display *dpy = wl_display_connect(NULL);
    if (!dpy) { fprintf(stderr, "touch-test: wl_display_connect failed "
                                "(WAYLAND_DISPLAY + XDG_RUNTIME_DIR?)\n"); return 1; }
    struct wl_registry *reg = wl_display_get_registry(dpy);
    wl_registry_add_listener(reg, &registry_listener, NULL);
    wl_display_roundtrip(dpy);
    if (!compositor || !shm || !wm_base || !seat) {
        fprintf(stderr, "touch-test: missing globals\n");
        return 1;
    }
    wl_display_roundtrip(dpy);   /* seat capabilities */
    if (!(seat_caps & WL_SEAT_CAPABILITY_TOUCH))
        fprintf(stderr, "touch-test: WARNING seat does not advertise touch\n");
    struct wl_touch *touch = wl_seat_get_touch(seat);
    wl_touch_add_listener(touch, &touch_listener, NULL);

    surface = wl_compositor_create_surface(compositor);
    struct xdg_surface *xsurface = xdg_wm_base_get_xdg_surface(wm_base, surface);
    xdg_surface_add_listener(xsurface, &xsurf_listener, NULL);
    struct xdg_toplevel *top = xdg_surface_get_toplevel(xsurface);
    xdg_toplevel_add_listener(top, &top_listener, NULL);
    xdg_toplevel_set_title(top, "touch test");
    xdg_toplevel_set_app_id(top, "com.max.iosc.touchtest");
    wl_surface_commit(surface);

    fprintf(stderr, "touch-test: mapped (green window); touch it or run "
                    "iosc-input-test -t <x> <y>\n");
    while (wl_display_dispatch(dpy) != -1) { }
    wl_display_disconnect(dpy);
    return 0;
}

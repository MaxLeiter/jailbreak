/*
 * iosc-client.c — a tiny self-contained Wayland wl_shm + xdg-shell client, to
 * validate the iosc compositor end-to-end on-device without cross-building the
 * Weston demos. It maps one xdg_toplevel and paints a recognizable pattern
 * (blue field, green border, a red diagonal) into a wl_shm XRGB8888 buffer.
 *
 * MIT. Standard libwayland-client boilerplate.
 */
#include <wayland-client.h>
#include "xdg-shell-client-protocol.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <time.h>
#include <sys/mman.h>

static struct wl_compositor *compositor;
static struct wl_shm        *shm;
static struct xdg_wm_base   *wm_base;

static int   want_w = 800, want_h = 600;
static int   configured = 0;
static int   painted = 0;
static int   frames = 0;

/* ---- anonymous shm file (no memfd on iOS) -------------------------------- */

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

/* ---- registry ------------------------------------------------------------ */

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
    else if (!strcmp(iface, "xdg_wm_base")) {
        wm_base = wl_registry_bind(reg, name, &xdg_wm_base_interface, 1);
        xdg_wm_base_add_listener(wm_base, &wm_base_listener, NULL);
    }
    fprintf(stderr, "client: global %s v%u\n", iface, version);
}
static void reg_global_remove(void *d, struct wl_registry *r, uint32_t n)
{ (void)d; (void)r; (void)n; }
static const struct wl_registry_listener registry_listener = {
    .global = reg_global, .global_remove = reg_global_remove,
};

/* ---- paint --------------------------------------------------------------- */

static struct wl_buffer *make_frame(int w, int h)
{
    int stride = w * 4;
    size_t size = (size_t)stride * h;
    int fd = create_shm_file(size);
    if (fd < 0) return NULL;
    uint32_t *px = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (px == MAP_FAILED) { perror("mmap"); close(fd); return NULL; }

    /* XRGB8888 = native-endian 0x00RRGGBB. Blue field, green 8px border, red
     * diagonal — unmistakably a client-drawn frame, not a test pattern. */
    for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
            uint32_t c = 0x00203a8f;                    /* blue */
            if (x < 8 || y < 8 || x >= w - 8 || y >= h - 8)
                c = 0x0030c030;                         /* green border */
            else if (x * h / (w ? w : 1) == y)
                c = 0x00e02020;                         /* red diagonal */
            px[y * w + x] = c;
        }
    }

    struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, (int32_t)size);
    struct wl_buffer *buf = wl_shm_pool_create_buffer(pool, 0, w, h, stride,
                                                      WL_SHM_FORMAT_XRGB8888);
    wl_shm_pool_destroy(pool);
    munmap(px, size);
    close(fd);
    return buf;
}

/* ---- xdg_surface / toplevel --------------------------------------------- */

static struct wl_surface  *surface;
static struct xdg_surface *xsurface;

static void draw(void)
{
    struct wl_buffer *buf = make_frame(want_w, want_h);
    if (!buf) { fprintf(stderr, "client: make_frame failed\n"); return; }
    wl_surface_attach(surface, buf, 0, 0);
    wl_surface_damage(surface, 0, 0, want_w, want_h);
    wl_surface_commit(surface);
    painted = 1;
    frames++;
    fprintf(stderr, "client: committed frame %d (%dx%d)\n", frames, want_w, want_h);
}

static void xsurf_configure(void *d, struct xdg_surface *xs, uint32_t serial)
{
    (void)d;
    xdg_surface_ack_configure(xs, serial);
    configured = 1;
    draw();
}
static const struct xdg_surface_listener xsurf_listener = { .configure = xsurf_configure };

static void top_configure(void *d, struct xdg_toplevel *t, int32_t w, int32_t h,
                          struct wl_array *states)
{
    (void)d; (void)t; (void)states;
    if (w > 0 && h > 0) { want_w = w; want_h = h; }
    fprintf(stderr, "client: toplevel configure %dx%d\n", w, h);
}
static void top_close(void *d, struct xdg_toplevel *t){ (void)d; (void)t; exit(0); }
static const struct xdg_toplevel_listener top_listener = {
    .configure = top_configure, .close = top_close,
};

int main(void)
{
    struct wl_display *dpy = wl_display_connect(NULL);
    if (!dpy) { fprintf(stderr, "client: wl_display_connect failed "
                                "(WAYLAND_DISPLAY + XDG_RUNTIME_DIR?)\n"); return 1; }

    struct wl_registry *reg = wl_display_get_registry(dpy);
    wl_registry_add_listener(reg, &registry_listener, NULL);
    wl_display_roundtrip(dpy);   /* receive globals */

    if (!compositor || !shm || !wm_base) {
        fprintf(stderr, "client: missing globals (compositor=%p shm=%p wm_base=%p)\n",
                (void*)compositor, (void*)shm, (void*)wm_base);
        return 1;
    }

    surface  = wl_compositor_create_surface(compositor);
    xsurface = xdg_wm_base_get_xdg_surface(wm_base, surface);
    xdg_surface_add_listener(xsurface, &xsurf_listener, NULL);
    struct xdg_toplevel *top = xdg_surface_get_toplevel(xsurface);
    xdg_toplevel_add_listener(top, &top_listener, NULL);
    xdg_toplevel_set_title(top, "iosc-client");
    xdg_toplevel_set_app_id(top, "com.max.iosc.client");
    wl_surface_commit(surface);   /* initial commit; compositor replies configure */

    fprintf(stderr, "client: mapped; entering dispatch loop\n");
    /* Keep dispatching: repaint a few frames to exercise frame callbacks/damage,
     * then idle (the buffer stays on the surface so the screen keeps showing it). */
    while (wl_display_dispatch(dpy) != -1) {
        if (configured && painted && frames < 3) {
            struct timespec ts = { 0, 200 * 1000 * 1000 };
            nanosleep(&ts, NULL);
            draw();
        }
    }
    wl_display_disconnect(dpy);
    return 0;
}

/*
 * iosc-layer-test.c — a tiny self-contained zwlr_layer_shell_v1 client, to
 * validate iosc's layer-shell implementation (§5.1) end-to-end without the full
 * panel/W0-sysroot link. It creates an anchored top-edge "panel" (full width,
 * 44px tall, exclusive-zone 44) and paints a solid bar into a wl_shm buffer, so
 * you can confirm: the configure handshake, anchored placement, the exclusive
 * zone (work area), and z-banding above toplevels.
 *
 * Args (all optional):
 *   -layer N    0 bg, 1 bottom, 2 top (default), 3 overlay
 *   -anchor M   ANCHOR bitfield top|bottom|left|right (default 13 = top|left|right)
 *   -h N        height in logical px (default 44; width spans the output)
 *   -excl N     exclusive zone (default = height)
 *   -kbd N      keyboard interactivity 0 none (default) / 2 on_demand
 *   -color 0xRRGGBB  bar color (default teal)
 *
 * MIT. Standard libwayland-client boilerplate.
 */
#include <wayland-client.h>
#include "wlr-layer-shell-unstable-v1-client-protocol.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>

static struct wl_compositor        *compositor;
static struct wl_shm               *shm;
static struct zwlr_layer_shell_v1  *layer_shell;

static struct wl_surface             *surface;
static struct zwlr_layer_surface_v1  *layer_surface;

static int      opt_layer  = ZWLR_LAYER_SHELL_V1_LAYER_TOP;
static uint32_t opt_anchor = ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP
                           | ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT
                           | ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT;
static int      opt_h      = 44;
static int      opt_excl   = -1;      /* -1 => default to height */
static int      opt_kbd    = ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_NONE;
static uint32_t opt_color  = 0x00008080;   /* teal */

static int cur_w = 0, cur_h = 0;      /* size from the configure event */
static int painted = 0;

static int create_shm_file(size_t size)
{
    const char *dir = getenv("XDG_RUNTIME_DIR");
    if (!dir) dir = "/var/jb/tmp";
    char tmpl[256];
    snprintf(tmpl, sizeof(tmpl), "%s/iosc-layer-XXXXXX", dir);
    int fd = mkstemp(tmpl);
    if (fd < 0) { perror("mkstemp"); return -1; }
    unlink(tmpl);
    if (ftruncate(fd, (off_t)size) < 0) { perror("ftruncate"); close(fd); return -1; }
    return fd;
}

static void reg_global(void *data, struct wl_registry *reg, uint32_t name,
                       const char *iface, uint32_t version)
{
    (void)data; (void)version;
    if (!strcmp(iface, "wl_compositor"))
        compositor = wl_registry_bind(reg, name, &wl_compositor_interface, 4);
    else if (!strcmp(iface, "wl_shm"))
        shm = wl_registry_bind(reg, name, &wl_shm_interface, 1);
    else if (!strcmp(iface, "zwlr_layer_shell_v1"))
        layer_shell = wl_registry_bind(reg, name, &zwlr_layer_shell_v1_interface,
                                       version < 4 ? version : 4);
    fprintf(stderr, "client: global %s v%u\n", iface, version);
}
static void reg_global_remove(void *d, struct wl_registry *r, uint32_t n)
{ (void)d; (void)r; (void)n; }
static const struct wl_registry_listener registry_listener = {
    .global = reg_global, .global_remove = reg_global_remove,
};

static void paint(void)
{
    int w = cur_w > 0 ? cur_w : 800;
    int h = cur_h > 0 ? cur_h : opt_h;
    int stride = w * 4;
    size_t size = (size_t)stride * h;
    int fd = create_shm_file(size);
    if (fd < 0) return;
    uint32_t *px = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (px == MAP_FAILED) { perror("mmap"); close(fd); return; }
    /* Solid bar with a 2px darker rule along the inner edge, so the anchored
     * side and exact extent are obvious on screen. */
    for (int y = 0; y < h; y++)
        for (int x = 0; x < w; x++)
            px[y * w + x] = (x < 2 || y < 2 || x >= w - 2 || y >= h - 2)
                          ? 0x00ffffff : opt_color;

    struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, (int32_t)size);
    struct wl_buffer *buf = wl_shm_pool_create_buffer(pool, 0, w, h, stride,
                                                      WL_SHM_FORMAT_XRGB8888);
    wl_shm_pool_destroy(pool);
    munmap(px, size);
    close(fd);

    wl_surface_attach(surface, buf, 0, 0);
    wl_surface_damage(surface, 0, 0, w, h);
    wl_surface_commit(surface);
    painted = 1;
    fprintf(stderr, "client: painted layer buffer %dx%d color=0x%06x\n", w, h, opt_color);
}

static void ls_configure(void *data, struct zwlr_layer_surface_v1 *ls,
                         uint32_t serial, uint32_t w, uint32_t h)
{
    (void)data;
    cur_w = (int)w;
    cur_h = (int)h;
    fprintf(stderr, "client: layer_surface.configure serial=%u %ux%u\n", serial, w, h);
    zwlr_layer_surface_v1_ack_configure(ls, serial);
    paint();
}
static void ls_closed(void *data, struct zwlr_layer_surface_v1 *ls)
{ (void)data; (void)ls; fprintf(stderr, "client: layer_surface.closed\n"); exit(0); }
static const struct zwlr_layer_surface_v1_listener ls_listener = {
    .configure = ls_configure, .closed = ls_closed,
};

int main(int argc, char **argv)
{
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-layer")  && i + 1 < argc) opt_layer  = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-anchor") && i + 1 < argc) opt_anchor = (uint32_t)strtoul(argv[++i], NULL, 0);
        else if (!strcmp(argv[i], "-h")     && i + 1 < argc) opt_h      = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-excl")  && i + 1 < argc) opt_excl   = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-kbd")   && i + 1 < argc) opt_kbd    = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-color") && i + 1 < argc) opt_color  = (uint32_t)strtoul(argv[++i], NULL, 0);
    }
    if (opt_excl < 0) opt_excl = opt_h;

    struct wl_display *dpy = wl_display_connect(NULL);
    if (!dpy) { fprintf(stderr, "client: wl_display_connect failed "
                                "(WAYLAND_DISPLAY + XDG_RUNTIME_DIR?)\n"); return 1; }
    struct wl_registry *reg = wl_display_get_registry(dpy);
    wl_registry_add_listener(reg, &registry_listener, NULL);
    wl_display_roundtrip(dpy);

    if (!compositor || !shm || !layer_shell) {
        fprintf(stderr, "client: missing globals (compositor=%p shm=%p layer_shell=%p) "
                        "-- compositor lacks zwlr_layer_shell_v1?\n",
                (void *)compositor, (void *)shm, (void *)layer_shell);
        return 1;
    }

    surface = wl_compositor_create_surface(compositor);
    layer_surface = zwlr_layer_shell_v1_get_layer_surface(
        layer_shell, surface, NULL, (uint32_t)opt_layer, "iosc-layer-test");
    zwlr_layer_surface_v1_add_listener(layer_surface, &ls_listener, NULL);
    zwlr_layer_surface_v1_set_anchor(layer_surface, opt_anchor);
    zwlr_layer_surface_v1_set_size(layer_surface, 0, (uint32_t)opt_h);
    zwlr_layer_surface_v1_set_exclusive_zone(layer_surface, opt_excl);
    zwlr_layer_surface_v1_set_keyboard_interactivity(layer_surface, (uint32_t)opt_kbd);
    wl_surface_commit(surface);   /* initial commit, no buffer -> configure */

    fprintf(stderr, "client: layer surface requested (layer=%d anchor=0x%x h=%d excl=%d kbd=%d); "
                    "entering dispatch\n", opt_layer, opt_anchor, opt_h, opt_excl, opt_kbd);
    while (wl_display_dispatch(dpy) != -1)
        ;
    (void)painted;
    wl_display_disconnect(dpy);
    return 0;
}

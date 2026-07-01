/*
 * iosc-spb-test.c — validate single-pixel-buffer-v1 (§ compositor-only track).
 *
 * Binds wp_single_pixel_buffer_manager_v1 + wp_viewporter + xdg-shell, creates a
 * 1x1 solid ORANGE buffer (r=255,g=128,b=0,a=255), scales it to the whole toplevel
 * with a viewport, and commits. No wl_shm, no client-side pixels at all — the fill
 * comes entirely from the compositor sampling the single texel. Run iosc with
 * IOSC_PROBE=1 and the app-space map should read a solid field of 'O'.
 *
 * MIT. Standard libwayland-client boilerplate.
 */
#include <wayland-client.h>
#include "xdg-shell-client-protocol.h"
#include "single-pixel-buffer-v1-client-protocol.h"
#include "viewporter-client-protocol.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static struct wl_compositor                     *compositor;
static struct xdg_wm_base                        *wm_base;
static struct wp_single_pixel_buffer_manager_v1  *spb_mgr;
static struct wp_viewporter                       *viewporter;

static int want_w = 800, want_h = 600;
static int configured = 0, painted = 0;

static void wm_base_ping(void *d, struct xdg_wm_base *b, uint32_t serial)
{ (void)d; xdg_wm_base_pong(b, serial); }
static const struct xdg_wm_base_listener wm_base_listener = { .ping = wm_base_ping };

static void reg_global(void *data, struct wl_registry *reg, uint32_t name,
                       const char *iface, uint32_t version)
{
    (void)data; (void)version;
    if (!strcmp(iface, "wl_compositor"))
        compositor = wl_registry_bind(reg, name, &wl_compositor_interface, 4);
    else if (!strcmp(iface, "xdg_wm_base")) {
        wm_base = wl_registry_bind(reg, name, &xdg_wm_base_interface, 1);
        xdg_wm_base_add_listener(wm_base, &wm_base_listener, NULL);
    } else if (!strcmp(iface, "wp_single_pixel_buffer_manager_v1"))
        spb_mgr = wl_registry_bind(reg, name, &wp_single_pixel_buffer_manager_v1_interface, 1);
    else if (!strcmp(iface, "wp_viewporter"))
        viewporter = wl_registry_bind(reg, name, &wp_viewporter_interface, 1);
    fprintf(stderr, "spb-test: global %s v%u\n", iface, version);
}
static void reg_global_remove(void *d, struct wl_registry *r, uint32_t n)
{ (void)d; (void)r; (void)n; }
static const struct wl_registry_listener registry_listener = {
    .global = reg_global, .global_remove = reg_global_remove,
};

static struct wl_surface  *surface;
static struct xdg_surface *xsurface;
static struct wp_viewport *viewport;

static void draw(void)
{
    /* Orange, premultiplied, full alpha: values are value/0xFFFFFFFF fractions. */
    struct wl_buffer *buf = wp_single_pixel_buffer_manager_v1_create_u32_rgba_buffer(
        spb_mgr, 0xFFFFFFFFu /*r=255*/, 0x80808080u /*g~128*/, 0u /*b=0*/, 0xFFFFFFFFu /*a=255*/);
    if (!buf) { fprintf(stderr, "spb-test: create_u32_rgba failed\n"); return; }
    wp_viewport_set_destination(viewport, want_w, want_h);
    wl_surface_attach(surface, buf, 0, 0);
    wl_surface_damage(surface, 0, 0, want_w, want_h);
    wl_surface_commit(surface);
    painted = 1;
    fprintf(stderr, "spb-test: committed 1x1 orange scaled to %dx%d\n", want_w, want_h);
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
    fprintf(stderr, "spb-test: toplevel configure %dx%d\n", w, h);
}
static void top_close(void *d, struct xdg_toplevel *t){ (void)d; (void)t; exit(0); }
static const struct xdg_toplevel_listener top_listener = {
    .configure = top_configure, .close = top_close,
};

int main(void)
{
    struct wl_display *dpy = wl_display_connect(NULL);
    if (!dpy) { fprintf(stderr, "spb-test: wl_display_connect failed\n"); return 1; }

    struct wl_registry *reg = wl_display_get_registry(dpy);
    wl_registry_add_listener(reg, &registry_listener, NULL);
    wl_display_roundtrip(dpy);

    if (!compositor || !wm_base || !spb_mgr || !viewporter) {
        fprintf(stderr, "spb-test: missing globals (compositor=%p wm_base=%p spb=%p vp=%p)\n",
                (void*)compositor, (void*)wm_base, (void*)spb_mgr, (void*)viewporter);
        return 1;
    }

    surface  = wl_compositor_create_surface(compositor);
    xsurface = xdg_wm_base_get_xdg_surface(wm_base, surface);
    xdg_surface_add_listener(xsurface, &xsurf_listener, NULL);
    struct xdg_toplevel *top = xdg_surface_get_toplevel(xsurface);
    xdg_toplevel_add_listener(top, &top_listener, NULL);
    xdg_toplevel_set_title(top, "iosc-spb-test");
    xdg_toplevel_set_app_id(top, "com.max.iosc.spbtest");
    viewport = wp_viewporter_get_viewport(viewporter, surface);
    wl_surface_commit(surface);

    fprintf(stderr, "spb-test: mapped; entering dispatch loop\n");
    while (wl_display_dispatch(dpy) != -1)
        ;
    wl_display_disconnect(dpy);
    return 0;
}

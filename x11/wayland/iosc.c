/*
 * iosc.c — a minimal single-output Wayland compositor for jailbroken iOS ("M1").
 *
 * Clean-room, MIT. Design follows owl-compositor/owl (libwayland-server + an
 * IOSurface hand-off), but NONE of Owl's GPL code is used here. The whole point:
 * iOS has no DRM/KMS, so off-the-shelf compositors (wlroots/Mutter/Weston) don't
 * apply — they drive a GPU/display directly. Here UIKit owns the panel, so the
 * compositor is "headless" with respect to scanout and instead presents every
 * committed client buffer into ONE shared BGRA IOSurface. The existing Xios iOS
 * app (apps/Xios) maps that IOSurface into a CAMetalLayer and shows it. We reuse
 * Xios's server-side rendezvous verbatim (linux-build/patches/xios/xios_surface.c):
 *
 *      wl_shm client buffer ── commit ──► copy into IOSurface ──► xios_notify_dirty()
 *                                              ▲
 *                                  xios_surface_create() + xios_server_start()
 *                                  hands the surface's mach port to the Xios app
 *
 * M1 scope (single fullscreen surface, software wl_shm only):
 *   globals: wl_compositor (wl_surface/wl_region), wl_shm (init_shm), and
 *            xdg_wm_base/xdg_surface/xdg_toplevel (so a real client can map).
 *   On wl_surface.commit we blit the attached wl_shm buffer into the output
 *   IOSurface and signal damage. Input, multi-window, popups, and zero-copy GPU
 *   IOSurface buffers are later milestones (see x11/docs/wayland-plan.md).
 */
#include <wayland-server.h>
#include <wayland-server-protocol.h>
#include "xdg-shell-server-protocol.h"

#include "xios_surface.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <stdint.h>

/* xios_surface.c writes the geometry handshake JSON and references `display`
 * (the X display-number string) for it. There is no X server here; this is only
 * cosmetic in xios.json ("display":":9"). */
char *display = "9";

/* ---- output -------------------------------------------------------------- */

static struct wl_display *g_display;
static uint8_t          *g_fb;        /* IOSurface base address (BGRA8) */
static int               g_width  = 2160;  /* iPad 7 native; app aspect-fits anyway */
static int               g_height = 1620;
static int               g_stride;    /* real bytes-per-row (IOSurface-padded) */

/* M1 presents one toplevel; remember it so a configure can size it fullscreen. */
struct iosc_surface;

static uint32_t now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint32_t)(ts.tv_sec * 1000 + ts.tv_nsec / 1000000);
}

/* ---- per-surface state --------------------------------------------------- */

struct iosc_surface {
    struct wl_resource *resource;        /* wl_surface */
    struct wl_resource *pending_buffer;  /* last wl_surface.attach (may be NULL) */
    int                 buffer_attached; /* attach was called this cycle */
    struct wl_resource *xdg_surface;     /* xdg_surface role, or NULL */
    struct wl_resource *xdg_toplevel;    /* xdg_toplevel role, or NULL */
    int                 configured;      /* sent the initial xdg configure */
    struct wl_list      frame_callbacks; /* pending wl_callback resources */
};

/* a queued frame-callback resource */
struct iosc_frame {
    struct wl_resource *resource;
    struct wl_list      link;
};

/* ---- present: copy a committed wl_shm buffer into the output IOSurface ---- */

static void present_shm(struct iosc_surface *s, struct wl_resource *buffer)
{
    struct wl_shm_buffer *shm = wl_shm_buffer_get(buffer);
    if (!shm) {
        /* Non-shm (e.g. dmabuf/IOSurface) buffers are a later milestone. */
        fprintf(stderr, "iosc: commit with non-shm buffer (ignored in M1)\n");
        return;
    }

    wl_shm_buffer_begin_access(shm);
    const uint8_t *src = wl_shm_buffer_get_data(shm);
    int   src_stride  = wl_shm_buffer_get_stride(shm);
    int   bw          = wl_shm_buffer_get_width(shm);
    int   bh          = wl_shm_buffer_get_height(shm);
    uint32_t fmt      = wl_shm_buffer_get_format(shm);

    /* wl_shm ARGB8888/XRGB8888 are native-endian 0xAARRGGBB; on little-endian
     * arm64 that is B,G,R,A in memory — exactly the IOSurface's BGRA8 byte order,
     * so the copy is a straight per-row memcpy (no swizzle). */
    if (fmt != WL_SHM_FORMAT_ARGB8888 && fmt != WL_SHM_FORMAT_XRGB8888) {
        fprintf(stderr, "iosc: unsupported shm format 0x%x (ignored)\n", fmt);
        wl_shm_buffer_end_access(shm);
        return;
    }

    int rows = bh < g_height ? bh : g_height;
    int cols = bw < g_width  ? bw : g_width;
    size_t row_bytes = (size_t)cols * 4;
    for (int y = 0; y < rows; y++)
        memcpy(g_fb + (size_t)y * g_stride, src + (size_t)y * src_stride, row_bytes);

    wl_shm_buffer_end_access(shm);

    /* We copied the pixels out synchronously, so the client may reuse the buffer. */
    wl_buffer_send_release(buffer);

    xios_notify_dirty();

    /* Read a center pixel straight back out of the IOSurface memory so the log
     * proves the client's pixels actually landed in the shared surface (BGRA). */
    uint32_t mid = *(uint32_t *)(g_fb + (size_t)(rows / 2) * g_stride
                                       + (size_t)(cols / 2) * 4);
    fprintf(stderr, "iosc: presented %dx%d (fmt 0x%x) -> IOSurface; center BGRA=0x%08x\n",
            bw, bh, fmt, mid);
}

/* ---- wl_surface ---------------------------------------------------------- */

static void surface_handle_destroy(struct wl_client *c, struct wl_resource *r)
{
    (void)c; wl_resource_destroy(r);
}
static void surface_attach(struct wl_client *c, struct wl_resource *r,
                           struct wl_resource *buffer, int32_t x, int32_t y)
{
    (void)c; (void)x; (void)y;
    struct iosc_surface *s = wl_resource_get_user_data(r);
    s->pending_buffer  = buffer;
    s->buffer_attached = 1;
}
static void surface_damage(struct wl_client *c, struct wl_resource *r,
                           int32_t x, int32_t y, int32_t w, int32_t h)
{ (void)c; (void)r; (void)x; (void)y; (void)w; (void)h; }

static void surface_frame(struct wl_client *c, struct wl_resource *r, uint32_t cb)
{
    struct iosc_surface *s = wl_resource_get_user_data(r);
    struct iosc_frame *f = calloc(1, sizeof(*f));
    if (!f) { wl_client_post_no_memory(c); return; }
    f->resource = wl_resource_create(c, &wl_callback_interface, 1, cb);
    if (!f->resource) { free(f); wl_client_post_no_memory(c); return; }
    /* No impl/user-data: a callback has no requests; we destroy it after done. */
    wl_list_insert(&s->frame_callbacks, &f->link);
}
static void surface_set_opaque_region(struct wl_client *c, struct wl_resource *r,
                                      struct wl_resource *region)
{ (void)c; (void)r; (void)region; }
static void surface_set_input_region(struct wl_client *c, struct wl_resource *r,
                                     struct wl_resource *region)
{ (void)c; (void)r; (void)region; }

static void surface_commit(struct wl_client *c, struct wl_resource *r)
{
    (void)c;
    struct iosc_surface *s = wl_resource_get_user_data(r);

    if (s->buffer_attached) {
        struct wl_resource *buf = s->pending_buffer;
        s->pending_buffer  = NULL;
        s->buffer_attached = 0;
        if (buf)
            present_shm(s, buf);
    }

    /* Fire (and retire) frame callbacks: tells the client it may draw the next
     * frame. Without this, throttled clients (simple-shm, GTK) stall after one. */
    uint32_t t = now_ms();
    struct iosc_frame *f, *tmp;
    wl_list_for_each_safe(f, tmp, &s->frame_callbacks, link) {
        wl_callback_send_done(f->resource, t);
        wl_resource_destroy(f->resource);
        wl_list_remove(&f->link);
        free(f);
    }
}
static void surface_set_buffer_transform(struct wl_client *c, struct wl_resource *r,
                                         int32_t transform)
{ (void)c; (void)r; (void)transform; }
static void surface_set_buffer_scale(struct wl_client *c, struct wl_resource *r,
                                     int32_t scale)
{ (void)c; (void)r; (void)scale; }
static void surface_damage_buffer(struct wl_client *c, struct wl_resource *r,
                                  int32_t x, int32_t y, int32_t w, int32_t h)
{ (void)c; (void)r; (void)x; (void)y; (void)w; (void)h; }

static const struct wl_surface_interface surface_impl = {
    .destroy              = surface_handle_destroy,
    .attach               = surface_attach,
    .damage               = surface_damage,
    .frame                = surface_frame,
    .set_opaque_region    = surface_set_opaque_region,
    .set_input_region     = surface_set_input_region,
    .commit               = surface_commit,
    .set_buffer_transform = surface_set_buffer_transform,
    .set_buffer_scale     = surface_set_buffer_scale,
    .damage_buffer        = surface_damage_buffer,
    /* .offset is v5; we advertise wl_compositor v4 so it's never called. */
};

static void surface_resource_destroy(struct wl_resource *r)
{
    struct iosc_surface *s = wl_resource_get_user_data(r);
    if (!s) return;
    struct iosc_frame *f, *tmp;
    wl_list_for_each_safe(f, tmp, &s->frame_callbacks, link) {
        wl_resource_destroy(f->resource);
        wl_list_remove(&f->link);
        free(f);
    }
    free(s);
}

/* ---- wl_region (minimal; geometry is ignored in M1) ---------------------- */

static void region_destroy(struct wl_client *c, struct wl_resource *r)
{ (void)c; wl_resource_destroy(r); }
static void region_add(struct wl_client *c, struct wl_resource *r,
                       int32_t x, int32_t y, int32_t w, int32_t h)
{ (void)c; (void)r; (void)x; (void)y; (void)w; (void)h; }
static void region_subtract(struct wl_client *c, struct wl_resource *r,
                            int32_t x, int32_t y, int32_t w, int32_t h)
{ (void)c; (void)r; (void)x; (void)y; (void)w; (void)h; }
static const struct wl_region_interface region_impl = {
    .destroy = region_destroy, .add = region_add, .subtract = region_subtract,
};

/* ---- wl_compositor -------------------------------------------------------- */

static void compositor_create_surface(struct wl_client *client,
                                       struct wl_resource *resource, uint32_t id)
{
    struct iosc_surface *s = calloc(1, sizeof(*s));
    if (!s) { wl_client_post_no_memory(client); return; }
    wl_list_init(&s->frame_callbacks);
    s->resource = wl_resource_create(client, &wl_surface_interface,
                                     wl_resource_get_version(resource), id);
    if (!s->resource) { free(s); wl_client_post_no_memory(client); return; }
    wl_resource_set_implementation(s->resource, &surface_impl, s,
                                   surface_resource_destroy);
    fprintf(stderr, "iosc: wl_surface created\n");
}
static void compositor_create_region(struct wl_client *client,
                                      struct wl_resource *resource, uint32_t id)
{
    struct wl_resource *res = wl_resource_create(client, &wl_region_interface,
                                                 wl_resource_get_version(resource), id);
    if (!res) { wl_client_post_no_memory(client); return; }
    wl_resource_set_implementation(res, &region_impl, NULL, NULL);
}
static const struct wl_compositor_interface compositor_impl = {
    .create_surface = compositor_create_surface,
    .create_region  = compositor_create_region,
};

static void compositor_bind(struct wl_client *client, void *data,
                            uint32_t version, uint32_t id)
{
    (void)data;
    struct wl_resource *r = wl_resource_create(client, &wl_compositor_interface,
                                               version, id);
    if (!r) { wl_client_post_no_memory(client); return; }
    wl_resource_set_implementation(r, &compositor_impl, NULL, NULL);
}

/* ---- xdg_shell ----------------------------------------------------------- */

/* Send the initial configure that lets a client map: tell the toplevel the
 * output size (fullscreen), then the xdg_surface serial it must ack. */
static void send_initial_configure(struct iosc_surface *s)
{
    struct wl_array states;
    wl_array_init(&states);
    uint32_t *st = wl_array_add(&states, sizeof(uint32_t));
    if (st) *st = XDG_TOPLEVEL_STATE_ACTIVATED;
    xdg_toplevel_send_configure(s->xdg_toplevel, g_width, g_height, &states);
    wl_array_release(&states);

    uint32_t serial = wl_display_next_serial(g_display);
    xdg_surface_send_configure(s->xdg_surface, serial);
    s->configured = 1;
}

/* xdg_toplevel: almost everything is a no-op for a single fullscreen window. */
static void xt_destroy(struct wl_client *c, struct wl_resource *r){ (void)c; wl_resource_destroy(r); }
static void xt_set_parent(struct wl_client *c, struct wl_resource *r, struct wl_resource *p){ (void)c;(void)r;(void)p; }
static void xt_set_title(struct wl_client *c, struct wl_resource *r, const char *t){ (void)c;(void)r; fprintf(stderr, "iosc: toplevel title=\"%s\"\n", t ? t : ""); }
static void xt_set_app_id(struct wl_client *c, struct wl_resource *r, const char *a){ (void)c;(void)r; fprintf(stderr, "iosc: toplevel app_id=\"%s\"\n", a ? a : ""); }
static void xt_show_window_menu(struct wl_client *c, struct wl_resource *r, struct wl_resource *seat, uint32_t serial, int32_t x, int32_t y){ (void)c;(void)r;(void)seat;(void)serial;(void)x;(void)y; }
static void xt_move(struct wl_client *c, struct wl_resource *r, struct wl_resource *seat, uint32_t serial){ (void)c;(void)r;(void)seat;(void)serial; }
static void xt_resize(struct wl_client *c, struct wl_resource *r, struct wl_resource *seat, uint32_t serial, uint32_t edges){ (void)c;(void)r;(void)seat;(void)serial;(void)edges; }
static void xt_set_max_size(struct wl_client *c, struct wl_resource *r, int32_t w, int32_t h){ (void)c;(void)r;(void)w;(void)h; }
static void xt_set_min_size(struct wl_client *c, struct wl_resource *r, int32_t w, int32_t h){ (void)c;(void)r;(void)w;(void)h; }
static void xt_set_maximized(struct wl_client *c, struct wl_resource *r){ (void)c;(void)r; }
static void xt_unset_maximized(struct wl_client *c, struct wl_resource *r){ (void)c;(void)r; }
static void xt_set_fullscreen(struct wl_client *c, struct wl_resource *r, struct wl_resource *out){ (void)c;(void)r;(void)out; }
static void xt_unset_fullscreen(struct wl_client *c, struct wl_resource *r){ (void)c;(void)r; }
static void xt_set_minimized(struct wl_client *c, struct wl_resource *r){ (void)c;(void)r; }
static const struct xdg_toplevel_interface xdg_toplevel_impl = {
    .destroy = xt_destroy, .set_parent = xt_set_parent, .set_title = xt_set_title,
    .set_app_id = xt_set_app_id, .show_window_menu = xt_show_window_menu,
    .move = xt_move, .resize = xt_resize, .set_max_size = xt_set_max_size,
    .set_min_size = xt_set_min_size, .set_maximized = xt_set_maximized,
    .unset_maximized = xt_unset_maximized, .set_fullscreen = xt_set_fullscreen,
    .unset_fullscreen = xt_unset_fullscreen, .set_minimized = xt_set_minimized,
};

/* xdg_surface */
static void xs_destroy(struct wl_client *c, struct wl_resource *r){ (void)c; wl_resource_destroy(r); }
static void xs_get_toplevel(struct wl_client *c, struct wl_resource *r, uint32_t id)
{
    struct iosc_surface *s = wl_resource_get_user_data(r);
    struct wl_resource *tl = wl_resource_create(c, &xdg_toplevel_interface,
                                                wl_resource_get_version(r), id);
    if (!tl) { wl_client_post_no_memory(c); return; }
    wl_resource_set_implementation(tl, &xdg_toplevel_impl, s, NULL);
    s->xdg_toplevel = tl;
    fprintf(stderr, "iosc: xdg_toplevel created -> sending initial configure %dx%d\n",
            g_width, g_height);
    send_initial_configure(s);
}
static void xs_get_popup(struct wl_client *c, struct wl_resource *r, uint32_t id,
                         struct wl_resource *parent, struct wl_resource *positioner)
{ (void)parent; (void)positioner;
    /* Popups are a later milestone; create the object so the client doesn't fault. */
    struct wl_resource *p = wl_resource_create(c, &xdg_popup_interface,
                                               wl_resource_get_version(r), id);
    if (p) wl_resource_set_implementation(p, NULL, NULL, NULL);
    fprintf(stderr, "iosc: xdg_popup requested (unsupported in M1)\n");
}
static void xs_set_window_geometry(struct wl_client *c, struct wl_resource *r,
                                   int32_t x, int32_t y, int32_t w, int32_t h)
{ (void)c;(void)r;(void)x;(void)y;(void)w;(void)h; }
static void xs_ack_configure(struct wl_client *c, struct wl_resource *r, uint32_t serial)
{ (void)c;(void)r;(void)serial; }
static const struct xdg_surface_interface xdg_surface_impl = {
    .destroy = xs_destroy, .get_toplevel = xs_get_toplevel, .get_popup = xs_get_popup,
    .set_window_geometry = xs_set_window_geometry, .ack_configure = xs_ack_configure,
};

/* xdg_wm_base */
static void wb_destroy(struct wl_client *c, struct wl_resource *r){ (void)c; wl_resource_destroy(r); }
static void wb_create_positioner(struct wl_client *c, struct wl_resource *r, uint32_t id)
{
    struct wl_resource *p = wl_resource_create(c, &xdg_positioner_interface,
                                               wl_resource_get_version(r), id);
    if (p) wl_resource_set_implementation(p, NULL, NULL, NULL);
}
static void wb_get_xdg_surface(struct wl_client *c, struct wl_resource *r,
                               uint32_t id, struct wl_resource *surface)
{
    struct iosc_surface *s = wl_resource_get_user_data(surface);
    struct wl_resource *xs = wl_resource_create(c, &xdg_surface_interface,
                                                wl_resource_get_version(r), id);
    if (!xs) { wl_client_post_no_memory(c); return; }
    wl_resource_set_implementation(xs, &xdg_surface_impl, s, NULL);
    s->xdg_surface = xs;
    fprintf(stderr, "iosc: xdg_surface created for wl_surface\n");
}
static void wb_pong(struct wl_client *c, struct wl_resource *r, uint32_t serial)
{ (void)c;(void)r;(void)serial; }
static const struct xdg_wm_base_interface xdg_wm_base_impl = {
    .destroy = wb_destroy, .create_positioner = wb_create_positioner,
    .get_xdg_surface = wb_get_xdg_surface, .pong = wb_pong,
};

static void xdg_wm_base_bind(struct wl_client *client, void *data,
                             uint32_t version, uint32_t id)
{
    (void)data;
    struct wl_resource *r = wl_resource_create(client, &xdg_wm_base_interface,
                                               version, id);
    if (!r) { wl_client_post_no_memory(client); return; }
    wl_resource_set_implementation(r, &xdg_wm_base_impl, NULL, NULL);
    fprintf(stderr, "iosc: client bound xdg_wm_base v%u\n", version);
}

/* ---- main ---------------------------------------------------------------- */

int main(int argc, char **argv)
{
    const char *sock_name = "wayland-0";
    const char *ddx_sock  = "/var/jb/tmp/iosc-ddx.sock";
    const char *json_path = "/var/jb/tmp/xios.json";   /* the Xios app reads this */
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-g") && i + 1 < argc) {
            sscanf(argv[++i], "%dx%d", &g_width, &g_height);
        } else if (!strcmp(argv[i], "-s") && i + 1 < argc) {
            sock_name = argv[++i];
        }
    }

    /* 1) Output: one fullscreen BGRA IOSurface + the rendezvous the Xios app
     *    already speaks. xios_server_start writes xios.json so the app finds us. */
    int alloc = 0;
    g_fb = xios_surface_create(g_width, g_height, &g_stride, &alloc);
    if (!g_fb) {
        fprintf(stderr, "iosc: xios_surface_create failed (IOSurface entitlement?)\n");
        return 1;
    }
    if (xios_server_start(ddx_sock, json_path, g_width, g_height, g_stride) != 0) {
        fprintf(stderr, "iosc: xios_server_start failed\n");
        return 1;
    }
    fprintf(stderr, "iosc: output IOSurface %dx%d stride=%d; app socket=%s\n",
            g_width, g_height, g_stride, ddx_sock);

    /* 2) Wayland display + globals. */
    g_display = wl_display_create();
    if (!g_display) { fprintf(stderr, "iosc: wl_display_create failed\n"); return 1; }

    if (wl_display_add_socket(g_display, sock_name) != 0) {
        fprintf(stderr, "iosc: wl_display_add_socket(%s) failed "
                        "(XDG_RUNTIME_DIR set + writable?)\n", sock_name);
        return 1;
    }
    if (wl_display_init_shm(g_display) != 0) {
        fprintf(stderr, "iosc: wl_display_init_shm failed\n");
        return 1;
    }
    wl_global_create(g_display, &wl_compositor_interface, 4, NULL, compositor_bind);
    wl_global_create(g_display, &xdg_wm_base_interface, 1, NULL, xdg_wm_base_bind);

    fprintf(stderr, "iosc: listening on WAYLAND_DISPLAY=%s (XDG_RUNTIME_DIR=%s)\n",
            sock_name, getenv("XDG_RUNTIME_DIR") ? getenv("XDG_RUNTIME_DIR") : "(unset)");
    fprintf(stderr, "iosc: globals: wl_compositor v4, wl_shm, xdg_wm_base v1\n");

    /* 3) Run the event loop forever. */
    wl_display_run(g_display);

    wl_display_destroy(g_display);
    xios_server_stop();
    return 0;
}

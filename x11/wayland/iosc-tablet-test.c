/*
 * iosc-tablet-test.c — validates zwp_tablet_manager_v2 (Apple Pencil) against
 * iosc. Maps a purple xdg_toplevel and prints the announced tablet/tool plus
 * every stroke event with pressure (0..1) and tilt (degrees). Drive it with a
 * real Pencil (once the Xios app emits IOSC_IN_PENCIL) or with the injector:
 *
 *   iosc-input-test -p 300 300 900 500
 *
 * Expected for the injector stroke: "tablet: Apple Pencil", "tool: PEN
 * (pressure, tilt)", then PROXIMITY_IN -> DOWN -> 12x MOTION with pressure
 * ramping 0.20 -> 1.00 at tilt 30/-15 -> UP -> PROXIMITY_OUT, framed.
 *
 * MIT. Standard libwayland-client boilerplate.
 */
#include <wayland-client.h>
#include "xdg-shell-client-protocol.h"
#include "tablet-v2-client-protocol.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>

static struct wl_compositor *compositor;
static struct wl_shm        *shm;
static struct xdg_wm_base   *wm_base;
static struct wl_seat       *seat;
static struct zwp_tablet_manager_v2 *tablet_mgr;
static struct wl_surface    *surface;

static int want_w = 700, want_h = 500;
static double last_pressure;
static double last_tilt_x, last_tilt_y;

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
                          ? 0x00ffffffu : 0x00502080u;   /* purple, white border */
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

/* ---- zwp_tablet_v2 --------------------------------------------------------- */

static void tab_name(void *d, struct zwp_tablet_v2 *t, const char *name)
{ (void)d; (void)t; fprintf(stderr, "tablet-test: tablet name \"%s\"\n", name); }
static void tab_id(void *d, struct zwp_tablet_v2 *t, uint32_t vid, uint32_t pid)
{ (void)d; (void)t; (void)vid; (void)pid; }
static void tab_path(void *d, struct zwp_tablet_v2 *t, const char *path)
{ (void)d; (void)t; fprintf(stderr, "tablet-test: tablet path %s\n", path); }
static void tab_done(void *d, struct zwp_tablet_v2 *t)
{ (void)d; (void)t; }
static void tab_removed(void *d, struct zwp_tablet_v2 *t)
{ (void)d; zwp_tablet_v2_destroy(t); }
static const struct zwp_tablet_v2_listener tablet_listener = {
    .name = tab_name, .id = tab_id, .path = tab_path,
    .done = tab_done, .removed = tab_removed,
};

/* ---- zwp_tablet_tool_v2 ---------------------------------------------------- */

static void tool_type(void *d, struct zwp_tablet_tool_v2 *t, uint32_t type)
{ (void)d; (void)t;
    fprintf(stderr, "tablet-test: tool type %s\n",
            type == ZWP_TABLET_TOOL_V2_TYPE_PEN ? "PEN" : "other"); }
static void tool_hw_serial(void *d, struct zwp_tablet_tool_v2 *t, uint32_t hi, uint32_t lo)
{ (void)d; (void)t; (void)hi; (void)lo; }
static void tool_hw_wacom(void *d, struct zwp_tablet_tool_v2 *t, uint32_t hi, uint32_t lo)
{ (void)d; (void)t; (void)hi; (void)lo; }
static void tool_capability(void *d, struct zwp_tablet_tool_v2 *t, uint32_t cap)
{ (void)d; (void)t;
    fprintf(stderr, "tablet-test: tool capability %s\n",
            cap == ZWP_TABLET_TOOL_V2_CAPABILITY_PRESSURE ? "pressure" :
            cap == ZWP_TABLET_TOOL_V2_CAPABILITY_TILT ? "tilt" : "other"); }
static void tool_done(void *d, struct zwp_tablet_tool_v2 *t)
{ (void)d; (void)t; }
static void tool_removed(void *d, struct zwp_tablet_tool_v2 *t)
{ (void)d; zwp_tablet_tool_v2_destroy(t); }
static void tool_prox_in(void *d, struct zwp_tablet_tool_v2 *t, uint32_t serial,
                         struct zwp_tablet_v2 *tab, struct wl_surface *s)
{ (void)d; (void)t; (void)serial; (void)tab;
    fprintf(stderr, "tablet-test: PROXIMITY_IN (%s)\n",
            s == surface ? "our surface" : "other surface"); }
static void tool_prox_out(void *d, struct zwp_tablet_tool_v2 *t)
{ (void)d; (void)t; fprintf(stderr, "tablet-test: PROXIMITY_OUT\n"); }
static void tool_down(void *d, struct zwp_tablet_tool_v2 *t, uint32_t serial)
{ (void)d; (void)t; (void)serial; fprintf(stderr, "tablet-test: DOWN\n"); }
static void tool_up(void *d, struct zwp_tablet_tool_v2 *t)
{ (void)d; (void)t; fprintf(stderr, "tablet-test: UP\n"); }
static void tool_motion(void *d, struct zwp_tablet_tool_v2 *t, wl_fixed_t x, wl_fixed_t y)
{ (void)d; (void)t;
    fprintf(stderr, "tablet-test: MOTION %.0f,%.0f pressure=%.2f tilt=%.0f/%.0f\n",
            wl_fixed_to_double(x), wl_fixed_to_double(y),
            last_pressure, last_tilt_x, last_tilt_y); }
static void tool_pressure(void *d, struct zwp_tablet_tool_v2 *t, uint32_t p)
{ (void)d; (void)t; last_pressure = (double)p / 65535.0; }
static void tool_distance(void *d, struct zwp_tablet_tool_v2 *t, uint32_t v)
{ (void)d; (void)t; (void)v; }
static void tool_tilt(void *d, struct zwp_tablet_tool_v2 *t, wl_fixed_t tx, wl_fixed_t ty)
{ (void)d; (void)t;
    last_tilt_x = wl_fixed_to_double(tx);
    last_tilt_y = wl_fixed_to_double(ty); }
static void tool_rotation(void *d, struct zwp_tablet_tool_v2 *t, wl_fixed_t v)
{ (void)d; (void)t; (void)v; }
static void tool_slider(void *d, struct zwp_tablet_tool_v2 *t, int32_t v)
{ (void)d; (void)t; (void)v; }
static void tool_wheel(void *d, struct zwp_tablet_tool_v2 *t, wl_fixed_t deg, int32_t clicks)
{ (void)d; (void)t; (void)deg; (void)clicks; }
static void tool_button(void *d, struct zwp_tablet_tool_v2 *t, uint32_t serial,
                        uint32_t button, uint32_t state)
{ (void)d; (void)t; (void)serial; (void)button; (void)state; }
static void tool_frame(void *d, struct zwp_tablet_tool_v2 *t, uint32_t time)
{ (void)d; (void)t; (void)time; }
static const struct zwp_tablet_tool_v2_listener tool_listener = {
    .type = tool_type, .hardware_serial = tool_hw_serial,
    .hardware_id_wacom = tool_hw_wacom, .capability = tool_capability,
    .done = tool_done, .removed = tool_removed,
    .proximity_in = tool_prox_in, .proximity_out = tool_prox_out,
    .down = tool_down, .up = tool_up, .motion = tool_motion,
    .pressure = tool_pressure, .distance = tool_distance, .tilt = tool_tilt,
    .rotation = tool_rotation, .slider = tool_slider, .wheel = tool_wheel,
    .button = tool_button, .frame = tool_frame,
};

/* ---- zwp_tablet_seat_v2 ---------------------------------------------------- */

static void tseat_tablet_added(void *d, struct zwp_tablet_seat_v2 *s, struct zwp_tablet_v2 *t)
{ (void)d; (void)s; zwp_tablet_v2_add_listener(t, &tablet_listener, NULL); }
static void tseat_tool_added(void *d, struct zwp_tablet_seat_v2 *s, struct zwp_tablet_tool_v2 *t)
{ (void)d; (void)s; zwp_tablet_tool_v2_add_listener(t, &tool_listener, NULL); }
static void tseat_pad_added(void *d, struct zwp_tablet_seat_v2 *s, struct zwp_tablet_pad_v2 *p)
{ (void)d; (void)s; (void)p; }
static const struct zwp_tablet_seat_v2_listener tseat_listener = {
    .tablet_added = tseat_tablet_added,
    .tool_added = tseat_tool_added,
    .pad_added = tseat_pad_added,
};

/* ---- registry / xdg boilerplate -------------------------------------------- */

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
    else if (!strcmp(iface, "wl_seat"))
        seat = wl_registry_bind(reg, name, &wl_seat_interface, 5);
    else if (!strcmp(iface, "zwp_tablet_manager_v2"))
        tablet_mgr = wl_registry_bind(reg, name, &zwp_tablet_manager_v2_interface, 1);
    else if (!strcmp(iface, "xdg_wm_base")) {
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
    if (!dpy) { fprintf(stderr, "tablet-test: wl_display_connect failed "
                                "(WAYLAND_DISPLAY + XDG_RUNTIME_DIR?)\n"); return 1; }
    struct wl_registry *reg = wl_display_get_registry(dpy);
    wl_registry_add_listener(reg, &registry_listener, NULL);
    wl_display_roundtrip(dpy);
    if (!compositor || !shm || !wm_base || !seat || !tablet_mgr) {
        fprintf(stderr, "tablet-test: missing globals (tablet_mgr=%p)\n",
                (void *)tablet_mgr);
        return 1;
    }
    struct zwp_tablet_seat_v2 *ts =
        zwp_tablet_manager_v2_get_tablet_seat(tablet_mgr, seat);
    zwp_tablet_seat_v2_add_listener(ts, &tseat_listener, NULL);

    surface = wl_compositor_create_surface(compositor);
    struct xdg_surface *xsurface = xdg_wm_base_get_xdg_surface(wm_base, surface);
    xdg_surface_add_listener(xsurface, &xsurf_listener, NULL);
    struct xdg_toplevel *top = xdg_surface_get_toplevel(xsurface);
    xdg_toplevel_add_listener(top, &top_listener, NULL);
    xdg_toplevel_set_title(top, "tablet test");
    xdg_toplevel_set_app_id(top, "com.max.iosc.tablettest");
    wl_surface_commit(surface);

    fprintf(stderr, "tablet-test: mapped (purple window); stroke it or run "
                    "iosc-input-test -p <x0> <y0> <x1> <y1>\n");
    while (wl_display_dispatch(dpy) != -1) { }
    wl_display_disconnect(dpy);
    return 0;
}

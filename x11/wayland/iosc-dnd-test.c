/*
 * iosc-dnd-test.c — validates wl_data_device drag-and-drop against iosc.
 *
 * Maps one xdg_toplevel. On pointer button PRESS it starts a drag carrying
 * "hello from iosc dnd" as text/plain (+ a 48x48 magenta drag icon); its own
 * wl_data_device then receives enter/motion/drop, streams the payload back over
 * the offer pipe, prints it, and finishes the offer. Press, drag a little, and
 * release inside the window: a self-drop exercises the entire protocol flow.
 *
 * Run a second instance with --no-drag to get a pure drop target (orange
 * window) for cross-client validation: drag from the blue window onto it.
 *
 * MIT. Standard libwayland-client boilerplate.
 */
#include <wayland-client.h>
#include "xdg-shell-client-protocol.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>

#define DND_MIME    "text/plain;charset=utf-8"
#define DND_PAYLOAD "hello from iosc dnd"

static struct wl_compositor         *compositor;
static struct wl_shm                *shm;
static struct xdg_wm_base           *wm_base;
static struct wl_seat               *seat;
static struct wl_data_device_manager *ddm;

static struct wl_surface     *surface;
static struct wl_data_device *data_device;
static struct wl_data_source *drag_source;
static struct wl_data_offer  *dnd_offer;      /* offer of the drag currently over us */

static int no_drag = 0;         /* --no-drag: act as a pure drop target */
static int want_w = 500, want_h = 400;
static uint32_t press_serial;   /* last wl_pointer.button PRESSED serial */
static int drag_started = 0;
static int read_fd = -1;        /* pipe read end armed by drop */
static int payload_written = 0; /* our source's send handler ran (self-drag) */
static int done_after_read = 0;

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

static struct wl_buffer *make_fill(int w, int h, uint32_t argb, uint32_t fmt)
{
    int stride = w * 4;
    size_t size = (size_t)stride * h;
    int fd = create_shm_file(size);
    if (fd < 0) return NULL;
    uint32_t *px = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (px == MAP_FAILED) { perror("mmap"); close(fd); return NULL; }
    for (size_t i = 0; i < (size_t)w * h; i++) px[i] = argb;
    struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, (int32_t)size);
    struct wl_buffer *buf = wl_shm_pool_create_buffer(pool, 0, w, h, stride, fmt);
    wl_shm_pool_destroy(pool);
    munmap(px, size);
    close(fd);
    return buf;
}

/* ---- wl_data_source (the drag payload we offer) --------------------------- */

static void src_target(void *d, struct wl_data_source *s, const char *mime)
{ (void)d; (void)s; fprintf(stderr, "dnd-test: source TARGET mime=%s\n", mime ? mime : "(nil)"); }

static void src_send(void *d, struct wl_data_source *s, const char *mime, int fd)
{ (void)d; (void)s;
    fprintf(stderr, "dnd-test: source SEND mime=%s -> writing payload\n", mime);
    ssize_t n = write(fd, DND_PAYLOAD, strlen(DND_PAYLOAD));
    if (n < 0) perror("dnd-test: write payload");
    close(fd);
    payload_written = 1;
}

static void src_cancelled(void *d, struct wl_data_source *s)
{ (void)d;
    fprintf(stderr, "dnd-test: source CANCELLED\n");
    wl_data_source_destroy(s);
    if (s == drag_source) drag_source = NULL;
    drag_started = 0;
}

static void src_drop_performed(void *d, struct wl_data_source *s)
{ (void)d; (void)s; fprintf(stderr, "dnd-test: source DND_DROP_PERFORMED\n"); }

static void src_finished(void *d, struct wl_data_source *s)
{ (void)d;
    fprintf(stderr, "dnd-test: source DND_FINISHED (transfer complete)\n");
    wl_data_source_destroy(s);
    if (s == drag_source) drag_source = NULL;
    drag_started = 0;
}

static void src_action(void *d, struct wl_data_source *s, uint32_t a)
{ (void)d; (void)s; fprintf(stderr, "dnd-test: source ACTION=%u\n", a); }

static const struct wl_data_source_listener src_listener = {
    .target = src_target,
    .send = src_send,
    .cancelled = src_cancelled,
    .dnd_drop_performed = src_drop_performed,
    .dnd_finished = src_finished,
    .action = src_action,
};

/* ---- wl_data_offer (the destination side) --------------------------------- */

static void offer_offer(void *d, struct wl_data_offer *o, const char *mime)
{ (void)d; (void)o; fprintf(stderr, "dnd-test: offer OFFER mime=%s\n", mime); }

static void offer_source_actions(void *d, struct wl_data_offer *o, uint32_t a)
{ (void)d; (void)o; fprintf(stderr, "dnd-test: offer SOURCE_ACTIONS=%u\n", a); }

static void offer_action(void *d, struct wl_data_offer *o, uint32_t a)
{ (void)d; (void)o; fprintf(stderr, "dnd-test: offer ACTION=%u\n", a); }

static const struct wl_data_offer_listener offer_listener = {
    .offer = offer_offer,
    .source_actions = offer_source_actions,
    .action = offer_action,
};

/* ---- wl_data_device (enter/leave/motion/drop) ----------------------------- */

static void dev_data_offer(void *d, struct wl_data_device *dev, struct wl_data_offer *o)
{ (void)d; (void)dev;
    fprintf(stderr, "dnd-test: device DATA_OFFER %p\n", (void *)o);
    wl_data_offer_add_listener(o, &offer_listener, NULL);
}

static void dev_enter(void *d, struct wl_data_device *dev, uint32_t serial,
                      struct wl_surface *surf, wl_fixed_t x, wl_fixed_t y,
                      struct wl_data_offer *o)
{ (void)d; (void)dev; (void)surf;
    fprintf(stderr, "dnd-test: device ENTER at %.0f,%.0f offer=%p\n",
            wl_fixed_to_double(x), wl_fixed_to_double(y), (void *)o);
    dnd_offer = o;
    if (o) {
        wl_data_offer_accept(o, serial, DND_MIME);
        wl_data_offer_set_actions(o,
            WL_DATA_DEVICE_MANAGER_DND_ACTION_COPY | WL_DATA_DEVICE_MANAGER_DND_ACTION_MOVE,
            WL_DATA_DEVICE_MANAGER_DND_ACTION_COPY);
    }
}

static void dev_leave(void *d, struct wl_data_device *dev)
{ (void)d; (void)dev;
    fprintf(stderr, "dnd-test: device LEAVE\n");
    if (dnd_offer) { wl_data_offer_destroy(dnd_offer); dnd_offer = NULL; }
}

static void dev_motion(void *d, struct wl_data_device *dev, uint32_t t,
                       wl_fixed_t x, wl_fixed_t y)
{ (void)d; (void)dev; (void)t;
    fprintf(stderr, "dnd-test: device MOTION %.0f,%.0f\n",
            wl_fixed_to_double(x), wl_fixed_to_double(y));
}

static void dev_drop(void *d, struct wl_data_device *dev)
{ (void)d; (void)dev;
    fprintf(stderr, "dnd-test: device DROP\n");
    if (!dnd_offer) { fprintf(stderr, "dnd-test: FAIL drop without offer\n"); return; }
    int fds[2];
    if (pipe(fds) != 0) { perror("pipe"); return; }
    wl_data_offer_receive(dnd_offer, DND_MIME, fds[1]);
    close(fds[1]);
    read_fd = fds[0];   /* read in the main loop once the source has written */
}

static void dev_selection(void *d, struct wl_data_device *dev, struct wl_data_offer *o)
{ (void)d; (void)dev;
    /* clipboard offer, not part of this test */
    if (o) wl_data_offer_destroy(o);
}

static const struct wl_data_device_listener dev_listener = {
    .data_offer = dev_data_offer,
    .enter = dev_enter,
    .leave = dev_leave,
    .motion = dev_motion,
    .drop = dev_drop,
    .selection = dev_selection,
};

/* ---- wl_pointer (capture the press serial + start the drag) ---------------- */

static void ptr_enter(void *d, struct wl_pointer *p, uint32_t serial,
                      struct wl_surface *s, wl_fixed_t x, wl_fixed_t y)
{ (void)d; (void)p; (void)serial; (void)s; (void)x; (void)y; }
static void ptr_leave(void *d, struct wl_pointer *p, uint32_t serial, struct wl_surface *s)
{ (void)d; (void)p; (void)serial; (void)s;
    fprintf(stderr, "dnd-test: pointer leave (drag grab?)\n"); }
static void ptr_motion(void *d, struct wl_pointer *p, uint32_t t, wl_fixed_t x, wl_fixed_t y)
{ (void)d; (void)p; (void)t; (void)x; (void)y; }

static void start_drag(void)
{
    drag_source = wl_data_device_manager_create_data_source(ddm);
    wl_data_source_add_listener(drag_source, &src_listener, NULL);
    wl_data_source_offer(drag_source, DND_MIME);
    wl_data_source_offer(drag_source, "text/plain");
    wl_data_source_set_actions(drag_source,
        WL_DATA_DEVICE_MANAGER_DND_ACTION_COPY | WL_DATA_DEVICE_MANAGER_DND_ACTION_MOVE);

    /* icon: role is assigned by start_drag, buffer committed after */
    struct wl_surface *icon = wl_compositor_create_surface(compositor);
    wl_data_device_start_drag(data_device, drag_source, surface, icon, press_serial);
    struct wl_buffer *ibuf = make_fill(48, 48, 0xffff00ffu, WL_SHM_FORMAT_ARGB8888);
    if (ibuf) {
        wl_surface_attach(icon, ibuf, 0, 0);
        wl_surface_damage(icon, 0, 0, 48, 48);
        wl_surface_commit(icon);
    }
    drag_started = 1;
    fprintf(stderr, "dnd-test: start_drag sent (serial %u)\n", press_serial);
}

static void ptr_button(void *d, struct wl_pointer *p, uint32_t serial, uint32_t t,
                       uint32_t button, uint32_t state)
{ (void)d; (void)p; (void)t; (void)button;
    if (state == WL_POINTER_BUTTON_STATE_PRESSED) {
        press_serial = serial;
        fprintf(stderr, "dnd-test: button press serial=%u\n", serial);
        if (!no_drag && !drag_started) start_drag();
    }
}
static void ptr_axis(void *d, struct wl_pointer *p, uint32_t t, uint32_t a, wl_fixed_t v)
{ (void)d; (void)p; (void)t; (void)a; (void)v; }
static void ptr_frame(void *d, struct wl_pointer *p){ (void)d; (void)p; }
static void ptr_axis_source(void *d, struct wl_pointer *p, uint32_t s){ (void)d; (void)p; (void)s; }
static void ptr_axis_stop(void *d, struct wl_pointer *p, uint32_t t, uint32_t a)
{ (void)d; (void)p; (void)t; (void)a; }
static void ptr_axis_discrete(void *d, struct wl_pointer *p, uint32_t a, int32_t v)
{ (void)d; (void)p; (void)a; (void)v; }

static const struct wl_pointer_listener ptr_listener = {
    .enter = ptr_enter, .leave = ptr_leave, .motion = ptr_motion,
    .button = ptr_button, .axis = ptr_axis, .frame = ptr_frame,
    .axis_source = ptr_axis_source, .axis_stop = ptr_axis_stop,
    .axis_discrete = ptr_axis_discrete,
};

/* ---- registry / xdg boilerplate ------------------------------------------- */

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
    else if (!strcmp(iface, "wl_data_device_manager"))
        ddm = wl_registry_bind(reg, name, &wl_data_device_manager_interface, 3);
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

static void draw(void)
{
    /* blue = drag source window; orange = --no-drag target window */
    uint32_t c = no_drag ? 0x00e07820u : 0x00203a8fu;
    struct wl_buffer *buf = make_fill(want_w, want_h, c, WL_SHM_FORMAT_XRGB8888);
    if (!buf) return;
    wl_surface_attach(surface, buf, 0, 0);
    wl_surface_damage(surface, 0, 0, want_w, want_h);
    wl_surface_commit(surface);
}

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

/* Once the drop landed AND our source wrote the payload (same process for a
 * self-drag), drain the pipe and finish the offer. */
static void try_finish_transfer(void)
{
    if (read_fd < 0) return;
    if (!no_drag && !payload_written) return;   /* self-drag: wait for src_send */
    char buf[4096];
    size_t have = 0;
    for (;;) {
        ssize_t n = read(read_fd, buf + have, sizeof(buf) - 1 - have);
        if (n > 0) { have += (size_t)n; continue; }
        if (n < 0 && (errno == EINTR)) continue;
        break;   /* EOF (writer closed) or error */
    }
    buf[have] = 0;
    close(read_fd);
    read_fd = -1;
    fprintf(stderr, "dnd-test: RECEIVED %zu bytes: \"%s\"\n", have, buf);
    fprintf(stderr, "dnd-test: %s\n",
            !strcmp(buf, DND_PAYLOAD) ? "PASS (payload matches)"
                                      : no_drag ? "cross-client payload (see above)"
                                                : "FAIL (payload mismatch)");
    if (dnd_offer) {
        wl_data_offer_finish(dnd_offer);
        wl_data_offer_destroy(dnd_offer);
        dnd_offer = NULL;
    }
    done_after_read = 1;
}

int main(int argc, char **argv)
{
    if (argc > 1 && !strcmp(argv[1], "--no-drag")) no_drag = 1;

    struct wl_display *dpy = wl_display_connect(NULL);
    if (!dpy) { fprintf(stderr, "dnd-test: wl_display_connect failed "
                                "(WAYLAND_DISPLAY + XDG_RUNTIME_DIR?)\n"); return 1; }
    struct wl_registry *reg = wl_display_get_registry(dpy);
    wl_registry_add_listener(reg, &registry_listener, NULL);
    wl_display_roundtrip(dpy);

    if (!compositor || !shm || !wm_base || !seat || !ddm) {
        fprintf(stderr, "dnd-test: missing globals (compositor=%p shm=%p wm_base=%p "
                        "seat=%p ddm=%p)\n", (void *)compositor, (void *)shm,
                (void *)wm_base, (void *)seat, (void *)ddm);
        return 1;
    }

    data_device = wl_data_device_manager_get_data_device(ddm, seat);
    wl_data_device_add_listener(data_device, &dev_listener, NULL);
    struct wl_pointer *ptr = wl_seat_get_pointer(seat);
    wl_pointer_add_listener(ptr, &ptr_listener, NULL);

    surface = wl_compositor_create_surface(compositor);
    struct xdg_surface *xsurface = xdg_wm_base_get_xdg_surface(wm_base, surface);
    xdg_surface_add_listener(xsurface, &xsurf_listener, NULL);
    struct xdg_toplevel *top = xdg_surface_get_toplevel(xsurface);
    xdg_toplevel_add_listener(top, &top_listener, NULL);
    xdg_toplevel_set_title(top, no_drag ? "dnd target" : "dnd source");
    xdg_toplevel_set_app_id(top, "com.max.iosc.dndtest");
    wl_surface_commit(surface);

    fprintf(stderr, "dnd-test: mapped (%s). Press, drag, release %s the window.\n",
            no_drag ? "target mode" : "source mode",
            no_drag ? "onto" : "inside");
    while (wl_display_dispatch(dpy) != -1) {
        try_finish_transfer();
        if (done_after_read) {
            wl_display_roundtrip(dpy);   /* deliver finish before exiting */
            fprintf(stderr, "dnd-test: done\n");
            break;
        }
    }
    wl_display_disconnect(dpy);
    return 0;
}

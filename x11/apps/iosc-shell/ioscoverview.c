/*
 * ioscoverview — an Activities-style app overview for the iosc desktop shell.
 *
 * A full-screen zwlr_layer_shell_v1 client on the OVERLAY layer: a grid of
 * installed apps (scanned from .desktop) plus a row of currently-open windows
 * (from zwlr_foreign_toplevel_management_v1). Tap an app to launch it, tap a
 * window to raise it, tap empty space or press Escape to dismiss. Drawn with the
 * shared wl_shm software renderer (shell-draw.h) — same zero-dep path as the
 * panel; no toolkit.
 *
 * Summoned by the panel's launcher button (fork+exec ioscoverview) or, later, a
 * compositor gesture via iosc_shell_v1 (see x11/docs/iosc-shell.md §3, §5.4).
 * Each invocation is a fresh process that exits on dismiss; a resident toggle
 * would need the iosc_shell_v1 control protocol.
 *
 * Build: build-panel.sh builds both ioscpanel and ioscoverview. Needs iosc to
 * implement zwlr_layer_shell_v1 before it can map.
 */
#define _GNU_SOURCE
#include "shell-draw.h"
#include "wlr-layer-shell-unstable-v1-client-protocol.h"
#include "wlr-foreign-toplevel-management-unstable-v1-client-protocol.h"

#include <poll.h>
#include <errno.h>
#include <signal.h>

/* ------------------------------------------------------------------ config */
#define OV_BG        0xff141414u   /* opaque dark backdrop (iosc ignores alpha) */
#define OV_FG        0xffe6e6e6u
#define OV_DIM       0xff8a8a8au
#define OV_ACCENT    0xffe3853fu   /* brand amber */
#define OV_TILE      0xff242426u
#define OV_TILE_HOV  0xff34343au
#define OV_MARGIN    48
#define OV_TILE_W    150
#define OV_TILE_H    128
#define OV_GAP       22
#define OV_ICON      72            /* icon square side (logical) */
#define MAX_APPS     128
#define MAX_TASKS    32

struct ov_task {
    struct zwlr_foreign_toplevel_handle_v1 *handle;
    char title[64];
    int  activated;
};
struct ov_hit { int x, y, w, h; int kind; int idx; }; /* kind 1=app 2=task 0=bg */

static struct {
    struct wl_display    *dpy;
    struct wl_compositor *comp;
    struct wl_shm        *shm;
    struct wl_seat       *seat;
    struct wl_pointer    *ptr;
    struct wl_keyboard   *kbd;
    struct zwlr_layer_shell_v1 *layer_shell;
    struct zwlr_foreign_toplevel_manager_v1 *ftm;
    struct wl_surface    *surf;
    struct zwlr_layer_surface_v1 *layer;

    int   width, height, scale, configured, running;
    int   px, py, have_ptr;

    struct sd_app  apps[MAX_APPS];
    int   napps;
    struct ov_task tasks[MAX_TASKS];
    int   ntasks;

    struct ov_hit hits[MAX_APPS + MAX_TASKS + 1];
    int   nhits;
} O;

/* --------------------------------------------------------------- render -- */

static void buf_release(void *d, struct wl_buffer *b){ (void)d; wl_buffer_destroy(b); }
static const struct wl_buffer_listener buf_listener = { .release = buf_release };

/* draw one tile (icon square + initial + label); records a hit rect. */
static void draw_tile(struct shell_canvas *cv, int x, int y, const char *label,
                      uint32_t accent, int hovered, int kind, int idx)
{
    sd_fill_rect(cv, x, y, OV_TILE_W, OV_TILE_H, hovered ? OV_TILE_HOV : OV_TILE);
    int ix = x + (OV_TILE_W - OV_ICON) / 2, iy = y + 14;
    sd_fill_rect(cv, ix, iy, OV_ICON, OV_ICON, accent);
    char init[2] = { label[0] ? label[0] : '?', 0 };
    sd_draw_text_centered(cv, init, ix, OV_ICON, iy + (OV_ICON - 7) / 2, OV_BG);
    char lbl[40];
    sd_fit_label(lbl, sizeof lbl, label, (OV_TILE_W - 8) / 6);
    sd_draw_text_centered(cv, lbl, x, OV_TILE_W, y + OV_TILE_H - 18, OV_FG);
    O.hits[O.nhits++] = (struct ov_hit){ x, y, OV_TILE_W, OV_TILE_H, kind, idx };
}

static void render(void)
{
    if (!O.configured) return;
    struct shell_canvas cv;
    struct wl_buffer *buf = sd_canvas_alloc(O.shm, O.width, O.height, O.scale, &cv);
    if (!buf) { fprintf(stderr, "ioscoverview: canvas alloc failed\n"); return; }
    O.nhits = 0;

    sd_fill_rect(&cv, 0, 0, O.width, O.height, OV_BG);
    /* whole background is a dismiss target (drawn first; tiles override it) */
    O.hits[O.nhits++] = (struct ov_hit){ 0, 0, O.width, O.height, 0, 0 };

    int cols = (O.width - 2*OV_MARGIN + OV_GAP) / (OV_TILE_W + OV_GAP);
    if (cols < 1) cols = 1;
    int grid_w = cols * OV_TILE_W + (cols - 1) * OV_GAP;
    int x0 = (O.width - grid_w) / 2;
    int y = OV_MARGIN;

    /* --- running windows row ---------------------------------------- */
    if (O.ntasks > 0) {
        sd_draw_text(&cv, "OPEN WINDOWS", x0, y, OV_DIM); y += 16;
        for (int i = 0; i < O.ntasks; i++) {
            int col = i % cols;
            int tx = x0 + col * (OV_TILE_W + OV_GAP);
            int ty = y + (i / cols) * (OV_TILE_H + OV_GAP);
            int hov = (O.have_ptr && O.px >= tx && O.px < tx+OV_TILE_W &&
                       O.py >= ty && O.py < ty+OV_TILE_H);
            const char *t = O.tasks[i].title[0] ? O.tasks[i].title : "WINDOW";
            draw_tile(&cv, tx, ty, t, O.tasks[i].activated ? OV_ACCENT : 0xff3a6ea5u,
                      hov, 2, i);
        }
        int rows = (O.ntasks + cols - 1) / cols;
        y += rows * (OV_TILE_H + OV_GAP) + OV_GAP;
    }

    /* --- installed apps grid ---------------------------------------- */
    sd_draw_text(&cv, "APPLICATIONS", x0, y, OV_DIM); y += 16;
    for (int i = 0; i < O.napps; i++) {
        int col = i % cols;
        int tx = x0 + col * (OV_TILE_W + OV_GAP);
        int ty = y + (i / cols) * (OV_TILE_H + OV_GAP);
        if (ty + OV_TILE_H > O.height - OV_MARGIN) break; /* clip overflow (no scroll yet) */
        int hov = (O.have_ptr && O.px >= tx && O.px < tx+OV_TILE_W &&
                   O.py >= ty && O.py < ty+OV_TILE_H);
        draw_tile(&cv, tx, ty, O.apps[i].name, OV_ACCENT, hov, 1, i);
    }

    wl_buffer_add_listener(buf, &buf_listener, NULL);
    wl_surface_attach(O.surf, buf, 0, 0);
    wl_surface_damage_buffer(O.surf, 0, 0, cv.bw, cv.bh);
    wl_surface_commit(O.surf);
}

/* ----------------------------------------------------- foreign-toplevel -- */

static struct ov_task *task_for(struct zwlr_foreign_toplevel_handle_v1 *h)
{
    for (int i = 0; i < O.ntasks; i++) if (O.tasks[i].handle == h) return &O.tasks[i];
    return NULL;
}
static void ft_title(void *d, struct zwlr_foreign_toplevel_handle_v1 *h, const char *t)
{ (void)d; struct ov_task *ti = task_for(h); if (ti) snprintf(ti->title, sizeof ti->title, "%s", t?t:""); }
static void ft_app_id(void *d, struct zwlr_foreign_toplevel_handle_v1 *h, const char *a){ (void)d;(void)h;(void)a; }
static void ft_out_enter(void *d, struct zwlr_foreign_toplevel_handle_v1 *h, struct wl_output *o){ (void)d;(void)h;(void)o; }
static void ft_out_leave(void *d, struct zwlr_foreign_toplevel_handle_v1 *h, struct wl_output *o){ (void)d;(void)h;(void)o; }
static void ft_state(void *d, struct zwlr_foreign_toplevel_handle_v1 *h, struct wl_array *st)
{
    (void)d; struct ov_task *ti = task_for(h); if (!ti) return;
    ti->activated = 0; uint32_t *s;
    wl_array_for_each(s, st) if (*s == ZWLR_FOREIGN_TOPLEVEL_HANDLE_V1_STATE_ACTIVATED) ti->activated = 1;
}
static void ft_done(void *d, struct zwlr_foreign_toplevel_handle_v1 *h){ (void)d;(void)h; render(); }
static void ft_closed(void *d, struct zwlr_foreign_toplevel_handle_v1 *h)
{
    (void)d;
    for (int i = 0; i < O.ntasks; i++) if (O.tasks[i].handle == h) {
        zwlr_foreign_toplevel_handle_v1_destroy(h);
        for (int j = i; j < O.ntasks-1; j++) O.tasks[j] = O.tasks[j+1];
        O.ntasks--; break;
    }
    render();
}
static void ft_parent(void *d, struct zwlr_foreign_toplevel_handle_v1 *h, struct zwlr_foreign_toplevel_handle_v1 *p){ (void)d;(void)h;(void)p; }
static const struct zwlr_foreign_toplevel_handle_v1_listener ft_handle_listener = {
    .title = ft_title, .app_id = ft_app_id, .output_enter = ft_out_enter,
    .output_leave = ft_out_leave, .state = ft_state, .done = ft_done,
    .closed = ft_closed, .parent = ft_parent,
};
static void ftm_toplevel(void *d, struct zwlr_foreign_toplevel_manager_v1 *m,
                         struct zwlr_foreign_toplevel_handle_v1 *h)
{
    (void)d;(void)m;
    if (O.ntasks >= MAX_TASKS) { zwlr_foreign_toplevel_handle_v1_destroy(h); return; }
    struct ov_task *ti = &O.tasks[O.ntasks++];
    memset(ti, 0, sizeof *ti); ti->handle = h;
    zwlr_foreign_toplevel_handle_v1_add_listener(h, &ft_handle_listener, NULL);
}
static void ftm_finished(void *d, struct zwlr_foreign_toplevel_manager_v1 *m)
{ (void)d; zwlr_foreign_toplevel_manager_v1_destroy(m); O.ftm = NULL; }
static const struct zwlr_foreign_toplevel_manager_v1_listener ftm_listener = {
    .toplevel = ftm_toplevel, .finished = ftm_finished,
};

/* --------------------------------------------------------- input handlers */

static void activate_hit(int i)
{
    struct ov_hit *r = &O.hits[i];
    if (r->kind == 1 && r->idx < O.napps) { sd_launch(O.apps[r->idx].exec); O.running = 0; }
    else if (r->kind == 2 && r->idx < O.ntasks && O.tasks[r->idx].handle) {
        zwlr_foreign_toplevel_handle_v1_activate(O.tasks[r->idx].handle, O.seat);
        O.running = 0;
    } else if (r->kind == 0) O.running = 0;   /* background tap dismisses */
}

static void pt_enter(void *d, struct wl_pointer *p, uint32_t s, struct wl_surface *sf, wl_fixed_t x, wl_fixed_t y)
{ (void)d;(void)p;(void)s;(void)sf; O.have_ptr=1; O.px=wl_fixed_to_int(x); O.py=wl_fixed_to_int(y); render(); }
static void pt_leave(void *d, struct wl_pointer *p, uint32_t s, struct wl_surface *sf)
{ (void)d;(void)p;(void)s;(void)sf; O.have_ptr=0; }
static void pt_motion(void *d, struct wl_pointer *p, uint32_t t, wl_fixed_t x, wl_fixed_t y)
{ (void)d;(void)p;(void)t; O.px=wl_fixed_to_int(x); O.py=wl_fixed_to_int(y); render(); }
static void pt_button(void *d, struct wl_pointer *p, uint32_t serial, uint32_t t, uint32_t button, uint32_t state)
{
    (void)d;(void)p;(void)serial;(void)t;
    if (state != WL_POINTER_BUTTON_STATE_PRESSED || button != 0x110) return;
    /* hit-test top-most first (tiles were appended after the bg rect) */
    for (int i = O.nhits - 1; i >= 0; i--) {
        struct ov_hit *r = &O.hits[i];
        if (O.px >= r->x && O.px < r->x+r->w && O.py >= r->y && O.py < r->y+r->h) {
            activate_hit(i); return;
        }
    }
}
static void pt_axis(void *d, struct wl_pointer *p, uint32_t t, uint32_t a, wl_fixed_t v){ (void)d;(void)p;(void)t;(void)a;(void)v; }
static void pt_frame(void *d, struct wl_pointer *p){ (void)d;(void)p; }
static void pt_axis_src(void *d, struct wl_pointer *p, uint32_t s){ (void)d;(void)p;(void)s; }
static void pt_axis_stop(void *d, struct wl_pointer *p, uint32_t t, uint32_t a){ (void)d;(void)p;(void)t;(void)a; }
static void pt_axis_disc(void *d, struct wl_pointer *p, uint32_t a, int32_t v){ (void)d;(void)p;(void)a;(void)v; }
#ifdef WL_POINTER_AXIS_VALUE120_SINCE_VERSION
static void pt_axis_v120(void *d, struct wl_pointer *p, uint32_t a, int32_t v){ (void)d;(void)p;(void)a;(void)v; }
#endif
#ifdef WL_POINTER_AXIS_RELATIVE_DIRECTION_SINCE_VERSION
static void pt_axis_dir(void *d, struct wl_pointer *p, uint32_t a, uint32_t dir){ (void)d;(void)p;(void)a;(void)dir; }
#endif
static const struct wl_pointer_listener pointer_listener = {
    .enter = pt_enter, .leave = pt_leave, .motion = pt_motion, .button = pt_button,
    .axis = pt_axis, .frame = pt_frame, .axis_source = pt_axis_src,
    .axis_stop = pt_axis_stop, .axis_discrete = pt_axis_disc,
#ifdef WL_POINTER_AXIS_VALUE120_SINCE_VERSION
    .axis_value120 = pt_axis_v120,
#endif
#ifdef WL_POINTER_AXIS_RELATIVE_DIRECTION_SINCE_VERSION
    .axis_relative_direction = pt_axis_dir,
#endif
};

/* keyboard: only Escape (evdev keycode 1) to dismiss. */
static void kb_keymap(void *d, struct wl_keyboard *k, uint32_t fmt, int32_t fd, uint32_t sz)
{ (void)d;(void)k;(void)fmt;(void)sz; if (fd >= 0) close(fd); }
static void kb_enter(void *d, struct wl_keyboard *k, uint32_t s, struct wl_surface *sf, struct wl_array *keys)
{ (void)d;(void)k;(void)s;(void)sf;(void)keys; }
static void kb_leave(void *d, struct wl_keyboard *k, uint32_t s, struct wl_surface *sf){ (void)d;(void)k;(void)s;(void)sf; }
static void kb_key(void *d, struct wl_keyboard *k, uint32_t serial, uint32_t t, uint32_t key, uint32_t state)
{ (void)d;(void)k;(void)serial;(void)t;
  if (state == WL_KEYBOARD_KEY_STATE_PRESSED && key == 1 /*KEY_ESC*/) O.running = 0; }
static void kb_mods(void *d, struct wl_keyboard *k, uint32_t s, uint32_t dep, uint32_t lat, uint32_t lock, uint32_t grp)
{ (void)d;(void)k;(void)s;(void)dep;(void)lat;(void)lock;(void)grp; }
static void kb_repeat(void *d, struct wl_keyboard *k, int32_t rate, int32_t delay){ (void)d;(void)k;(void)rate;(void)delay; }
static const struct wl_keyboard_listener keyboard_listener = {
    .keymap = kb_keymap, .enter = kb_enter, .leave = kb_leave, .key = kb_key,
    .modifiers = kb_mods, .repeat_info = kb_repeat,
};

static void seat_caps(void *d, struct wl_seat *s, uint32_t caps)
{
    (void)d;
    if ((caps & WL_SEAT_CAPABILITY_POINTER) && !O.ptr) {
        O.ptr = wl_seat_get_pointer(s); wl_pointer_add_listener(O.ptr, &pointer_listener, NULL);
    }
    if ((caps & WL_SEAT_CAPABILITY_KEYBOARD) && !O.kbd) {
        O.kbd = wl_seat_get_keyboard(s); wl_keyboard_add_listener(O.kbd, &keyboard_listener, NULL);
    }
}
static void seat_name(void *d, struct wl_seat *s, const char *n){ (void)d;(void)s;(void)n; }
static const struct wl_seat_listener seat_listener = { .capabilities = seat_caps, .name = seat_name };

/* ------------------------------------------------------- layer surface --- */

static void layer_configure(void *d, struct zwlr_layer_surface_v1 *ls, uint32_t serial, uint32_t w, uint32_t h)
{
    (void)d;
    if (w) O.width = (int)w;
    if (h) O.height = (int)h;
    zwlr_layer_surface_v1_ack_configure(ls, serial);
    O.configured = 1;
    render();
}
static void layer_closed(void *d, struct zwlr_layer_surface_v1 *ls){ (void)d;(void)ls; O.running = 0; }
static const struct zwlr_layer_surface_v1_listener layer_listener = {
    .configure = layer_configure, .closed = layer_closed,
};

/* --------------------------------------------------------------- registry */

static void reg_global(void *d, struct wl_registry *r, uint32_t name, const char *iface, uint32_t ver)
{
    (void)d;
    if (!strcmp(iface, wl_compositor_interface.name))
        O.comp = wl_registry_bind(r, name, &wl_compositor_interface, ver < 4 ? ver : 4);
    else if (!strcmp(iface, wl_shm_interface.name))
        O.shm = wl_registry_bind(r, name, &wl_shm_interface, 1);
    else if (!strcmp(iface, wl_seat_interface.name)) {
        O.seat = wl_registry_bind(r, name, &wl_seat_interface, ver < 5 ? ver : 5);
        wl_seat_add_listener(O.seat, &seat_listener, NULL);
    } else if (!strcmp(iface, zwlr_layer_shell_v1_interface.name))
        O.layer_shell = wl_registry_bind(r, name, &zwlr_layer_shell_v1_interface, ver < 4 ? ver : 4);
    else if (!strcmp(iface, zwlr_foreign_toplevel_manager_v1_interface.name)) {
        O.ftm = wl_registry_bind(r, name, &zwlr_foreign_toplevel_manager_v1_interface, ver < 3 ? ver : 3);
        zwlr_foreign_toplevel_manager_v1_add_listener(O.ftm, &ftm_listener, NULL);
    }
}
static void reg_remove(void *d, struct wl_registry *r, uint32_t name){ (void)d;(void)r;(void)name; }
static const struct wl_registry_listener registry_listener = { .global = reg_global, .global_remove = reg_remove };

/* ------------------------------------------------------------------ main */

int main(void)
{
    signal(SIGCHLD, SIG_IGN);
    memset(&O, 0, sizeof O);
    O.width = 1080; O.height = 810; O.scale = 2; O.running = 1;
    const char *es = getenv("IOSC_PANEL_SCALE");
    if (es && atoi(es) > 0) O.scale = atoi(es);

    O.dpy = wl_display_connect(NULL);
    if (!O.dpy) { fprintf(stderr, "ioscoverview: cannot connect to WAYLAND_DISPLAY\n"); return 1; }
    struct wl_registry *reg = wl_display_get_registry(O.dpy);
    wl_registry_add_listener(reg, &registry_listener, NULL);
    wl_display_roundtrip(O.dpy);
    wl_display_roundtrip(O.dpy);

    if (!O.comp || !O.shm) { fprintf(stderr, "ioscoverview: missing wl_compositor/wl_shm\n"); return 1; }
    if (!O.layer_shell) {
        fprintf(stderr, "ioscoverview: compositor lacks zwlr_layer_shell_v1 — cannot map "
                        "(iosc must implement it; see iosc-shell.md)\n");
        return 2;
    }

    O.napps = sd_scan_apps(O.apps, MAX_APPS);
    fprintf(stderr, "ioscoverview: %d app(s), foreign-toplevel=%s\n",
            O.napps, O.ftm ? "yes" : "no");

    O.surf  = wl_compositor_create_surface(O.comp);
    O.layer = zwlr_layer_shell_v1_get_layer_surface(O.layer_shell, O.surf, NULL,
                ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY, "overview");
    zwlr_layer_surface_v1_add_listener(O.layer, &layer_listener, NULL);
    zwlr_layer_surface_v1_set_anchor(O.layer,
        ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP | ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM |
        ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT | ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT);
    zwlr_layer_surface_v1_set_size(O.layer, 0, 0);          /* span the whole output */
    zwlr_layer_surface_v1_set_exclusive_zone(O.layer, -1);  /* cover everything */
    zwlr_layer_surface_v1_set_keyboard_interactivity(O.layer, 1); /* take focus (Escape) */
    wl_surface_commit(O.surf);

    int fd = wl_display_get_fd(O.dpy);
    while (O.running) {
        while (wl_display_prepare_read(O.dpy) != 0) wl_display_dispatch_pending(O.dpy);
        wl_display_flush(O.dpy);
        struct pollfd pfd = { .fd = fd, .events = POLLIN };
        int n = poll(&pfd, 1, -1);
        if (n < 0 && errno != EINTR) { wl_display_cancel_read(O.dpy); break; }
        if (n > 0 && (pfd.revents & POLLIN)) wl_display_read_events(O.dpy);
        else wl_display_cancel_read(O.dpy);
        wl_display_dispatch_pending(O.dpy);
    }
    wl_display_disconnect(O.dpy);
    return 0;
}

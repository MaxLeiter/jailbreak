/*
 * ioscpanel — a minimal desktop panel for the iosc Wayland compositor.
 *
 * A self-contained zwlr_layer_shell_v1 client. It anchors a bar to the top edge
 * of the iosc output, reserves an exclusive zone (so maximized toplevels don't
 * draw under it), and renders three regions with the shared wl_shm software
 * renderer (shell-draw.h) — no cairo/pango/GTK dependency:
 *
 *   [ launcher apps ............ | taskbar (open windows) ........ | HH:MM ]
 *
 * - launcher: up to LAUNCH_MAX quick-launch buttons scanned from
 *   /var/jb/usr/share/applications (the .desktop set); a tap fork+execs the app.
 * - taskbar: one button per open toplevel, driven by
 *   zwlr_foreign_toplevel_management_v1. A tap activates (raises) that window.
 *   Empty until iosc advertises the foreign-toplevel global (degrades cleanly).
 * - clock: HH:MM, repainted each minute off a poll() timeout in the wl loop.
 *
 * Build: build-panel.sh (Docker cross-compile). Needs iosc to implement
 * zwlr_layer_shell_v1 before it can map (see x11/docs/iosc-shell.md §5.1).
 */
#define _GNU_SOURCE
#include "shell-draw.h"
#include "wlr-layer-shell-unstable-v1-client-protocol.h"
#include "wlr-foreign-toplevel-management-unstable-v1-client-protocol.h"

#include <time.h>
#include <poll.h>
#include <errno.h>
#include <signal.h>

/* ------------------------------------------------------------------ config */
#define PANEL_H        44
#define PANEL_BG       0xff1c1c1eu
#define PANEL_FG       0xffe6e6e6u
#define PANEL_ACCENT   0xffe3853fu
#define BTN_HOVER      0xff2e2e30u
#define BTN_ACTIVE     0xff3a3a3cu
#define LAUNCH_MAX     8
#define TASK_MAX       16
#define BTN_W          120
#define LAUNCH_W       40
#define PAD            8

struct task_item {
    struct zwlr_foreign_toplevel_handle_v1 *handle;
    char  title[64];
    int   activated;
};
struct hitrect { int x, w; int kind; int idx; };  /* kind: 1=launch 2=task */

static struct {
    struct wl_display    *dpy;
    struct wl_compositor *comp;
    struct wl_shm        *shm;
    struct wl_seat       *seat;
    struct wl_pointer    *ptr;
    struct zwlr_layer_shell_v1 *layer_shell;
    struct zwlr_foreign_toplevel_manager_v1 *ftm;
    struct wl_surface    *surf;
    struct zwlr_layer_surface_v1 *layer;

    int   width, height, scale, configured, running;
    int   px, py, have_ptr;

    struct sd_app    launch[LAUNCH_MAX];
    int   nlaunch;
    struct task_item tasks[TASK_MAX];
    int   ntasks;

    struct hitrect hits[LAUNCH_MAX + TASK_MAX];
    int   nhits;
} P;

static void clock_string(char *out, size_t n)
{
    time_t t = time(NULL); struct tm tm; localtime_r(&t, &tm);
    snprintf(out, n, "%02d:%02d", tm.tm_hour, tm.tm_min);
}

/* ------------------------------------------------------------- rendering -- */

static void buf_release(void *d, struct wl_buffer *b){ (void)d; wl_buffer_destroy(b); }
static const struct wl_buffer_listener buf_listener = { .release = buf_release };

static void render(void)
{
    if (!P.configured) return;
    struct shell_canvas cv;
    struct wl_buffer *buf = sd_canvas_alloc(P.shm, P.width, P.height, P.scale, &cv);
    if (!buf) { fprintf(stderr, "ioscpanel: canvas alloc failed\n"); return; }
    P.nhits = 0;

    sd_fill_rect(&cv, 0, 0, P.width, P.height, PANEL_BG);
    sd_fill_rect(&cv, 0, P.height - 1, P.width, 1, PANEL_ACCENT);   /* hairline */
    int ty = (P.height - 7) / 2;

    /* --- launcher strip (left) --------------------------------------- */
    int x = PAD;
    for (int i = 0; i < P.nlaunch; i++) {
        int bx = x, bw = LAUNCH_W;
        if (P.have_ptr && P.px >= bx && P.px < bx+bw)
            sd_fill_rect(&cv, bx, 3, bw, P.height-6, BTN_HOVER);
        int side = P.height - 16;
        sd_fill_rect(&cv, bx+8, 8, side, side, PANEL_ACCENT);
        char init[2] = { P.launch[i].name[0], 0 };
        sd_draw_text_centered(&cv, init, bx+8, side, ty, PANEL_BG);
        P.hits[P.nhits++] = (struct hitrect){ bx, bw, 1, i };
        x += bw;
    }
    x += PAD;
    sd_fill_rect(&cv, x, 6, 1, P.height-12, BTN_HOVER);   /* separator */
    x += PAD;

    /* --- clock (right) ----------------------------------------------- */
    char clk[8]; clock_string(clk, sizeof clk);
    int clk_x = P.width - PAD - sd_text_w(clk);
    sd_draw_text(&cv, clk, clk_x, ty, PANEL_FG);

    /* --- taskbar (center) -------------------------------------------- */
    int task_left = x, task_right = clk_x - PAD * 2;
    int avail = task_right - task_left;
    int bw = BTN_W;
    if (P.ntasks > 0 && avail / P.ntasks < bw) bw = avail / P.ntasks;
    if (bw < 24) bw = 24;
    for (int i = 0; i < P.ntasks; i++) {
        int bx = task_left + i * (bw + 4);
        if (bx + bw > task_right) break;
        int hover = (P.have_ptr && P.px >= bx && P.px < bx+bw);
        uint32_t bg = P.tasks[i].activated ? BTN_ACTIVE : (hover ? BTN_HOVER : PANEL_BG);
        sd_fill_rect(&cv, bx, 4, bw, P.height-8, bg);
        if (P.tasks[i].activated) sd_fill_rect(&cv, bx, P.height-3, bw, 2, PANEL_ACCENT);
        char lbl[40];
        sd_fit_label(lbl, sizeof lbl, P.tasks[i].title[0] ? P.tasks[i].title : "WINDOW", (bw-12)/6);
        sd_draw_text(&cv, lbl, bx + 6, ty, PANEL_FG);
        P.hits[P.nhits++] = (struct hitrect){ bx, bw, 2, i };
    }

    wl_buffer_add_listener(buf, &buf_listener, NULL);
    wl_surface_attach(P.surf, buf, 0, 0);
    wl_surface_damage_buffer(P.surf, 0, 0, cv.bw, cv.bh);
    wl_surface_commit(P.surf);
}

/* ----------------------------------------------------- foreign-toplevel -- */

static struct task_item *task_for(struct zwlr_foreign_toplevel_handle_v1 *h)
{
    for (int i = 0; i < P.ntasks; i++) if (P.tasks[i].handle == h) return &P.tasks[i];
    return NULL;
}
static void ft_title(void *d, struct zwlr_foreign_toplevel_handle_v1 *h, const char *t)
{ (void)d; struct task_item *ti = task_for(h); if (ti) snprintf(ti->title, sizeof ti->title, "%s", t?t:""); }
static void ft_app_id(void *d, struct zwlr_foreign_toplevel_handle_v1 *h, const char *a){ (void)d;(void)h;(void)a; }
static void ft_out_enter(void *d, struct zwlr_foreign_toplevel_handle_v1 *h, struct wl_output *o){ (void)d;(void)h;(void)o; }
static void ft_out_leave(void *d, struct zwlr_foreign_toplevel_handle_v1 *h, struct wl_output *o){ (void)d;(void)h;(void)o; }
static void ft_state(void *d, struct zwlr_foreign_toplevel_handle_v1 *h, struct wl_array *st)
{
    (void)d; struct task_item *ti = task_for(h); if (!ti) return;
    ti->activated = 0; uint32_t *s;
    wl_array_for_each(s, st) if (*s == ZWLR_FOREIGN_TOPLEVEL_HANDLE_V1_STATE_ACTIVATED) ti->activated = 1;
}
static void ft_done(void *d, struct zwlr_foreign_toplevel_handle_v1 *h){ (void)d;(void)h; render(); }
static void ft_closed(void *d, struct zwlr_foreign_toplevel_handle_v1 *h)
{
    (void)d;
    for (int i = 0; i < P.ntasks; i++) if (P.tasks[i].handle == h) {
        zwlr_foreign_toplevel_handle_v1_destroy(h);
        for (int j = i; j < P.ntasks-1; j++) P.tasks[j] = P.tasks[j+1];
        P.ntasks--; break;
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
    if (P.ntasks >= TASK_MAX) { zwlr_foreign_toplevel_handle_v1_destroy(h); return; }
    struct task_item *ti = &P.tasks[P.ntasks++];
    memset(ti, 0, sizeof *ti); ti->handle = h;
    zwlr_foreign_toplevel_handle_v1_add_listener(h, &ft_handle_listener, NULL);
}
static void ftm_finished(void *d, struct zwlr_foreign_toplevel_manager_v1 *m)
{ (void)d; zwlr_foreign_toplevel_manager_v1_destroy(m); P.ftm = NULL; }
static const struct zwlr_foreign_toplevel_manager_v1_listener ftm_listener = {
    .toplevel = ftm_toplevel, .finished = ftm_finished,
};

/* ------------------------------------------------------------- pointer --- */

static void pt_enter(void *d, struct wl_pointer *p, uint32_t s, struct wl_surface *sf, wl_fixed_t x, wl_fixed_t y)
{ (void)d;(void)p;(void)s;(void)sf; P.have_ptr=1; P.px=wl_fixed_to_int(x); P.py=wl_fixed_to_int(y); render(); }
static void pt_leave(void *d, struct wl_pointer *p, uint32_t s, struct wl_surface *sf)
{ (void)d;(void)p;(void)s;(void)sf; P.have_ptr=0; render(); }
static void pt_motion(void *d, struct wl_pointer *p, uint32_t t, wl_fixed_t x, wl_fixed_t y)
{ (void)d;(void)p;(void)t; P.px=wl_fixed_to_int(x); P.py=wl_fixed_to_int(y); render(); }
static void pt_button(void *d, struct wl_pointer *p, uint32_t serial, uint32_t t, uint32_t button, uint32_t state)
{
    (void)d;(void)p;(void)serial;(void)t;
    if (state != WL_POINTER_BUTTON_STATE_PRESSED || button != 0x110 /*BTN_LEFT*/) return;
    for (int i = 0; i < P.nhits; i++) {
        struct hitrect *r = &P.hits[i];
        if (P.px < r->x || P.px >= r->x + r->w) continue;
        if (r->kind == 1 && r->idx < P.nlaunch) sd_launch(P.launch[r->idx].exec);
        else if (r->kind == 2 && r->idx < P.ntasks && P.tasks[r->idx].handle)
            zwlr_foreign_toplevel_handle_v1_activate(P.tasks[r->idx].handle, P.seat);
        return;
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

static void seat_caps(void *d, struct wl_seat *s, uint32_t caps)
{
    (void)d;
    if ((caps & WL_SEAT_CAPABILITY_POINTER) && !P.ptr) {
        P.ptr = wl_seat_get_pointer(s); wl_pointer_add_listener(P.ptr, &pointer_listener, NULL);
    }
}
static void seat_name(void *d, struct wl_seat *s, const char *n){ (void)d;(void)s;(void)n; }
static const struct wl_seat_listener seat_listener = { .capabilities = seat_caps, .name = seat_name };

/* ------------------------------------------------------- layer surface --- */

static void layer_configure(void *d, struct zwlr_layer_surface_v1 *ls, uint32_t serial, uint32_t w, uint32_t h)
{
    (void)d;
    if (w) P.width = (int)w;
    if (h) P.height = (int)h;
    zwlr_layer_surface_v1_ack_configure(ls, serial);
    P.configured = 1;
    render();
}
static void layer_closed(void *d, struct zwlr_layer_surface_v1 *ls){ (void)d;(void)ls; P.running = 0; }
static const struct zwlr_layer_surface_v1_listener layer_listener = {
    .configure = layer_configure, .closed = layer_closed,
};

/* --------------------------------------------------------------- registry */

static void reg_global(void *d, struct wl_registry *r, uint32_t name, const char *iface, uint32_t ver)
{
    (void)d;
    if (!strcmp(iface, wl_compositor_interface.name))
        P.comp = wl_registry_bind(r, name, &wl_compositor_interface, ver < 4 ? ver : 4);
    else if (!strcmp(iface, wl_shm_interface.name))
        P.shm = wl_registry_bind(r, name, &wl_shm_interface, 1);
    else if (!strcmp(iface, wl_seat_interface.name)) {
        P.seat = wl_registry_bind(r, name, &wl_seat_interface, ver < 5 ? ver : 5);
        wl_seat_add_listener(P.seat, &seat_listener, NULL);
    } else if (!strcmp(iface, zwlr_layer_shell_v1_interface.name))
        P.layer_shell = wl_registry_bind(r, name, &zwlr_layer_shell_v1_interface, ver < 4 ? ver : 4);
    else if (!strcmp(iface, zwlr_foreign_toplevel_manager_v1_interface.name)) {
        P.ftm = wl_registry_bind(r, name, &zwlr_foreign_toplevel_manager_v1_interface, ver < 3 ? ver : 3);
        zwlr_foreign_toplevel_manager_v1_add_listener(P.ftm, &ftm_listener, NULL);
    }
}
static void reg_remove(void *d, struct wl_registry *r, uint32_t name){ (void)d;(void)r;(void)name; }
static const struct wl_registry_listener registry_listener = { .global = reg_global, .global_remove = reg_remove };

/* ------------------------------------------------------------------ main */

int main(void)
{
    signal(SIGCHLD, SIG_IGN);
    memset(&P, 0, sizeof P);
    P.width = 1080; P.height = PANEL_H; P.scale = 2; P.running = 1;
    const char *es = getenv("IOSC_PANEL_SCALE");
    if (es && atoi(es) > 0) P.scale = atoi(es);

    P.dpy = wl_display_connect(NULL);
    if (!P.dpy) { fprintf(stderr, "ioscpanel: cannot connect to WAYLAND_DISPLAY\n"); return 1; }
    struct wl_registry *reg = wl_display_get_registry(P.dpy);
    wl_registry_add_listener(reg, &registry_listener, NULL);
    wl_display_roundtrip(P.dpy);
    wl_display_roundtrip(P.dpy);

    if (!P.comp || !P.shm) { fprintf(stderr, "ioscpanel: missing wl_compositor/wl_shm\n"); return 1; }
    if (!P.layer_shell) {
        fprintf(stderr, "ioscpanel: compositor lacks zwlr_layer_shell_v1 — cannot map a panel. "
                        "(iosc must implement it; see iosc-shell.md)\n");
        return 2;
    }

    P.nlaunch = sd_scan_apps(P.launch, LAUNCH_MAX);
    fprintf(stderr, "ioscpanel: %d launcher(s), foreign-toplevel=%s\n",
            P.nlaunch, P.ftm ? "yes" : "no (taskbar disabled)");

    P.surf  = wl_compositor_create_surface(P.comp);
    P.layer = zwlr_layer_shell_v1_get_layer_surface(P.layer_shell, P.surf, NULL,
                ZWLR_LAYER_SHELL_V1_LAYER_TOP, "panel");
    zwlr_layer_surface_v1_add_listener(P.layer, &layer_listener, NULL);
    zwlr_layer_surface_v1_set_anchor(P.layer,
        ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP | ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT |
        ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT);
    zwlr_layer_surface_v1_set_size(P.layer, 0, PANEL_H);
    zwlr_layer_surface_v1_set_exclusive_zone(P.layer, PANEL_H);
    zwlr_layer_surface_v1_set_keyboard_interactivity(P.layer, 0);
    wl_surface_commit(P.surf);

    int wfd = wl_display_get_fd(P.dpy);
    int last_min = -1;
    while (P.running) {
        while (wl_display_prepare_read(P.dpy) != 0) wl_display_dispatch_pending(P.dpy);
        wl_display_flush(P.dpy);
        time_t now = time(NULL);
        int to_ms = (int)(60 - (now % 60)) * 1000;   /* wake at the next minute */
        struct pollfd pfd = { .fd = wfd, .events = POLLIN };
        int n = poll(&pfd, 1, to_ms);
        if (n < 0 && errno != EINTR) { wl_display_cancel_read(P.dpy); break; }
        if (n > 0 && (pfd.revents & POLLIN)) wl_display_read_events(P.dpy);
        else wl_display_cancel_read(P.dpy);
        wl_display_dispatch_pending(P.dpy);
        struct tm tm; time_t t2 = time(NULL); localtime_r(&t2, &tm);
        if (tm.tm_min != last_min) { last_min = tm.tm_min; render(); }
    }
    wl_display_disconnect(P.dpy);
    return 0;
}

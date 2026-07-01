/*
 * ioscpanel — the desktop panel for the iosc Wayland compositor.
 *
 * A self-contained zwlr_layer_shell_v1 client anchored to the top edge of the
 * iosc output. It reserves an exclusive zone (maximized toplevels don't draw
 * under it) and renders three regions:
 *
 *   [ launcher icons ......... | taskbar pills (open windows) ....... | clock ]
 *
 * Rendering is real vector drawing via cairo + pangocairo (panel-render.h /
 * panel-layout.h): San Francisco text, rounded translucent surfaces, and PNG
 * app icons resolved from each .desktop's Icon= (panel-icons.h). The wl_shm
 * buffer we hand iosc is wrapped as a cairo ARGB32 surface, so the panel draws
 * on the CPU and iosc composites it (no GPU/IOSurface entitlements needed).
 *
 * - launcher: quick-launch buttons scanned from /var/jb/usr/share/applications;
 *   a tap fork+execs the app (sd_launch).
 * - taskbar: one pill per open toplevel (zwlr_foreign_toplevel_management_v1),
 *   with the app's real icon + title; tap activates, tap the × closes.
 * - clock: HH:MM, repainted each minute off the poll() timeout.
 *
 * Build: build-panel.sh. Needs iosc's zwlr_layer_shell_v1.
 */
#define _GNU_SOURCE
#define SD_NO_DRAW                 /* pull only the .desktop scan + launch + shm helpers */
#include "shell-draw.h"
#include "panel-render.h"
#include "panel-layout.h"
#include "panel-icons.h"
#include "wlr-layer-shell-unstable-v1-client-protocol.h"
#include "wlr-foreign-toplevel-management-unstable-v1-client-protocol.h"

#include <time.h>
#include <poll.h>
#include <errno.h>
#include <signal.h>

/* ------------------------------------------------------------------ config */
#define PANEL_H     44
#define LAUNCH_MAX  PL_MAX_LAUNCH
#define TASK_MAX    PL_MAX_TASK

struct task_item {
    struct zwlr_foreign_toplevel_handle_v1 *handle;
    char  title[96];
    char  app_id[96];
    cairo_surface_t *icon;
    int   icon_tried;
    int   activated;
};

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
    double bg_alpha;

    struct sd_app    launch[LAUNCH_MAX];
    cairo_surface_t *launch_icon[LAUNCH_MAX];
    int   nlaunch;
    struct task_item tasks[TASK_MAX];
    int   ntasks;

    struct panel_hits hits;
} P;

static void clock_string(char *out, size_t n)
{
    time_t t = time(NULL); struct tm tm; localtime_r(&t, &tm);
    snprintf(out, n, "%d:%02d", tm.tm_hour, tm.tm_min);
}

/* Resolve + load an icon for `name` at the current scale, or NULL. */
static cairo_surface_t *load_icon(const char *name)
{
    char path[512];
    if (!pi_resolve(name, P.scale, path, sizeof path)) return NULL;
    return pr_icon_load(path);
}

/* ------------------------------------------------------------- rendering -- */

static void buf_release(void *d, struct wl_buffer *b){ (void)d; wl_buffer_destroy(b); }
static const struct wl_buffer_listener buf_listener = { .release = buf_release };

/* Allocate a wl_shm buffer and wrap its mmap as a cairo ARGB32 surface (scaled
 * logical->physical). Returns the wl_buffer; out_cr/out_surf receive the cairo
 * objects (already scaled so drawing is in logical px). Caller destroys cr+surf
 * after commit; the wl_buffer is destroyed on release. */
static struct wl_buffer *alloc_cairo_buffer(int lw, int lh, int scale,
                                            cairo_t **out_cr, cairo_surface_t **out_surf,
                                            void **out_map, size_t *out_size)
{
    int s = scale > 0 ? scale : 1;
    int bw = lw * s, bh = lh * s;
    int stride = cairo_format_stride_for_width(CAIRO_FORMAT_ARGB32, bw);
    size_t size = (size_t)stride * bh;
    int fd = sd_create_anon_fd(size);
    if (fd < 0) return NULL;
    void *map = mmap(NULL, size, PROT_READ|PROT_WRITE, MAP_SHARED, fd, 0);
    if (map == MAP_FAILED) { close(fd); return NULL; }
    struct wl_shm_pool *pool = wl_shm_create_pool(P.shm, fd, (int32_t)size);
    struct wl_buffer *buf = wl_shm_pool_create_buffer(pool, 0, bw, bh, stride,
                                                      WL_SHM_FORMAT_ARGB8888);
    wl_shm_pool_destroy(pool);
    close(fd);

    cairo_surface_t *surf = cairo_image_surface_create_for_data(
        (unsigned char *)map, CAIRO_FORMAT_ARGB32, bw, bh, stride);
    cairo_t *cr = cairo_create(surf);
    cairo_scale(cr, s, s);
    *out_cr = cr; *out_surf = surf; *out_map = map; *out_size = size;
    return buf;
}

static void build_model(struct panel_model *m)
{
    memset(m, 0, sizeof *m);
    m->bg_alpha = P.bg_alpha;
    m->have_ptr = P.have_ptr; m->px = P.px; m->py = P.py;
    clock_string(m->clock, sizeof m->clock);

    m->nlaunch = P.nlaunch;
    for (int i = 0; i < P.nlaunch; i++) {
        snprintf(m->launch[i].label, sizeof m->launch[i].label, "%s", P.launch[i].name);
        snprintf(m->launch[i].key,   sizeof m->launch[i].key,   "%s", P.launch[i].name);
        m->launch[i].icon = P.launch_icon[i];
    }
    m->ntasks = P.ntasks;
    for (int i = 0; i < P.ntasks; i++) {
        snprintf(m->tasks[i].label, sizeof m->tasks[i].label, "%s",
                 P.tasks[i].title[0] ? P.tasks[i].title : "Window");
        snprintf(m->tasks[i].key, sizeof m->tasks[i].key, "%s",
                 P.tasks[i].title[0] ? P.tasks[i].title : P.tasks[i].app_id);
        m->tasks[i].icon = P.tasks[i].icon;
        m->tasks[i].active = P.tasks[i].activated;
    }
}

static void render(void)
{
    if (!P.configured) return;
    cairo_t *cr; cairo_surface_t *surf; void *map; size_t size;
    struct wl_buffer *buf = alloc_cairo_buffer(P.width, P.height, P.scale,
                                               &cr, &surf, &map, &size);
    if (!buf) { fprintf(stderr, "ioscpanel: cairo buffer alloc failed\n"); return; }

    pr_text_ctx t = pr_text_ctx_new(cr);
    struct panel_model m;
    build_model(&m);
    panel_draw_topbar(cr, &t, P.width, P.height, &m, &P.hits);
    pr_text_ctx_free(&t);

    cairo_surface_flush(surf);
    cairo_destroy(cr);
    cairo_surface_destroy(surf);
    munmap(map, size);   /* iosc copies the shm data during commit access */

    wl_buffer_add_listener(buf, &buf_listener, NULL);
    wl_surface_attach(P.surf, buf, 0, 0);
    wl_surface_damage_buffer(P.surf, 0, 0, P.width * P.scale, P.height * P.scale);
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
static void ft_app_id(void *d, struct zwlr_foreign_toplevel_handle_v1 *h, const char *a)
{
    (void)d; struct task_item *ti = task_for(h); if (!ti || !a) return;
    snprintf(ti->app_id, sizeof ti->app_id, "%s", a);
    if (!ti->icon_tried) { ti->icon_tried = 1; ti->icon = load_icon(a); }
}
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
        if (P.tasks[i].icon) cairo_surface_destroy(P.tasks[i].icon);
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
    for (int i = 0; i < P.hits.n; i++) {
        struct panel_hit *r = &P.hits.v[i];
        if (P.px < r->x || P.px >= r->x + r->w) continue;
        if (r->kind == PL_HIT_LAUNCH && r->idx < P.nlaunch) sd_launch(P.launch[r->idx].exec);
        else if (r->kind == PL_HIT_ACTIVATE && r->idx < P.ntasks && P.tasks[r->idx].handle)
            zwlr_foreign_toplevel_handle_v1_activate(P.tasks[r->idx].handle, P.seat);
        else if (r->kind == PL_HIT_CLOSE && r->idx < P.ntasks && P.tasks[r->idx].handle)
            zwlr_foreign_toplevel_handle_v1_close(P.tasks[r->idx].handle);
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
    P.bg_alpha = 1.0;   /* opaque today; iosc composites layers opaque. Set <1 to
                         * enable translucency once iosc blends layer surfaces. */
    const char *es = getenv("IOSC_PANEL_SCALE");
    if (es && atoi(es) > 0) P.scale = atoi(es);
    const char *op = getenv("IOSC_PANEL_OPACITY");   /* 0..100 */
    if (op && atoi(op) > 0) P.bg_alpha = atoi(op) / 100.0;

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
    for (int i = 0; i < P.nlaunch; i++)
        P.launch_icon[i] = load_icon(P.launch[i].icon[0] ? P.launch[i].icon : P.launch[i].name);
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

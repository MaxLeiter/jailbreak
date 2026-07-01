/*
 * ioscpanel — the desktop panel for the iosc Wayland compositor.
 *
 * A self-contained zwlr_layer_shell_v1 client anchored to the top edge of the
 * iosc output. It reserves an exclusive zone (maximized toplevels don't draw
 * under it) and renders:
 *
 *   [ ⊞ apps | launcher icons | taskbar pills (open windows) | battery date time ]
 *
 * plus a QUICK-SETTINGS card (a second layer surface, toggled by the status
 * cluster) with device name, date, a battery gauge, and Overview / Screenshot
 * actions over a frosted screencopy backdrop.
 *
 * Rendering is real vector drawing via cairo + pangocairo (panel-render.h /
 * panel-layout.h): San Francisco text, rounded translucent surfaces, and PNG
 * app icons resolved from each .desktop's Icon= (panel-icons.h). The wl_shm
 * buffer we hand iosc is wrapped as a cairo ARGB32 surface, so the panel draws
 * on the CPU and iosc composites it (no GPU/IOSurface entitlements needed).
 *
 * Input: wl_pointer (hover + click) AND wl_touch (press feedback on down, act
 * on up) — this is a tablet first. The ⊞ button and the QS "Overview" action
 * fork+exec ioscoverview; launcher taps fork+exec the app (sd_launch);
 * "Screenshot" captures the output via zwlr_screencopy and writes a PNG.
 *
 * Status: battery via IOKit power-source APIs (dlopen'd, hides cleanly if
 * unavailable), device name via MobileGestalt — see shell-status.h.
 *
 * Build: build-panel.sh. Needs iosc's zwlr_layer_shell_v1.
 */
#define _GNU_SOURCE
#define SD_NO_DRAW                 /* pull only the .desktop scan + launch + shm helpers */
#include "shell-draw.h"
#include "shell-theme.h"
#include "panel-render.h"
#include "panel-layout.h"
#include "panel-icons.h"
#include "shell-status.h"
#include "shell-blur.h"
#include "wlr-layer-shell-unstable-v1-client-protocol.h"
#include "wlr-foreign-toplevel-management-unstable-v1-client-protocol.h"
#include "wlr-screencopy-unstable-v1-client-protocol.h"
#include "shell-screencopy.h"

#include <time.h>
#include <poll.h>
#include <errno.h>
#include <signal.h>
#include <libgen.h>
#include <sys/stat.h>

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
    struct wl_touch      *touch;
    struct wl_output     *output;
    struct zwlr_layer_shell_v1 *layer_shell;
    struct zwlr_foreign_toplevel_manager_v1 *ftm;
    struct zwlr_screencopy_manager_v1 *scm;
    int    scm_version;

    /* panel surface */
    struct wl_surface    *surf;
    struct zwlr_layer_surface_v1 *layer;
    int   width, height, scale, configured, running;

    /* quick-settings surface (created on open, destroyed on close) */
    struct wl_surface    *qs_surf;
    struct zwlr_layer_surface_v1 *qs_layer;
    int   qs_w, qs_h, qs_configured;
    cairo_surface_t *qs_backdrop;
    struct qs_model  qs;
    struct panel_hits qs_hits;

    /* input routing: which of our surfaces the pointer/touch is on */
    struct wl_surface *ptr_surf;
    int   px, py, have_ptr;
    int   press_kind, press_idx;       /* touch-down feedback */
    struct wl_surface *touch_surf;
    int   touch_id;

    /* deferred actions (never run screencopy/spawn inside a listener) */
    int   want_qs_toggle, want_overview, want_shot;

    double bg_alpha;
    int   batt_pct, batt_charging;

    struct sd_app    launch[LAUNCH_MAX];
    cairo_surface_t *launch_icon[LAUNCH_MAX];
    int   nlaunch;
    struct task_item tasks[TASK_MAX];
    int   ntasks;

    struct panel_hits hits;
    char  self_dir[512];               /* for spawning ioscoverview */
} P;

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
 * logical->physical). Caller destroys cr+surf after commit; the wl_buffer is
 * destroyed on release. */
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
    if (P.ptr_surf == P.surf) { m->have_ptr = P.have_ptr; m->px = P.px; m->py = P.py; }
    st_clock(m->clock, sizeof m->clock);
    st_date_short(m->date, sizeof m->date);
    m->batt_pct = P.batt_pct; m->batt_charging = P.batt_charging;
    m->qs_open = P.qs_surf != NULL;
    if (P.touch_surf == P.surf) { m->press_kind = P.press_kind; m->press_idx = P.press_idx; }

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

static void render_qs(void)
{
    if (!P.qs_surf || !P.qs_configured) return;
    cairo_t *cr; cairo_surface_t *surf; void *map; size_t size;
    struct wl_buffer *buf = alloc_cairo_buffer(P.qs_w, P.qs_h, P.scale,
                                               &cr, &surf, &map, &size);
    if (!buf) return;

    /* the card has rounded corners: start from transparent */
    cairo_save(cr);
    cairo_set_operator(cr, CAIRO_OPERATOR_CLEAR);
    cairo_paint(cr);
    cairo_restore(cr);

    P.qs.backdrop = P.qs_backdrop;
    if (P.ptr_surf == P.qs_surf) { P.qs.have_ptr = P.have_ptr; P.qs.px = P.px; P.qs.py = P.py; }
    else P.qs.have_ptr = 0;
    if (P.touch_surf == P.qs_surf) { P.qs.press_kind = P.press_kind; P.qs.press_idx = P.press_idx; }
    else P.qs.press_kind = 0;
    P.qs.batt_pct = P.batt_pct; P.qs.batt_charging = P.batt_charging;

    pr_text_ctx t = pr_text_ctx_new(cr);
    panel_draw_qs(cr, &t, P.qs_w, P.qs_h, &P.qs, &P.qs_hits);
    pr_text_ctx_free(&t);

    cairo_surface_flush(surf);
    cairo_destroy(cr);
    cairo_surface_destroy(surf);
    munmap(map, size);

    wl_buffer_add_listener(buf, &buf_listener, NULL);
    wl_surface_attach(P.qs_surf, buf, 0, 0);
    wl_surface_damage_buffer(P.qs_surf, 0, 0, P.qs_w * P.scale, P.qs_h * P.scale);
    wl_surface_commit(P.qs_surf);
}

/* ------------------------------------------------------- quick settings --- */

static void qs_close(void);
static void qs_layer_configure(void *d, struct zwlr_layer_surface_v1 *ls,
                               uint32_t serial, uint32_t w, uint32_t h)
{
    (void)d;
    if (w) P.qs_w = (int)w;
    if (h) P.qs_h = (int)h;
    zwlr_layer_surface_v1_ack_configure(ls, serial);
    P.qs_configured = 1;
    render_qs();
}
static void qs_layer_closed(void *d, struct zwlr_layer_surface_v1 *ls)
{ (void)d; (void)ls; qs_close(); }
static const struct zwlr_layer_surface_v1_listener qs_layer_listener = {
    .configure = qs_layer_configure, .closed = qs_layer_closed,
};

static void qs_close(void)
{
    if (!P.qs_surf) return;
    if (P.ptr_surf == P.qs_surf) P.ptr_surf = NULL;
    if (P.touch_surf == P.qs_surf) { P.touch_surf = NULL; P.press_kind = 0; }
    zwlr_layer_surface_v1_destroy(P.qs_layer); P.qs_layer = NULL;
    wl_surface_destroy(P.qs_surf);             P.qs_surf = NULL;
    if (P.qs_backdrop) { cairo_surface_destroy(P.qs_backdrop); P.qs_backdrop = NULL; }
    P.qs_configured = 0;
    render();   /* un-light the status cluster */
}

static void qs_open(void)
{
    if (P.qs_surf) return;

    memset(&P.qs, 0, sizeof P.qs);
    st_device_name(P.qs.device, sizeof P.qs.device, "iPad");
    st_date_long(P.qs.date_long, sizeof P.qs.date_long);
    P.qs.batt_pct = P.batt_pct; P.qs.batt_charging = P.batt_charging;
    P.qs_w = QS_W; P.qs_h = panel_qs_height(&P.qs);

    /* frosted backdrop: capture the region the card will cover (physical px).
     * The card sits just below the panel at the right edge. */
    if (P.scm) {
        int lx = P.width - QS_MARGIN - QS_W, ly = PANEL_H + QS_MARGIN;
        cairo_surface_t *cap = sc_capture(P.dpy, P.shm, P.scm, P.scm_version, P.output,
                                          lx * P.scale, ly * P.scale,
                                          QS_W * P.scale, P.qs_h * P.scale);
        if (cap) {
            P.qs_backdrop = sb_backdrop_build(cap, 4, 6);
            cairo_surface_destroy(cap);
        }
    }

    P.qs_surf  = wl_compositor_create_surface(P.comp);
    P.qs_layer = zwlr_layer_shell_v1_get_layer_surface(P.layer_shell, P.qs_surf, NULL,
                    ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY, "quick-settings");
    zwlr_layer_surface_v1_add_listener(P.qs_layer, &qs_layer_listener, NULL);
    zwlr_layer_surface_v1_set_anchor(P.qs_layer,
        ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP | ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT);
    zwlr_layer_surface_v1_set_size(P.qs_layer, (uint32_t)P.qs_w, (uint32_t)P.qs_h);
    zwlr_layer_surface_v1_set_margin(P.qs_layer, QS_MARGIN, QS_MARGIN, 0, 0);
    zwlr_layer_surface_v1_set_keyboard_interactivity(P.qs_layer, 0);
    wl_surface_commit(P.qs_surf);   /* no-buffer commit -> configure */
    render();   /* light the status cluster */
}

/* ------------------------------------------------------------- actions ---- */

static void spawn_overview(void)
{
    pid_t pid = fork();
    if (pid != 0) return;
    setsid();
    char path[600];
    snprintf(path, sizeof path, "%s/ioscoverview", P.self_dir);
    execl(path, "ioscoverview", (char*)NULL);
    execl("/var/jb/usr/local/bin/ioscoverview", "ioscoverview", (char*)NULL);
    execlp("ioscoverview", "ioscoverview", (char*)NULL);
    _exit(127);
}

/* Full-output screenshot -> PNG. Runs from the main loop (roundtrips inside). */
static void take_screenshot(void)
{
    if (!P.scm) return;
    cairo_surface_t *cap = sc_capture(P.dpy, P.shm, P.scm, P.scm_version, P.output,
                                      0, 0, 0, 0);
    if (!cap) { fprintf(stderr, "ioscpanel: screenshot capture failed\n"); return; }

    time_t now = time(NULL); struct tm tm; localtime_r(&now, &tm);
    char name[64];
    strftime(name, sizeof name, "xios-%Y%m%d-%H%M%S.png", &tm);

    static const char *dirs[] = { "/var/jb/var/mobile/Documents", "/var/jb/tmp" };
    char path[300] = "";
    for (size_t i = 0; i < sizeof(dirs)/sizeof(dirs[0]); i++) {
        struct stat st;
        if (stat(dirs[i], &st) != 0 || !S_ISDIR(st.st_mode)) continue;
        snprintf(path, sizeof path, "%s/%s", dirs[i], name);
        if (cairo_surface_write_to_png(cap, path) == CAIRO_STATUS_SUCCESS) {
            fprintf(stderr, "ioscpanel: screenshot -> %s\n", path);
            break;
        }
        path[0] = 0;
    }
    if (!path[0]) fprintf(stderr, "ioscpanel: screenshot write failed\n");
    cairo_surface_destroy(cap);
}

/* Act on a hit (panel or QS). Heavy actions (screencopy, spawn) are deferred
 * to the main loop via want_* flags — never run roundtrips inside a listener. */
static void act_on_hit(const struct panel_hit *r)
{
    switch (r->kind) {
    case PL_HIT_LAUNCH:
        if (r->idx < P.nlaunch) sd_launch(P.launch[r->idx].exec);
        break;
    case PL_HIT_ACTIVATE:
        if (r->idx < P.ntasks && P.tasks[r->idx].handle)
            zwlr_foreign_toplevel_handle_v1_activate(P.tasks[r->idx].handle, P.seat);
        break;
    case PL_HIT_CLOSE:
        if (r->idx < P.ntasks && P.tasks[r->idx].handle)
            zwlr_foreign_toplevel_handle_v1_close(P.tasks[r->idx].handle);
        break;
    case PL_HIT_APPGRID:  P.want_overview = 1; break;
    case PL_HIT_STATUS:   P.want_qs_toggle = 1; break;
    case QS_HIT_OVERVIEW: P.want_overview = 1; P.want_qs_toggle = 1; break;
    case QS_HIT_SHOT:     P.want_shot = 1;     P.want_qs_toggle = 1; break;
    }
}

static void hit_at(struct wl_surface *sf, int x, int y)
{
    const struct panel_hits *hs = sf == P.qs_surf && P.qs_surf ? &P.qs_hits : &P.hits;
    int i = pl_hit_test(hs, x, y);
    if (i >= 0) act_on_hit(&hs->v[i]);
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

static void rerender_for(struct wl_surface *sf)
{
    if (P.qs_surf && sf == P.qs_surf) render_qs(); else render();
}

static void pt_enter(void *d, struct wl_pointer *p, uint32_t s, struct wl_surface *sf, wl_fixed_t x, wl_fixed_t y)
{ (void)d;(void)p;(void)s; P.ptr_surf=sf; P.have_ptr=1; P.px=wl_fixed_to_int(x); P.py=wl_fixed_to_int(y); rerender_for(sf); }
static void pt_leave(void *d, struct wl_pointer *p, uint32_t s, struct wl_surface *sf)
{ (void)d;(void)p;(void)s; P.have_ptr=0; P.ptr_surf=NULL; rerender_for(sf); }
static void pt_motion(void *d, struct wl_pointer *p, uint32_t t, wl_fixed_t x, wl_fixed_t y)
{ (void)d;(void)p;(void)t; P.px=wl_fixed_to_int(x); P.py=wl_fixed_to_int(y); rerender_for(P.ptr_surf); }
static void pt_button(void *d, struct wl_pointer *p, uint32_t serial, uint32_t t, uint32_t button, uint32_t state)
{
    (void)d;(void)p;(void)serial;(void)t;
    if (state != WL_POINTER_BUTTON_STATE_PRESSED || button != 0x110 /*BTN_LEFT*/) return;
    if (P.ptr_surf) hit_at(P.ptr_surf, P.px, P.py);
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

/* --------------------------------------------------------------- touch --- */
/* Finger down = press feedback on the hit under it; finger up = act. */

static void tc_down(void *d, struct wl_touch *t, uint32_t serial, uint32_t time,
                    struct wl_surface *sf, int32_t id, wl_fixed_t x, wl_fixed_t y)
{
    (void)d;(void)t;(void)serial;(void)time;
    if (P.touch_surf) return;                    /* single-touch UI */
    P.touch_surf = sf; P.touch_id = id;
    P.px = wl_fixed_to_int(x); P.py = wl_fixed_to_int(y);
    const struct panel_hits *hs = (P.qs_surf && sf == P.qs_surf) ? &P.qs_hits : &P.hits;
    int i = pl_hit_test(hs, P.px, P.py);
    if (i >= 0) { P.press_kind = hs->v[i].kind; P.press_idx = hs->v[i].idx; }
    rerender_for(sf);
}
static void tc_up(void *d, struct wl_touch *t, uint32_t serial, uint32_t time, int32_t id)
{
    (void)d;(void)t;(void)serial;(void)time;
    if (!P.touch_surf || id != P.touch_id) return;
    struct wl_surface *sf = P.touch_surf;
    P.touch_surf = NULL; P.press_kind = 0; P.press_idx = 0;
    hit_at(sf, P.px, P.py);
    rerender_for(sf);
}
static void tc_motion(void *d, struct wl_touch *t, uint32_t time, int32_t id, wl_fixed_t x, wl_fixed_t y)
{ (void)d;(void)t;(void)time; if (P.touch_surf && id == P.touch_id) { P.px=wl_fixed_to_int(x); P.py=wl_fixed_to_int(y); } }
static void tc_frame(void *d, struct wl_touch *t){ (void)d;(void)t; }
static void tc_cancel(void *d, struct wl_touch *t)
{ (void)d;(void)t; struct wl_surface *sf = P.touch_surf; P.touch_surf=NULL; P.press_kind=0; P.press_idx=0; if (sf) rerender_for(sf); }
static void tc_shape(void *d, struct wl_touch *t, int32_t id, wl_fixed_t maj, wl_fixed_t min)
{ (void)d;(void)t;(void)id;(void)maj;(void)min; }
static void tc_orient(void *d, struct wl_touch *t, int32_t id, wl_fixed_t o)
{ (void)d;(void)t;(void)id;(void)o; }
static const struct wl_touch_listener touch_listener = {
    .down = tc_down, .up = tc_up, .motion = tc_motion, .frame = tc_frame,
    .cancel = tc_cancel, .shape = tc_shape, .orientation = tc_orient,
};

static void seat_caps(void *d, struct wl_seat *s, uint32_t caps)
{
    (void)d;
    if ((caps & WL_SEAT_CAPABILITY_POINTER) && !P.ptr) {
        P.ptr = wl_seat_get_pointer(s); wl_pointer_add_listener(P.ptr, &pointer_listener, NULL);
    }
    if ((caps & WL_SEAT_CAPABILITY_TOUCH) && !P.touch) {
        P.touch = wl_seat_get_touch(s); wl_touch_add_listener(P.touch, &touch_listener, NULL);
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
    else if (!strcmp(iface, wl_output_interface.name) && !P.output)
        P.output = wl_registry_bind(r, name, &wl_output_interface, ver < 2 ? ver : 2);
    else if (!strcmp(iface, wl_seat_interface.name)) {
        P.seat = wl_registry_bind(r, name, &wl_seat_interface, ver < 5 ? ver : 5);
        wl_seat_add_listener(P.seat, &seat_listener, NULL);
    } else if (!strcmp(iface, zwlr_layer_shell_v1_interface.name))
        P.layer_shell = wl_registry_bind(r, name, &zwlr_layer_shell_v1_interface, ver < 4 ? ver : 4);
    else if (!strcmp(iface, zwlr_foreign_toplevel_manager_v1_interface.name)) {
        P.ftm = wl_registry_bind(r, name, &zwlr_foreign_toplevel_manager_v1_interface, ver < 3 ? ver : 3);
        zwlr_foreign_toplevel_manager_v1_add_listener(P.ftm, &ftm_listener, NULL);
    } else if (!strcmp(iface, zwlr_screencopy_manager_v1_interface.name)) {
        P.scm_version = (int)(ver < 3 ? ver : 3);
        P.scm = wl_registry_bind(r, name, &zwlr_screencopy_manager_v1_interface, (uint32_t)P.scm_version);
    }
}
static void reg_remove(void *d, struct wl_registry *r, uint32_t name){ (void)d;(void)r;(void)name; }
static const struct wl_registry_listener registry_listener = { .global = reg_global, .global_remove = reg_remove };

/* ------------------------------------------------------------------ main */

static void poll_battery(void)
{
    int pct, chg;
    if (st_battery(&pct, &chg)) { P.batt_pct = pct; P.batt_charging = chg; }
    else P.batt_pct = -1;
}

int main(int argc, char **argv)
{
    signal(SIGCHLD, SIG_IGN);
    memset(&P, 0, sizeof P);
    P.width = 1080; P.height = PANEL_H; P.scale = 2; P.running = 1;
    P.batt_pct = -1;
    P.bg_alpha = 1.0;   /* opaque today; iosc composites layers opaque. Set <1 to
                         * enable translucency once iosc blends layer surfaces. */
    const char *es = getenv("IOSC_PANEL_SCALE");
    if (es && atoi(es) > 0) P.scale = atoi(es);
    const char *op = getenv("IOSC_PANEL_OPACITY");   /* 0..100 */
    if (op && atoi(op) > 0) P.bg_alpha = atoi(op) / 100.0;

    /* remember our dir so the ⊞ button can spawn a sibling ioscoverview */
    if (argc > 0 && strchr(argv[0], '/')) {
        char tmp[512]; snprintf(tmp, sizeof tmp, "%s", argv[0]);
        snprintf(P.self_dir, sizeof P.self_dir, "%s", dirname(tmp));
    } else snprintf(P.self_dir, sizeof P.self_dir, "/var/jb/usr/local/bin");

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
    poll_battery();
    fprintf(stderr, "ioscpanel: %d launcher(s), foreign-toplevel=%s, screencopy=%s, battery=%s\n",
            P.nlaunch, P.ftm ? "yes" : "no (taskbar disabled)",
            P.scm ? "yes" : "no (QS backdrop/screenshot off)",
            P.batt_pct >= 0 ? "yes" : "no");

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

        /* deferred actions (safe here: outside any listener) */
        if (P.want_qs_toggle) {
            P.want_qs_toggle = 0;
            if (P.qs_surf) qs_close(); else qs_open();
        }
        if (P.want_shot)     { P.want_shot = 0; wl_display_roundtrip(P.dpy); take_screenshot(); }
        if (P.want_overview) { P.want_overview = 0; spawn_overview(); }

        struct tm tm; time_t t2 = time(NULL); localtime_r(&t2, &tm);
        if (tm.tm_min != last_min) {
            last_min = tm.tm_min;
            poll_battery();
            render();
        }
    }
    wl_display_disconnect(P.dpy);
    return 0;
}

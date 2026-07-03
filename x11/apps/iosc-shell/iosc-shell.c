/*
 * iosc shell chrome — status bar and dock clients for the iosc Wayland compositor.
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
#define SD_APP_SCAN
#define SD_CAIRO                   /* sd_cairo_pool from shell-draw.h */
#include "shell-draw.h"
#include "shell-theme.h"
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
/* Reference design space (matches preview-host.c + shell-theme.h tuning). The
 * panel is always drawn PL_REF_W wide x PL_REF_H tall in these units, then
 * scaled to the real output by P.ui so its on-glass size is -logical-invariant. */
#define IOSC_SHELL_VER "0.9.7"

#define PL_REF_W    1440
#define PL_REF_H    64     /* >= TH_TOUCH (44+ iOS pt at the 1.5 default) */
#define PANEL_H     PL_REF_H
#define DOCK_REORDER_HOLD_MS 540

enum shell_surface_mode {
    MODE_UNKNOWN = 0,
    MODE_BAR   = 1,   /* tablet-DE slim status bar */
    MODE_DOCK  = 2,   /* tablet-DE floating bottom dock */
};

/* logical <-> reference conversions via the current UI scale */
static double pl_ui(void);
static inline int pl_to_ref(int logical) { double u = pl_ui(); return (int)lround(logical / u); }
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
    struct sd_cairo_pool surface_pool;
    enum shell_surface_mode mode;
    int   width, height, scale, scale_env, configured, running;
    /* UI scale: keep the chrome a CONSTANT on-glass size at any -logical.
     * ui = logical_width / PL_REF_W. The panel is drawn in a fixed
     * PL_REF_W x PL_REF_H reference space (what shell-theme.h is tuned for) and
     * scaled by ui, so raising -logical shrinks app content WITHOUT shrinking
     * the panel's 44pt+ touch targets. ui = 1.0 at the 1440x1080 default. */
    double ui;
    int   req_h;                       /* last layer height we requested */

    /* quick-settings surface (created on open, destroyed on close) */
    struct wl_surface    *qs_surf;
    struct zwlr_layer_surface_v1 *qs_layer;
    struct sd_cairo_pool qs_pool;
    int   qs_w, qs_h, qs_wref, qs_href, qs_configured;
    cairo_surface_t *qs_backdrop;
    struct qs_model  qs;
    struct panel_hits qs_hits;

    /* window-menu popup (created on app-name tap) */
    struct wl_surface    *wm_surf;
    struct zwlr_layer_surface_v1 *wm_layer;
    struct sd_cairo_pool wm_pool;
    int   wm_w, wm_h, wm_configured;
    struct panel_hits wm_hits;
    int   wm_idx;                      /* task index the menu was opened for */

    /* input routing: which of our surfaces the pointer/touch is on */
    struct wl_surface *ptr_surf;
    int   px, py, have_ptr;
    int   ptr_kind, ptr_idx;
    int   press_kind, press_idx;       /* touch-down feedback */
    struct wl_surface *touch_surf;
    int   touch_id;
    int   touch_x0, touch_y0;
    int   touch_moved;
    uint32_t input_time;
    uint32_t last_touch_up_time;
    uint32_t last_launch_time;
    int   last_launch_idx;
    uint64_t press_ms;
    int   reorder_active, reorder_idx, reorder_target, reorder_x, reorder_y;

    /* deferred actions (never run screencopy/spawn inside a listener) */
    int   want_qs_toggle, want_overview, want_shot, want_wm_toggle;

    double bg_alpha;
    int   batt_pct, batt_charging;
    int   wifi_on, net_kind;

    struct sd_app    launch[LAUNCH_MAX];
    cairo_surface_t *launch_icon[LAUNCH_MAX];
    int   nlaunch;
    struct task_item tasks[TASK_MAX];
    int   ntasks;

    struct panel_hits hits;
    char  self_dir[512];               /* for spawning ioscoverview */
} P;

static const char *mode_name(void)
{
    switch (P.mode) {
    case MODE_BAR:  return "ioscbar";
    case MODE_DOCK: return "ioscdock";
    default:        return "iosc-shell";
    }
}

static int mode_ref_h(void)
{
    switch (P.mode) {
    case MODE_BAR:  return BAR_REF_H;
    case MODE_DOCK: return DOCK_REF_H;
    default:        return BAR_REF_H;
    }
}

/* Current UI scale (logical_width / reference_width), clamped to a sane range. */
static double pl_ui(void)
{
    double u = P.ui > 0 ? P.ui : 1.0;
    if (u < 0.6) u = 0.6;
    if (u > 2.5) u = 2.5;
    return u;
}

static uint64_t mono_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000u + (uint64_t)ts.tv_nsec / 1000000u;
}

static void dock_order_path(char *out, size_t n)
{
    const char *env = getenv("IOSC_DOCK_ORDER");
    if (env && *env) { snprintf(out, n, "%s", env); return; }
    snprintf(out, n, "/var/mobile/Library/Preferences/com.max.iosc-dock-order");
}

static void dock_apply_saved_order(void)
{
    char path[256]; dock_order_path(path, sizeof path);
    FILE *f = fopen(path, "r");
    if (!f) return;
    struct sd_app ordered[LAUNCH_MAX];
    int used[LAUNCH_MAX] = {0}, n = 0;
    char line[256];
    while (fgets(line, sizeof line, f) && n < P.nlaunch) {
        line[strcspn(line, "\r\n")] = 0;
        if (!line[0]) continue;
        for (int i = 0; i < P.nlaunch; i++) {
            if (!used[i] && !strcmp(P.launch[i].exec, line)) {
                ordered[n++] = P.launch[i];
                used[i] = 1;
                break;
            }
        }
    }
    fclose(f);
    for (int i = 0; i < P.nlaunch && n < LAUNCH_MAX; i++)
        if (!used[i]) ordered[n++] = P.launch[i];
    for (int i = 0; i < n; i++) P.launch[i] = ordered[i];
}

static void dock_save_order(void)
{
    char path[256]; dock_order_path(path, sizeof path);
    FILE *f = fopen(path, "w");
    if (!f) return;
    for (int i = 0; i < P.nlaunch; i++)
        fprintf(f, "%s\n", P.launch[i].exec);
    fclose(f);
}

static void dock_move_launcher(int from, int to)
{
    if (from < 0 || from >= P.nlaunch || to < 0 || to >= P.nlaunch || from == to) return;
    struct sd_app app = P.launch[from];
    cairo_surface_t *icon = P.launch_icon[from];
    if (from < to) {
        for (int i = from; i < to; i++) {
            P.launch[i] = P.launch[i + 1];
            P.launch_icon[i] = P.launch_icon[i + 1];
        }
    } else {
        for (int i = from; i > to; i--) {
            P.launch[i] = P.launch[i - 1];
            P.launch_icon[i] = P.launch_icon[i - 1];
        }
    }
    P.launch[to] = app;
    P.launch_icon[to] = icon;
    P.reorder_idx = to;
    P.reorder_target = to;
}

/* Resolve + load an icon for `name` at the current scale, or NULL. */
static cairo_surface_t *load_icon(const char *name)
{
    char path[512];
    if (!pi_resolve(name, P.scale, path, sizeof path)) return NULL;
    return pr_icon_load(path);
}

/* ------------------------------------------------------------- rendering -- */

static void build_model(struct panel_model *m)
{
    memset(m, 0, sizeof *m);
    m->bg_alpha = P.bg_alpha;
    /* hover coords are logical; the panel draws in reference space, so convert */
    if (P.ptr_surf == P.surf) { m->have_ptr = P.have_ptr; m->px = pl_to_ref(P.px); m->py = pl_to_ref(P.py); }
    st_clock(m->clock, sizeof m->clock);
    st_date_short(m->date, sizeof m->date);
    m->batt_pct = P.batt_pct; m->batt_charging = P.batt_charging;
    m->wifi_on = P.wifi_on;
    m->net_kind = P.net_kind;
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
    cairo_t *cr; cairo_surface_t *surf;
    struct sd_cairo_slot *slot = sd_cairo_pool_begin(&P.surface_pool, P.shm,
                                                     P.width, P.height, P.scale,
                                                     &cr, &surf);
    struct wl_buffer *buf = slot ? slot->buffer : NULL;
    if (!buf) { fprintf(stderr, "%s: cairo buffer alloc failed\n", mode_name()); return; }

    cairo_save(cr);
    cairo_set_operator(cr, CAIRO_OPERATOR_CLEAR);
    cairo_paint(cr);
    cairo_restore(cr);

    /* draw the fixed reference panel, zoomed by ui to fill the real output */
    double ui = pl_ui();
    cairo_scale(cr, ui, ui);
    int wref = (int)lround(P.width / ui);   /* == PL_REF_W */

    pr_text_ctx t = pr_text_ctx_new(cr);
    struct panel_model m;
    build_model(&m);
    if (P.mode == MODE_BAR)
        panel_draw_statusbar(cr, &t, wref, BAR_REF_H, &m, &P.hits);
    else if (P.mode == MODE_DOCK)
        panel_draw_dock(cr, &t, wref, DOCK_REF_H, &m, &P.hits);
    else
        panel_draw_topbar(cr, &t, wref, PL_REF_H, &m, &P.hits);
    pr_text_ctx_free(&t);

    cairo_surface_flush(surf);
    cairo_destroy(cr);
    cairo_surface_destroy(surf);

    wl_surface_set_buffer_scale(P.surf, P.scale);
    wl_surface_attach(P.surf, buf, 0, 0);
    wl_surface_damage_buffer(P.surf, 0, 0, P.width * P.scale, P.height * P.scale);
    wl_surface_commit(P.surf);
}

static void render_qs(void)
{
    if (!P.qs_surf || !P.qs_configured) return;
    cairo_t *cr; cairo_surface_t *surf;
    struct sd_cairo_slot *slot = sd_cairo_pool_begin(&P.qs_pool, P.shm,
                                                     P.qs_w, P.qs_h, P.scale,
                                                     &cr, &surf);
    struct wl_buffer *buf = slot ? slot->buffer : NULL;
    if (!buf) return;

    /* the card has rounded corners: start from transparent */
    cairo_save(cr);
    cairo_set_operator(cr, CAIRO_OPERATOR_CLEAR);
    cairo_paint(cr);
    cairo_restore(cr);

    P.qs.backdrop = P.qs_backdrop;
    if (P.ptr_surf == P.qs_surf) { P.qs.have_ptr = P.have_ptr; P.qs.px = pl_to_ref(P.px); P.qs.py = pl_to_ref(P.py); }
    else P.qs.have_ptr = 0;
    if (P.touch_surf == P.qs_surf) { P.qs.press_kind = P.press_kind; P.qs.press_idx = P.press_idx; }
    else P.qs.press_kind = 0;
    P.qs.batt_pct = P.batt_pct; P.qs.batt_charging = P.batt_charging;

    double ui = pl_ui();
    cairo_scale(cr, ui, ui);
    pr_text_ctx t = pr_text_ctx_new(cr);
    panel_draw_qs(cr, &t, P.qs_wref, P.qs_href, &P.qs, &P.qs_hits);
    pr_text_ctx_free(&t);

    cairo_surface_flush(surf);
    cairo_destroy(cr);
    cairo_surface_destroy(surf);

    wl_surface_set_buffer_scale(P.qs_surf, P.scale);
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
    sd_cairo_pool_destroy(&P.qs_pool);
    zwlr_layer_surface_v1_destroy(P.qs_layer); P.qs_layer = NULL;
    wl_surface_destroy(P.qs_surf);             P.qs_surf = NULL;
    if (P.qs_backdrop) { cairo_surface_destroy(P.qs_backdrop); P.qs_backdrop = NULL; }
    P.qs_configured = 0;
    render();   /* un-light the status cluster */
}

/* ----------------------------------------------------------- window menu -- */

static void wm_render(void);
static void wm_close(void);

static void wm_layer_configure(void *d, struct zwlr_layer_surface_v1 *ls,
                               uint32_t serial, uint32_t w, uint32_t h)
{
    (void)d;
    if (w) P.wm_w = (int)w;
    if (h) P.wm_h = (int)h;
    zwlr_layer_surface_v1_ack_configure(ls, serial);
    P.wm_configured = 1;
    wm_render();
}
static void wm_layer_closed(void *d, struct zwlr_layer_surface_v1 *ls)
{ (void)d; (void)ls; wm_close(); }
static const struct zwlr_layer_surface_v1_listener wm_layer_listener = {
    .configure = wm_layer_configure, .closed = wm_layer_closed,
};

static void wm_close(void)
{
    if (!P.wm_surf) return;
    if (P.ptr_surf == P.wm_surf) P.ptr_surf = NULL;
    if (P.touch_surf == P.wm_surf) { P.touch_surf = NULL; P.press_kind = 0; }
    sd_cairo_pool_destroy(&P.wm_pool);
    zwlr_layer_surface_v1_destroy(P.wm_layer); P.wm_layer = NULL;
    wl_surface_destroy(P.wm_surf);             P.wm_surf = NULL;
    P.wm_configured = 0;
}

static void wm_open(int task_idx)
{
    if (P.wm_surf) { wm_close(); return; }
    P.wm_idx = task_idx;

    double ui = pl_ui();
    P.wm_w = (int)lround(WM_W * ui);
    P.wm_h = (int)lround(WM_H * ui);

    P.wm_surf  = wl_compositor_create_surface(P.comp);
    P.wm_layer = zwlr_layer_shell_v1_get_layer_surface(P.layer_shell, P.wm_surf, NULL,
                    ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY, "window-menu");
    zwlr_layer_surface_v1_add_listener(P.wm_layer, &wm_layer_listener, NULL);
    zwlr_layer_surface_v1_set_anchor(P.wm_layer,
        ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP | ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT);
    int margin_top = (int)lround(mode_ref_h() * ui) + 4;
    int margin_left = 12;
    zwlr_layer_surface_v1_set_margin(P.wm_layer, margin_top, 0, 0, margin_left);
    zwlr_layer_surface_v1_set_size(P.wm_layer, (uint32_t)P.wm_w, (uint32_t)P.wm_h);
    zwlr_layer_surface_v1_set_keyboard_interactivity(P.wm_layer, 0);
    wl_surface_commit(P.wm_surf);
}

static void wm_render(void)
{
    if (!P.wm_surf || !P.wm_configured) return;
    cairo_t *cr; cairo_surface_t *surf;
    struct sd_cairo_slot *slot = sd_cairo_pool_begin(&P.wm_pool, P.shm,
                                                     P.wm_w, P.wm_h, P.scale,
                                                     &cr, &surf);
    struct wl_buffer *buf = slot ? slot->buffer : NULL;
    if (!buf) return;

    cairo_save(cr);
    cairo_set_operator(cr, CAIRO_OPERATOR_CLEAR);
    cairo_paint(cr);
    cairo_restore(cr);

    double ui = pl_ui();
    cairo_scale(cr, ui, ui);
    int wm_wref = (int)lround(P.wm_w / ui);
    int wm_href = (int)lround(P.wm_h / ui);
    pr_text_ctx t = pr_text_ctx_new(cr);
    panel_draw_window_menu(cr, &t, wm_wref, wm_href, &P.wm_hits);
    pr_text_ctx_free(&t);

    cairo_surface_flush(surf);
    cairo_destroy(cr);
    cairo_surface_destroy(surf);

    wl_surface_set_buffer_scale(P.wm_surf, P.scale);
    wl_surface_attach(P.wm_surf, buf, 0, 0);
    wl_surface_damage_buffer(P.wm_surf, 0, 0, P.wm_w * P.scale, P.wm_h * P.scale);
    wl_surface_commit(P.wm_surf);
}

static void qs_open(void)
{
    if (P.qs_surf) return;

    memset(&P.qs, 0, sizeof P.qs);
    st_device_name(P.qs.device, sizeof P.qs.device, "iPad");
    st_date_long(P.qs.date_long, sizeof P.qs.date_long);
    P.qs.batt_pct = P.batt_pct; P.qs.batt_charging = P.batt_charging;

    /* card is sized in reference space (constant on-glass), then scaled to
     * logical px by ui for the layer surface + capture region. */
    double ui = pl_ui();
    P.qs_wref = panel_qs_width(PL_REF_W);   /* caps wide, fits narrow */
    P.qs_href = panel_qs_height(&P.qs);
    P.qs_w = (int)lround(P.qs_wref * ui);
    P.qs_h = (int)lround(P.qs_href * ui);
    int margin = (int)lround(QS_MARGIN * ui);
    int panel_h = (int)lround(mode_ref_h() * ui);

    /* frosted backdrop: capture the region the card will cover (physical px).
     * The card sits just below the panel at the right edge. */
    if (P.scm) {
        int lx = P.width - margin - P.qs_w, ly = panel_h + margin;
        cairo_surface_t *cap = sc_capture(P.dpy, P.shm, P.scm, P.scm_version, P.output,
                                          lx * P.scale, ly * P.scale,
                                          P.qs_w * P.scale, P.qs_h * P.scale);
        if (cap) {
            P.qs_backdrop = sb_backdrop_build(cap, 4, 6);
            cairo_surface_destroy(cap);
        }
    }

    P.qs_surf  = wl_compositor_create_surface(P.comp);
    P.qs_layer = zwlr_layer_shell_v1_get_layer_surface(P.layer_shell, P.qs_surf, NULL,
                    ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY, "control-center");
    zwlr_layer_surface_v1_add_listener(P.qs_layer, &qs_layer_listener, NULL);
    zwlr_layer_surface_v1_set_anchor(P.qs_layer,
        ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP | ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT);
    zwlr_layer_surface_v1_set_size(P.qs_layer, (uint32_t)P.qs_w, (uint32_t)P.qs_h);
    zwlr_layer_surface_v1_set_margin(P.qs_layer, margin, margin, 0, 0);
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
    sd_join_path(path, sizeof path, sd_jbroot(), "/usr/local/bin/ioscoverview");
    execl(path, "ioscoverview", (char*)NULL);
    execlp("ioscoverview", "ioscoverview", (char*)NULL);
    _exit(127);
}

/* Close the window menu if it's open and the tap is on a different surface. */
static void wm_dismiss_on_other_tap(struct wl_surface *sf)
{
    if (P.wm_surf && sf != P.wm_surf) wm_close();
}

/* Full-output screenshot -> PNG. Runs from the main loop (roundtrips inside). */
static void take_screenshot(void)
{
    if (!P.scm) return;
    cairo_surface_t *cap = sc_capture(P.dpy, P.shm, P.scm, P.scm_version, P.output,
                                      0, 0, 0, 0);
    if (!cap) { fprintf(stderr, "%s: screenshot capture failed\n", mode_name()); return; }

    time_t now = time(NULL); struct tm tm; localtime_r(&now, &tm);
    char name[64];
    strftime(name, sizeof name, "xios-%Y%m%d-%H%M%S.png", &tm);

    char docs[256], tmpdir[256];
    sd_join_path(docs, sizeof docs, sd_jbroot(), "/var/mobile/Documents");
    sd_join_path(tmpdir, sizeof tmpdir, sd_jbroot(), "/tmp");
    const char *dirs[] = { docs, tmpdir };
    char path[300] = "";
    for (size_t i = 0; i < sizeof(dirs)/sizeof(dirs[0]); i++) {
        struct stat st;
        if (stat(dirs[i], &st) != 0 || !S_ISDIR(st.st_mode)) continue;
        snprintf(path, sizeof path, "%s/%s", dirs[i], name);
        if (cairo_surface_write_to_png(cap, path) == CAIRO_STATUS_SUCCESS) {
            fprintf(stderr, "%s: screenshot -> %s\n", mode_name(), path);
            break;
        }
        path[0] = 0;
    }
    if (!path[0]) fprintf(stderr, "%s: screenshot write failed\n", mode_name());
    cairo_surface_destroy(cap);
}

static int pdbg(void);

/* Act on a hit (panel or QS). Heavy actions (screencopy, spawn) are deferred
 * to the main loop via want_* flags — never run roundtrips inside a listener. */
static void act_on_hit(const struct panel_hit *r)
{
    switch (r->kind) {
    case PL_HIT_LAUNCH:
        if (r->idx < P.nlaunch) {
            uint32_t dt = P.input_time - P.last_launch_time;
            if (P.last_launch_idx >= 0 && P.last_launch_idx == r->idx && dt < 700) {
                if (pdbg()) fprintf(stderr, "%s: suppress duplicate launch idx=%d dt=%u\n",
                                    mode_name(), r->idx, dt);
                break;
            }
            P.last_launch_idx = r->idx;
            P.last_launch_time = P.input_time;
            sd_launch(P.launch[r->idx].exec);
        }
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
    case PL_HIT_APPNAME:  P.want_wm_toggle = 1; break;
    case WM_HIT_CLOSE:
        if (P.wm_idx >= 0 && P.wm_idx < P.ntasks) {
            zwlr_foreign_toplevel_handle_v1_close(P.tasks[P.wm_idx].handle);
            wm_close();
        }
        break;
    case WM_HIT_MINIMIZE:
        if (P.wm_idx >= 0 && P.wm_idx < P.ntasks) {
            zwlr_foreign_toplevel_handle_v1_set_minimized(P.tasks[P.wm_idx].handle);
            wm_close();
        }
        break;
    case WM_HIT_MAXIMIZE:
        if (P.wm_idx >= 0 && P.wm_idx < P.ntasks) {
            zwlr_foreign_toplevel_handle_v1_set_maximized(P.tasks[P.wm_idx].handle);
            wm_close();
        }
        break;
    case QS_HIT_OVERVIEW: P.want_overview = 1; P.want_qs_toggle = 1; break;
    case QS_HIT_SHOT:     P.want_shot = 1;     P.want_qs_toggle = 1; break;
    }
}

/* Input tracing (IOSC_SHELL_DEBUG=1): stderr lands in $XDG_RUNTIME_DIR/<client>.log
 * via run-shell.sh, so a dead-to-taps report can be diagnosed from the log —
 * it shows whether events arrive at all, with what coords, and what they hit. */
static int pdbg(void)
{
    static int on = -1;
    if (on < 0) { const char *e = getenv("IOSC_SHELL_DEBUG"); on = e && *e && *e != '0'; }
    return on;
}

static void hit_at(struct wl_surface *sf, int x, int y)
{
    const struct panel_hits *hs = sf == P.qs_surf && P.qs_surf ? &P.qs_hits : &P.hits;
    /* x,y are logical (surface-local); the hit table is in reference space */
    int rx = pl_to_ref(x), ry = pl_to_ref(y);
    int i = pl_hit_test(hs, rx, ry);
    if (pdbg())
        fprintf(stderr, "%s: hit_at %s logical(%d,%d) ref(%d,%d) ui=%.3f -> %d "
                "(kind=%d idx=%d) of %d rects\n",
                mode_name(), sf == P.qs_surf ? "qs" : mode_name(), x, y, rx, ry, pl_ui(), i,
                i >= 0 ? hs->v[i].kind : -1, i >= 0 ? hs->v[i].idx : -1, hs->n);
    if (i >= 0) act_on_hit(&hs->v[i]);
}

static int dock_launch_hit_at(int x, int y)
{
    if (P.mode != MODE_DOCK || P.nlaunch <= 0) return -1;
    int rx = pl_to_ref(x), ry = pl_to_ref(y);
    for (int i = P.hits.n - 1; i >= 0; i--) {
        const struct panel_hit *r = &P.hits.v[i];
        if (r->kind != PL_HIT_LAUNCH) continue;
        if (rx >= r->x && rx < r->x + r->w && ry >= r->y && ry < r->y + r->h)
            return r->idx;
    }
    return -1;
}

static void dock_reorder_motion(int x, int y)
{
    if (!P.reorder_active) return;
    P.reorder_x = x; P.reorder_y = y;
    int target = dock_launch_hit_at(x, y);
    if (target >= 0 && target != P.reorder_idx) {
        dock_move_launcher(P.reorder_idx, target);
        P.press_kind = PL_HIT_LAUNCH;
        P.press_idx = P.reorder_idx;
        render();
    }
}

static void dock_reorder_finish(int save)
{
    if (!P.reorder_active) return;
    if (save) dock_save_order();
    P.reorder_active = 0;
    P.reorder_idx = P.reorder_target = -1;
    P.press_kind = P.press_idx = 0;
    render();
}

static void dock_maybe_begin_reorder(void)
{
    if (P.reorder_active || P.mode != MODE_DOCK || P.touch_surf != P.surf) return;
    if (P.press_kind != PL_HIT_LAUNCH || P.press_idx < 0 || P.press_idx >= P.nlaunch) return;
    if (mono_ms() - P.press_ms < DOCK_REORDER_HOLD_MS) return;
    P.reorder_active = 1;
    P.reorder_idx = P.reorder_target = P.press_idx;
    P.reorder_x = P.px; P.reorder_y = P.py;
    P.touch_moved = 1;
    render();
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

static void ptr_update_hover(struct wl_surface *sf)
{
    const struct panel_hits *hs = (P.qs_surf && sf == P.qs_surf) ? &P.qs_hits : &P.hits;
    int i = P.have_ptr ? pl_hit_test(hs, pl_to_ref(P.px), pl_to_ref(P.py)) : -1;
    P.ptr_kind = i >= 0 ? hs->v[i].kind : -1;
    P.ptr_idx = i >= 0 ? hs->v[i].idx : -1;
}

static void pt_enter(void *d, struct wl_pointer *p, uint32_t s, struct wl_surface *sf, wl_fixed_t x, wl_fixed_t y)
{
    (void)d;(void)p;(void)s;
    P.ptr_surf=sf; P.have_ptr=1; P.px=wl_fixed_to_int(x); P.py=wl_fixed_to_int(y);
    ptr_update_hover(sf);
    if (pdbg()) fprintf(stderr, "%s: pt_enter %s (%d,%d)\n",
                        mode_name(), sf == P.qs_surf ? "qs" : mode_name(), P.px, P.py);
    rerender_for(sf);
}
static void pt_leave(void *d, struct wl_pointer *p, uint32_t s, struct wl_surface *sf)
{ (void)d;(void)p;(void)s; P.have_ptr=0; P.ptr_surf=NULL; P.ptr_kind=-1; P.ptr_idx=-1; rerender_for(sf); }
static void pt_motion(void *d, struct wl_pointer *p, uint32_t t, wl_fixed_t x, wl_fixed_t y)
{
    (void)d;(void)p;(void)t;
    struct wl_surface *sf = P.ptr_surf;
    int old_kind = P.ptr_kind, old_idx = P.ptr_idx;
    P.px=wl_fixed_to_int(x); P.py=wl_fixed_to_int(y);
    if (!sf) return;
    ptr_update_hover(sf);
    if (P.ptr_kind != old_kind || P.ptr_idx != old_idx) rerender_for(sf);
}
static void pt_button(void *d, struct wl_pointer *p, uint32_t serial, uint32_t t, uint32_t button, uint32_t state)
{
    (void)d;(void)p;(void)serial;(void)t;
    if (pdbg()) fprintf(stderr, "%s: pt_button 0x%x state=%u surf=%s at (%d,%d)\n",
                        mode_name(), button, state, P.ptr_surf ? "yes" : "NULL", P.px, P.py);
    if (state != WL_POINTER_BUTTON_STATE_PRESSED || button != 0x110 /*BTN_LEFT*/) return;
    P.input_time = t;
    if (P.last_touch_up_time && t - P.last_touch_up_time < 450) {
        if (pdbg()) fprintf(stderr, "%s: suppress synthetic pointer after touch dt=%u\n",
                            mode_name(), t - P.last_touch_up_time);
        return;
    }
    if (P.ptr_surf) { wm_dismiss_on_other_tap(P.ptr_surf); hit_at(P.ptr_surf, P.px, P.py); }
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
/* Finger down = press feedback; short tap acts; intentional swipes trigger shell gestures. */

static void tc_down(void *d, struct wl_touch *t, uint32_t serial, uint32_t time,
                    struct wl_surface *sf, int32_t id, wl_fixed_t x, wl_fixed_t y)
{
    (void)d;(void)t;(void)serial;(void)time;
    if (P.touch_surf) return;                    /* single-touch UI */
    P.touch_surf = sf; P.touch_id = id;
    P.input_time = time;
    P.press_ms = mono_ms();
    P.px = wl_fixed_to_int(x); P.py = wl_fixed_to_int(y);
    P.touch_x0 = P.px; P.touch_y0 = P.py; P.touch_moved = 0;
    const struct panel_hits *hs = (P.qs_surf && sf == P.qs_surf) ? &P.qs_hits : &P.hits;
    int i = pl_hit_test(hs, pl_to_ref(P.px), pl_to_ref(P.py));
    if (pdbg()) fprintf(stderr, "%s: tc_down id=%d %s logical(%d,%d) ui=%.3f -> press %d\n",
                        mode_name(), id, sf == P.qs_surf ? "qs" : mode_name(), P.px, P.py, pl_ui(), i);
    if (i >= 0) { P.press_kind = hs->v[i].kind; P.press_idx = hs->v[i].idx; }
    rerender_for(sf);
}
static void tc_up(void *d, struct wl_touch *t, uint32_t serial, uint32_t time, int32_t id)
{
    (void)d;(void)t;(void)serial;(void)time;
    if (!P.touch_surf || id != P.touch_id) return;
    if (P.reorder_active) {
        P.touch_surf = NULL;
        P.last_touch_up_time = time;
        dock_reorder_finish(1);
        return;
    }
    struct wl_surface *sf = P.touch_surf;
    P.input_time = time;
    P.last_touch_up_time = time;
    int dx = P.px - P.touch_x0, dy = P.py - P.touch_y0;
    int adx = dx < 0 ? -dx : dx, ady = dy < 0 ? -dy : dy;
    P.touch_surf = NULL; P.press_kind = 0; P.press_idx = 0;
    /* 34 is tuned in reference px (like the hit rects); scale by ui so the
     * on-glass swipe distance stays -logical-invariant. */
    int swipe_min = (int)lround(34 * pl_ui());
    if (ady >= swipe_min && ady > adx * 2) {
        if (sf == P.surf && P.mode == MODE_DOCK && dy < 0) {
            P.want_overview = 1;
            if (pdbg()) fprintf(stderr, "%s: gesture dock swipe up -> overview\n", mode_name());
        } else if (sf == P.surf && P.mode == MODE_BAR && dy > 0) {
            P.want_qs_toggle = 1;
            if (pdbg()) fprintf(stderr, "%s: gesture status swipe down -> quick settings\n", mode_name());
        } else if (sf == P.qs_surf && dy < 0) {
            P.want_qs_toggle = 1;
            if (pdbg()) fprintf(stderr, "%s: gesture qs swipe up -> close\n", mode_name());
        }
    } else if (!P.touch_moved) {
        wm_dismiss_on_other_tap(sf);
        hit_at(sf, P.px, P.py);
    } else if (pdbg()) {
        fprintf(stderr, "%s: touch ended after drag dx=%d dy=%d -> no tap\n", mode_name(), dx, dy);
    }
    rerender_for(sf);
}
static void tc_motion(void *d, struct wl_touch *t, uint32_t time, int32_t id, wl_fixed_t x, wl_fixed_t y)
{
    (void)d;(void)t;(void)time;
    if (P.touch_surf && id == P.touch_id) {
        P.px=wl_fixed_to_int(x); P.py=wl_fixed_to_int(y);
        if (P.reorder_active) {
            dock_reorder_motion(P.px, P.py);
            return;
        }
        int dx = P.px - P.touch_x0, dy = P.py - P.touch_y0;
        int slop = (int)lround(10 * pl_ui());   /* tap-cancel slop, reference px */
        if ((dx < 0 ? -dx : dx) > slop || (dy < 0 ? -dy : dy) > slop) {
            P.touch_moved = 1;
            if (P.press_kind && !(P.mode == MODE_DOCK && P.touch_surf == P.surf &&
                                  P.press_kind == PL_HIT_LAUNCH)) {
                P.press_kind = 0; P.press_idx = 0; rerender_for(P.touch_surf);
            }
        }
    }
}
static void tc_frame(void *d, struct wl_touch *t){ (void)d;(void)t; }
static void tc_cancel(void *d, struct wl_touch *t)
{
    (void)d;(void)t;
    if (P.reorder_active) dock_reorder_finish(0);
    struct wl_surface *sf = P.touch_surf;
    P.touch_surf=NULL; P.press_kind=0; P.press_idx=0;
    if (sf) rerender_for(sf);
}
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
    if (pdbg()) fprintf(stderr, "%s: seat caps=0x%x (ptr=%d touch=%d)\n",
                        mode_name(), caps, !!(caps & WL_SEAT_CAPABILITY_POINTER),
                        !!(caps & WL_SEAT_CAPABILITY_TOUCH));
    if ((caps & WL_SEAT_CAPABILITY_POINTER) && !P.ptr) {
        P.ptr = wl_seat_get_pointer(s); wl_pointer_add_listener(P.ptr, &pointer_listener, NULL);
    }
    if ((caps & WL_SEAT_CAPABILITY_TOUCH) && !P.touch) {
        P.touch = wl_seat_get_touch(s); wl_touch_add_listener(P.touch, &touch_listener, NULL);
    }
}
static void seat_name(void *d, struct wl_seat *s, const char *n){ (void)d;(void)s;(void)n; }
static const struct wl_seat_listener seat_listener = { .capabilities = seat_caps, .name = seat_name };

/* ------------------------------------------------------------- output ---- */
/* Follow the compositor's output scale so the panel renders crisp at ANY DPI
 * (iosc's supersampled desktop is scale 2 over a 1440x1080 logical output;
 * a different device/output just sends a different factor). IOSC_PANEL_SCALE
 * stays as an explicit override. Logical SIZE already tracks the output via
 * the layer-surface configure. */
static void out_geometry(void *d, struct wl_output *o, int32_t x, int32_t y,
                         int32_t pw, int32_t ph, int32_t sp,
                         const char *mk, const char *md, int32_t tr)
{ (void)d;(void)o;(void)x;(void)y;(void)pw;(void)ph;(void)sp;(void)mk;(void)md;(void)tr; }
static void out_mode(void *d, struct wl_output *o, uint32_t f, int32_t w, int32_t h, int32_t r)
{ (void)d;(void)o;(void)f;(void)w;(void)h;(void)r; }
static void out_done(void *d, struct wl_output *o){ (void)d;(void)o; }
static void out_scale(void *d, struct wl_output *o, int32_t f)
{
    (void)d;(void)o;
    if (P.scale_env || f <= 0 || f == P.scale) return;
    P.scale = (int)f;
    render();
    render_qs();
}
static const struct wl_output_listener output_listener = {
    .geometry = out_geometry, .mode = out_mode, .done = out_done, .scale = out_scale,
};

/* ------------------------------------------------------- layer surface --- */

static void layer_configure(void *d, struct zwlr_layer_surface_v1 *ls, uint32_t serial, uint32_t w, uint32_t h)
{
    (void)d; (void)h;   /* height is derived from ui, not taken from configure */
    if (w) P.width = (int)w;
    zwlr_layer_surface_v1_ack_configure(ls, serial);

    /* Scale the surface's logical HEIGHT so its on-glass size is constant: the
     * output width sets ui, and each role owns a fixed reference height. */
    P.ui = P.width > 0 ? (double)P.width / PL_REF_W : 1.0;
    int want = (int)lround(mode_ref_h() * pl_ui());
    if (want != P.req_h) {
        P.req_h = want;
        zwlr_layer_surface_v1_set_size(P.layer, 0, (uint32_t)want);
        zwlr_layer_surface_v1_set_exclusive_zone(P.layer, want);
    }
    P.height = want;
    if (pdbg()) fprintf(stderr, "%s: configure w=%u -> ui=%.3f surface_h=%d\n",
                        mode_name(), w, pl_ui(), want);
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
    else if (!strcmp(iface, wl_output_interface.name) && !P.output) {
        P.output = wl_registry_bind(r, name, &wl_output_interface, ver < 2 ? ver : 2);
        if (ver >= 2) wl_output_add_listener(P.output, &output_listener, NULL);
    } else if (!strcmp(iface, wl_seat_interface.name)) {
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

static void poll_status(void)
{
    int pct, chg;
    if (st_battery(&pct, &chg)) { P.batt_pct = pct; P.batt_charging = chg; }
    else P.batt_pct = -1;
    P.net_kind = st_network();
    P.wifi_on = P.net_kind == ST_NET_WIFI;
}

int main(int argc, char **argv)
{
    signal(SIGCHLD, SIG_IGN);
    memset(&P, 0, sizeof P);
    P.mode = MODE_UNKNOWN;
    P.ptr_kind = -1; P.ptr_idx = -1;
    P.last_launch_idx = -1;
    P.reorder_idx = P.reorder_target = -1;
    if (argc > 0) {
        char btmp[512]; snprintf(btmp, sizeof btmp, "%s", argv[0]);
        char *bn = basename(btmp);
        if (strstr(bn, "ioscbar")) P.mode = MODE_BAR;
        else if (strstr(bn, "ioscdock")) P.mode = MODE_DOCK;
    }
    if (P.mode == MODE_UNKNOWN) {
        fprintf(stderr, "iosc-shell: run as ioscbar or ioscdock\n");
        return 2;
    }
    P.width = PL_REF_W; P.height = mode_ref_h(); P.scale = 2; P.running = 1;
    P.ui = 1.0; P.req_h = mode_ref_h();
    P.batt_pct = -1;
    P.bg_alpha = 0.85;  /* translucent over the wallpaper (iosc blends layer
                         * surfaces since e11aa52); IOSC_PANEL_OPACITY overrides */
    const char *es = getenv("IOSC_PANEL_SCALE");
    if (es && atoi(es) > 0) { P.scale = atoi(es); P.scale_env = 1; }
    const char *op = getenv("IOSC_PANEL_OPACITY");   /* 0..100 */
    if (op && atoi(op) > 0) P.bg_alpha = atoi(op) / 100.0;

    /* remember our dir so the ⊞ button can spawn a sibling ioscoverview */
    if (argc > 0 && strchr(argv[0], '/')) {
        char tmp[512]; snprintf(tmp, sizeof tmp, "%s", argv[0]);
        snprintf(P.self_dir, sizeof P.self_dir, "%s", dirname(tmp));
    } else sd_join_path(P.self_dir, sizeof P.self_dir, sd_jbroot(), "/usr/local/bin");

    P.dpy = wl_display_connect(NULL);
    if (!P.dpy) { fprintf(stderr, "%s: cannot connect to WAYLAND_DISPLAY\n", mode_name()); return 1; }
    struct wl_registry *reg = wl_display_get_registry(P.dpy);
    wl_registry_add_listener(reg, &registry_listener, NULL);
    wl_display_roundtrip(P.dpy);
    wl_display_roundtrip(P.dpy);

    if (!P.comp || !P.shm) { fprintf(stderr, "%s: missing wl_compositor/wl_shm\n", mode_name()); return 1; }
    if (!P.layer_shell) {
        fprintf(stderr, "%s: compositor lacks zwlr_layer_shell_v1 — cannot map shell chrome. "
                        "(iosc must implement it; see iosc-shell.md)\n", mode_name());
        return 2;
    }

    P.nlaunch = sd_scan_apps(P.launch, LAUNCH_MAX);
    dock_apply_saved_order();
    for (int i = 0; i < P.nlaunch; i++)
        P.launch_icon[i] = load_icon(P.launch[i].icon[0] ? P.launch[i].icon : P.launch[i].name);
    poll_status();
    /* Version banner: confirms WHICH panel binary is live on device (a
     * "looks like the old panel" report is usually a stale process). */
    fprintf(stderr, "%s " IOSC_SHELL_VER ": %s, opacity=%d%% "
            "(translucency needs iosc>=0.9.1 blend)\n", mode_name(),
            P.mode == MODE_BAR ? "tablet status bar"
            : P.mode == MODE_DOCK ? "tablet dock"
            : "tablet panel",
            (int)lround(P.bg_alpha * 100));
    fprintf(stderr, "%s: %d launcher(s), foreign-toplevel=%s, screencopy=%s, battery=%s, network=%s\n",
            mode_name(), P.nlaunch, P.ftm ? "yes" : "no (taskbar disabled)",
            P.scm ? "yes" : "no (QS backdrop/screenshot off)",
            P.batt_pct >= 0 ? "yes" : "no",
            P.net_kind == ST_NET_WIFI ? "wifi" :
            P.net_kind == ST_NET_CELLULAR ? "cellular" : "none");

    P.surf  = wl_compositor_create_surface(P.comp);
    P.layer = zwlr_layer_shell_v1_get_layer_surface(P.layer_shell, P.surf, NULL,
                ZWLR_LAYER_SHELL_V1_LAYER_TOP, mode_name());
    zwlr_layer_surface_v1_add_listener(P.layer, &layer_listener, NULL);
    uint32_t anchor = ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT |
                      ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT |
                      (P.mode == MODE_DOCK ? ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM
                                           : ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP);
    zwlr_layer_surface_v1_set_anchor(P.layer, anchor);
    zwlr_layer_surface_v1_set_size(P.layer, 0, (uint32_t)P.req_h);
    zwlr_layer_surface_v1_set_exclusive_zone(P.layer, P.req_h);
    zwlr_layer_surface_v1_set_keyboard_interactivity(P.layer, 0);
    wl_surface_commit(P.surf);

    int wfd = wl_display_get_fd(P.dpy);
    int last_min = -1;
    while (P.running) {
        while (wl_display_prepare_read(P.dpy) != 0) wl_display_dispatch_pending(P.dpy);
        wl_display_flush(P.dpy);
        time_t now = time(NULL);
        int to_ms = (int)(60 - (now % 60)) * 1000;   /* wake at the next minute */
        if (P.touch_surf == P.surf && P.mode == MODE_DOCK && P.press_kind == PL_HIT_LAUNCH)
            to_ms = to_ms < 50 ? to_ms : 50;
        struct pollfd pfd = { .fd = wfd, .events = POLLIN };
        int n = poll(&pfd, 1, to_ms);
        if (n < 0 && errno != EINTR) { wl_display_cancel_read(P.dpy); break; }
        if (n > 0 && (pfd.revents & POLLIN)) wl_display_read_events(P.dpy);
        else wl_display_cancel_read(P.dpy);
        wl_display_dispatch_pending(P.dpy);
        dock_maybe_begin_reorder();

        /* deferred actions (safe here: outside any listener) */
        if (P.want_qs_toggle) {
            P.want_qs_toggle = 0;
            if (P.qs_surf) qs_close(); else { if (P.wm_surf) wm_close(); qs_open(); }
        }
        if (P.want_wm_toggle) {
            P.want_wm_toggle = 0;
            if (P.wm_surf) wm_close();
            else {
                int idx = -1;
                for (int i = 0; i < P.ntasks; i++)
                    if (P.tasks[i].activated || (idx < 0 && P.tasks[i].handle)) idx = i;
                if (idx >= 0) wm_open(idx);
            }
        }
        if (P.want_shot)     { P.want_shot = 0; wl_display_roundtrip(P.dpy); take_screenshot(); }
        if (P.want_overview) { P.want_overview = 0; spawn_overview(); }

        struct tm tm; time_t t2 = time(NULL); localtime_r(&t2, &tm);
        if (tm.tm_min != last_min) {
            last_min = tm.tm_min;
            poll_status();
            render();
        }
    }
    sd_cairo_pool_destroy(&P.surface_pool);
    sd_cairo_pool_destroy(&P.qs_pool);
    sd_cairo_pool_destroy(&P.wm_pool);
    wl_display_disconnect(P.dpy);
    return 0;
}

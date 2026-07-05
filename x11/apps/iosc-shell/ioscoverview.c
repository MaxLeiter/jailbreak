/*
 * ioscoverview — the launcher + window switcher for the iosc desktop shell.
 *
 * A full-screen zwlr_layer_shell_v1 OVERLAY client drawn with cairo/pango
 * (overview-layout.h): the live desktop is captured via zwlr_screencopy the
 * instant before the surface maps, frosted client-side (shell-blur.h), and
 * used as the backdrop under a dim scrim — the iPadOS "materialize" look with
 * zero compositor changes. On top: a centered search pill (type to filter,
 * Enter launches the first match), a row of open-window chips
 * (zwlr_foreign_toplevel_management_v1: tap raises, × closes), and the app
 * grid from .desktop scan with real icons (panel-icons.h).
 *
 * Input: pointer (hover + click + wheel scroll), touch (press feedback, tap,
 * drag-to-scroll with a slop threshold), keyboard (evdev codes from iosc's xkb
 * seat: type to search, Backspace, Enter, Escape dismisses). Tapping empty
 * space dismisses. Each invocation is a fresh process that exits on dismiss;
 * the panel's ⊞ button (or its QS "Overview" action) spawns it.
 *
 * Build: build-panel.sh. Needs iosc's zwlr_layer_shell_v1.
 */
#define _GNU_SOURCE
#define SD_APP_SCAN
#define SD_DESKTOP_PINNING
#define SD_CAIRO                   /* sd_cairo_pool from shell-draw.h */
#include "shell-draw.h"
#include "shell-theme.h"
#include "overview-layout.h"
#include "panel-icons.h"
#include "shell-blur.h"
#include "wlr-layer-shell-unstable-v1-client-protocol.h"
#include "wlr-foreign-toplevel-management-unstable-v1-client-protocol.h"
#include "wlr-screencopy-unstable-v1-client-protocol.h"
#include "shell-screencopy.h"

#include <poll.h>
#include <errno.h>
#include <signal.h>
#include <ctype.h>
#include <time.h>

#define IOSCOVERVIEW_VER "0.9.7"
#define APP_MAX   OV_MAX_APPS
#define WIN_MAX   OV_MAX_WINS
#define APP_PIN_HOLD_MS 540

/* IOSC_SHELL_DEBUG=1 -> trace to $XDG_RUNTIME_DIR/ioscoverview.log */
static int ovdbg(void)
{ static int on=-1; if(on<0){ const char*e=getenv("IOSC_SHELL_DEBUG"); on=e&&*e&&*e!='0'; } return on; }

struct win_item {
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
    struct wl_keyboard   *kbd;
    struct wl_output     *output;
    struct zwlr_layer_shell_v1 *layer_shell;
    struct zwlr_foreign_toplevel_manager_v1 *ftm;
    struct zwlr_screencopy_manager_v1 *scm;
    int    scm_version;
    struct wl_surface    *surf;
    struct zwlr_layer_surface_v1 *layer;
    struct sd_cairo_pool surface_pool;

    int   width, height, scale, scale_env, configured, running;
    int   px, py, have_ptr;
    int   ptr_kind, ptr_idx;
    int   press_kind, press_idx;
    int   touch_active, touch_id, touch_drag, touch_moved;
    int   touch_x0, touch_y0, drag_scroll0;
    uint64_t press_ms;
    int   long_press_done;
    int   scroll_y;
    double anim_t;

    char  query[64];

    struct sd_app  apps[APP_MAX];
    cairo_surface_t *app_icon[APP_MAX];
    int   napps;
    int   fmap[APP_MAX];              /* filtered index -> apps[] index */
    int   nfiltered;

    struct win_item wins[WIN_MAX];
    int   nwins;

    cairo_surface_t *backdrop;        /* pre-blurred desktop capture */
    struct ov_hits hits;
} O;

static uint64_t mono_ms(void)
{
    return sd_mono_ms();
}

/* case-insensitive substring */
static int ci_match(const char *hay, const char *needle)
{
    if (!needle[0]) return 1;
    size_t nl = strlen(needle);
    for (const char *p = hay; *p; p++) {
        size_t i = 0;
        while (i < nl && p[i] &&
               tolower((unsigned char)p[i]) == tolower((unsigned char)needle[i])) i++;
        if (i == nl) return 1;
    }
    return 0;
}

static void refilter(void)
{
    O.nfiltered = 0;
    for (int i = 0; i < O.napps; i++)
        if (ci_match(O.apps[i].name, O.query))
            O.fmap[O.nfiltered++] = i;
}

/* ------------------------------------------------------------- rendering -- */

static void build_model(struct ov_model *m)
{
    memset(m, 0, sizeof *m);
    m->backdrop = O.backdrop;
    m->have_ptr = O.have_ptr; m->px = O.px; m->py = O.py;
    m->press_kind = O.press_kind; m->press_idx = O.press_idx;
    m->scroll_y = O.scroll_y;
    m->anim_t = O.anim_t;
    snprintf(m->query, sizeof m->query, "%s", O.query);
    m->searching = O.query[0] != 0;

    m->napps = O.nfiltered;
    for (int i = 0; i < O.nfiltered; i++) {
        const struct sd_app *a = &O.apps[O.fmap[i]];
        snprintf(m->apps[i].label, sizeof m->apps[i].label, "%s", a->name);
        snprintf(m->apps[i].key,   sizeof m->apps[i].key,   "%s", a->name);
        m->apps[i].icon = O.app_icon[O.fmap[i]];
    }
    m->nwins = O.nwins;
    for (int i = 0; i < O.nwins; i++) {
        snprintf(m->wins[i].label, sizeof m->wins[i].label, "%s",
                 O.wins[i].title[0] ? O.wins[i].title : "Window");
        snprintf(m->wins[i].key, sizeof m->wins[i].key, "%s",
                 O.wins[i].title[0] ? O.wins[i].title : O.wins[i].app_id);
        m->wins[i].icon = O.wins[i].icon;
        m->wins[i].active = O.wins[i].activated;
    }
}

static void clamp_scroll(void)
{
    int max = ov_content_height(O.nfiltered, O.nwins, O.query[0] != 0, O.width)
              - (O.height - OV_SECT_TOP) + 24;
    if (max < 0) max = 0;
    if (O.scroll_y > max) O.scroll_y = max;
    if (O.scroll_y < 0)   O.scroll_y = 0;
}

static void render(void)
{
    if (!O.configured) return;
    cairo_t *cr; cairo_surface_t *surf;
    struct sd_cairo_slot *slot = sd_cairo_pool_begin(&O.surface_pool, O.shm,
                                                     O.width, O.height, O.scale,
                                                     &cr, &surf);
    struct wl_buffer *buf = slot ? slot->buffer : NULL;
    if (!buf) return;

    pr_text_ctx t = pr_text_ctx_new(cr);
    struct ov_model m;
    build_model(&m);
    ov_draw(cr, &t, O.width, O.height, &m, &O.hits);
    pr_text_ctx_free(&t);

    cairo_surface_flush(surf);
    cairo_destroy(cr);
    cairo_surface_destroy(surf);

    wl_surface_set_buffer_scale(O.surf, O.scale);
    wl_surface_attach(O.surf, buf, 0, 0);
    wl_surface_damage_buffer(O.surf, 0, 0, O.width * O.scale, O.height * O.scale);
    wl_surface_commit(O.surf);
}

/* --------------------------------------------------------------- actions -- */

static void act_on_hit(const struct ov_hit *r)
{
    switch (r->kind) {
    case OV_HIT_APP:
        if (r->idx < O.nfiltered) { sd_launch(O.apps[O.fmap[r->idx]].exec); O.running = 0; }
        break;
    case OV_HIT_WIN:
        if (r->idx < O.nwins && O.wins[r->idx].handle) {
            zwlr_foreign_toplevel_handle_v1_activate(O.wins[r->idx].handle, O.seat);
            O.running = 0;
        }
        break;
    case OV_HIT_WINCLOSE:
        if (r->idx < O.nwins && O.wins[r->idx].handle)
            zwlr_foreign_toplevel_handle_v1_close(O.wins[r->idx].handle);
        break;                          /* stay open; closed event re-renders */
    case OV_HIT_BG:
        O.running = 0;
        break;
    }
}

/* ----------------------------------------------------- foreign-toplevel -- */

static struct win_item *win_for(struct zwlr_foreign_toplevel_handle_v1 *h)
{
    for (int i = 0; i < O.nwins; i++) if (O.wins[i].handle == h) return &O.wins[i];
    return NULL;
}
static void ft_title(void *d, struct zwlr_foreign_toplevel_handle_v1 *h, const char *t)
{ (void)d; struct win_item *w = win_for(h); if (w) snprintf(w->title, sizeof w->title, "%s", t?t:""); }
static void ft_app_id(void *d, struct zwlr_foreign_toplevel_handle_v1 *h, const char *a)
{
    (void)d; struct win_item *w = win_for(h); if (!w || !a) return;
    snprintf(w->app_id, sizeof w->app_id, "%s", a);
    if (!w->icon_tried) { w->icon_tried = 1; w->icon = pi_load_surface(a, O.scale); }
}
static void ft_out_enter(void *d, struct zwlr_foreign_toplevel_handle_v1 *h, struct wl_output *o){ (void)d;(void)h;(void)o; }
static void ft_out_leave(void *d, struct zwlr_foreign_toplevel_handle_v1 *h, struct wl_output *o){ (void)d;(void)h;(void)o; }
static void ft_state(void *d, struct zwlr_foreign_toplevel_handle_v1 *h, struct wl_array *st)
{
    (void)d; struct win_item *w = win_for(h); if (!w) return;
    w->activated = 0; uint32_t *s;
    wl_array_for_each(s, st) if (*s == ZWLR_FOREIGN_TOPLEVEL_HANDLE_V1_STATE_ACTIVATED) w->activated = 1;
}
static void ft_done(void *d, struct zwlr_foreign_toplevel_handle_v1 *h){ (void)d;(void)h; render(); }
static void ft_closed(void *d, struct zwlr_foreign_toplevel_handle_v1 *h)
{
    (void)d;
    for (int i = 0; i < O.nwins; i++) if (O.wins[i].handle == h) {
        if (O.wins[i].icon) cairo_surface_destroy(O.wins[i].icon);
        zwlr_foreign_toplevel_handle_v1_destroy(h);
        for (int j = i; j < O.nwins-1; j++) O.wins[j] = O.wins[j+1];
        O.nwins--; break;
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
    if (O.nwins >= WIN_MAX) { zwlr_foreign_toplevel_handle_v1_destroy(h); return; }
    struct win_item *w = &O.wins[O.nwins++];
    memset(w, 0, sizeof *w); w->handle = h;
    zwlr_foreign_toplevel_handle_v1_add_listener(h, &ft_handle_listener, NULL);
}
static void ftm_finished(void *d, struct zwlr_foreign_toplevel_manager_v1 *m)
{ (void)d; zwlr_foreign_toplevel_manager_v1_destroy(m); O.ftm = NULL; }
static const struct zwlr_foreign_toplevel_manager_v1_listener ftm_listener = {
    .toplevel = ftm_toplevel, .finished = ftm_finished,
};

/* --------------------------------------------------------- input: pointer */

static void ptr_update_hover(void)
{
    int i = O.have_ptr ? ov_hit_test(&O.hits, O.px, O.py) : -1;
    O.ptr_kind = i >= 0 ? O.hits.v[i].kind : -1;
    O.ptr_idx = i >= 0 ? O.hits.v[i].idx : -1;
}

static void pt_enter(void *d, struct wl_pointer *p, uint32_t s, struct wl_surface *sf, wl_fixed_t x, wl_fixed_t y)
{ (void)d;(void)p;(void)s;(void)sf; O.have_ptr=1; O.px=wl_fixed_to_int(x); O.py=wl_fixed_to_int(y); ptr_update_hover(); render(); }
static void pt_leave(void *d, struct wl_pointer *p, uint32_t s, struct wl_surface *sf)
{ (void)d;(void)p;(void)s;(void)sf; O.have_ptr=0; O.ptr_kind=-1; O.ptr_idx=-1; render(); }
static void pt_motion(void *d, struct wl_pointer *p, uint32_t t, wl_fixed_t x, wl_fixed_t y)
{
    (void)d;(void)p;(void)t;
    int old_kind = O.ptr_kind, old_idx = O.ptr_idx;
    O.px=wl_fixed_to_int(x); O.py=wl_fixed_to_int(y);
    ptr_update_hover();
    if (O.ptr_kind != old_kind || O.ptr_idx != old_idx) render();
}
static void pt_button(void *d, struct wl_pointer *p, uint32_t serial, uint32_t t, uint32_t button, uint32_t state)
{
    (void)d;(void)p;(void)serial;(void)t;
    if (state != WL_POINTER_BUTTON_STATE_PRESSED || button != 0x110) return;
    int i = ov_hit_test(&O.hits, O.px, O.py);
    if (i >= 0) act_on_hit(&O.hits.v[i]);
}
static void pt_axis(void *d, struct wl_pointer *p, uint32_t t, uint32_t a, wl_fixed_t v)
{
    (void)d;(void)p;(void)t;
    if (a != WL_POINTER_AXIS_VERTICAL_SCROLL) return;
    int old_scroll = O.scroll_y;
    O.scroll_y += wl_fixed_to_int(v) * 3;
    clamp_scroll();
    if (O.scroll_y != old_scroll) render();
}
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

/* ----------------------------------------------------------- input: touch */
/* Tap = press feedback + act on up. Movement past the slop in either axis
 * cancels the tap (press feedback clears); a vertical drag also scrolls the
 * grid. */
#define TOUCH_SLOP 8

static void tc_down(void *d, struct wl_touch *t, uint32_t serial, uint32_t time,
                    struct wl_surface *sf, int32_t id, wl_fixed_t x, wl_fixed_t y)
{
    (void)d;(void)t;(void)serial;(void)time;(void)sf;
    if (O.touch_active) return;
    O.touch_active = 1; O.touch_id = id; O.touch_drag = 0; O.touch_moved = 0;
    O.long_press_done = 0; O.press_ms = mono_ms();
    O.px = wl_fixed_to_int(x); O.py = wl_fixed_to_int(y);
    O.touch_x0 = O.px; O.touch_y0 = O.py; O.drag_scroll0 = O.scroll_y;
    int i = ov_hit_test(&O.hits, O.px, O.py);
    if (i >= 0 && O.hits.v[i].kind != OV_HIT_BG) {
        O.press_kind = O.hits.v[i].kind; O.press_idx = O.hits.v[i].idx;
    }
    render();
}
static void tc_motion(void *d, struct wl_touch *t, uint32_t time, int32_t id, wl_fixed_t x, wl_fixed_t y)
{
    (void)d;(void)t;(void)time;
    if (!O.touch_active || id != O.touch_id) return;
    O.px = wl_fixed_to_int(x); O.py = wl_fixed_to_int(y);
    int dx = O.px - O.touch_x0, dy = O.py - O.touch_y0;
    int adx = dx < 0 ? -dx : dx, ady = dy < 0 ? -dy : dy;
    int need_render = 0;
    if (!O.touch_moved && (adx > TOUCH_SLOP || ady > TOUCH_SLOP)) {
        O.touch_moved = 1;                      /* movement: not a tap */
        O.press_kind = 0; O.press_idx = 0;
        need_render = 1;
    }
    if (!O.touch_drag && ady > TOUCH_SLOP)
        O.touch_drag = 1;                       /* vertical drag scrolls */
    if (O.touch_drag) {
        int old_scroll = O.scroll_y;
        O.scroll_y = O.drag_scroll0 - dy;
        clamp_scroll();
        if (O.scroll_y != old_scroll) need_render = 1;
    }
    if (need_render) render();
}

static void maybe_pin_pressed_app(void)
{
    if (!O.touch_active || O.long_press_done || O.press_kind != OV_HIT_APP) return;
    if (O.press_idx < 0 || O.press_idx >= O.nfiltered) return;
    if (mono_ms() - O.press_ms < APP_PIN_HOLD_MS) return;
    int app_idx = O.fmap[O.press_idx];
    if (app_idx >= 0 && app_idx < O.napps) {
        sd_pin_app_to_desktop(&O.apps[app_idx]);
        if (ovdbg()) fprintf(stderr, "ioscoverview: pinned %s to desktop\n", O.apps[app_idx].name);
    }
    O.long_press_done = 1;
    O.touch_moved = 1;
    O.press_kind = 0; O.press_idx = 0;
    render();
}

static void tc_up(void *d, struct wl_touch *t, uint32_t serial, uint32_t time, int32_t id)
{
    (void)d;(void)t;(void)serial;(void)time;
    if (!O.touch_active || id != O.touch_id) return;
    int moved = O.touch_moved;
    O.touch_active = 0; O.touch_drag = 0; O.touch_moved = 0;
    O.press_kind = 0; O.press_idx = 0;
    if (!moved && !O.long_press_done) {
        int i = ov_hit_test(&O.hits, O.px, O.py);
        if (i >= 0) act_on_hit(&O.hits.v[i]);
    }
    O.long_press_done = 0;
    render();
}
static void tc_frame(void *d, struct wl_touch *t){ (void)d;(void)t; }
static void tc_cancel(void *d, struct wl_touch *t)
{ (void)d;(void)t; O.touch_active=0; O.touch_drag=0; O.touch_moved=0; O.press_kind=0; O.press_idx=0; render(); }
static void tc_shape(void *d, struct wl_touch *t, int32_t id, wl_fixed_t maj, wl_fixed_t min)
{ (void)d;(void)t;(void)id;(void)maj;(void)min; }
static void tc_orient(void *d, struct wl_touch *t, int32_t id, wl_fixed_t o)
{ (void)d;(void)t;(void)id;(void)o; }
static const struct wl_touch_listener touch_listener = {
    .down = tc_down, .up = tc_up, .motion = tc_motion, .frame = tc_frame,
    .cancel = tc_cancel, .shape = tc_shape, .orientation = tc_orient,
};

/* -------------------------------------------------------- input: keyboard */
/* iosc's seat delivers evdev keycodes (its xkb keymap is plain US); a small
 * table covers type-to-search without pulling in libxkbcommon. */

static char evdev_char(uint32_t key)
{
    static const char *row1 = "1234567890";
    static const char *rowq = "qwertyuiop";
    static const char *rowa = "asdfghjkl";
    static const char *rowz = "zxcvbnm";
    if (key >= 2  && key <= 11) return row1[key - 2];
    if (key >= 16 && key <= 25) return rowq[key - 16];
    if (key >= 30 && key <= 38) return rowa[key - 30];
    if (key >= 44 && key <= 50) return rowz[key - 44];
    if (key == 57) return ' ';
    if (key == 12) return '-';
    if (key == 52) return '.';
    return 0;
}

static void kb_keymap(void *d, struct wl_keyboard *k, uint32_t fmt, int32_t fd, uint32_t sz)
{ (void)d;(void)k;(void)fmt;(void)sz; if (fd >= 0) close(fd); }
static void kb_enter(void *d, struct wl_keyboard *k, uint32_t s, struct wl_surface *sf, struct wl_array *keys)
{ (void)d;(void)k;(void)s;(void)sf;(void)keys; }
static void kb_leave(void *d, struct wl_keyboard *k, uint32_t s, struct wl_surface *sf){ (void)d;(void)k;(void)s;(void)sf; }
static void kb_key(void *d, struct wl_keyboard *k, uint32_t serial, uint32_t t, uint32_t key, uint32_t state)
{
    (void)d;(void)k;(void)serial;(void)t;
    if (state != WL_KEYBOARD_KEY_STATE_PRESSED) return;
    if (key == 1 /*ESC*/) { O.running = 0; return; }
    if (key == 14 /*BACKSPACE*/) {
        size_t n = strlen(O.query);
        if (n) { O.query[n-1] = 0; refilter(); O.scroll_y = 0; render(); }
        return;
    }
    if (key == 28 /*ENTER*/) {
        if (O.query[0] && O.nfiltered > 0) {
            sd_launch(O.apps[O.fmap[0]].exec);
            O.running = 0;
        }
        return;
    }
    char c = evdev_char(key);
    if (c) {
        size_t n = strlen(O.query);
        if (n + 1 < sizeof O.query) {
            O.query[n] = c; O.query[n+1] = 0;
            refilter(); O.scroll_y = 0; render();
        }
    }
}
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
    if ((caps & WL_SEAT_CAPABILITY_TOUCH) && !O.touch) {
        O.touch = wl_seat_get_touch(s); wl_touch_add_listener(O.touch, &touch_listener, NULL);
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
    if (ovdbg())
        fprintf(stderr, "ioscoverview: configure w=%u h=%u scale=%d -> buffer %dx%d "
                "(search pill centered in W=%d; expect w==logical output width)\n",
                w, h, O.scale, O.width*O.scale, O.height*O.scale, O.width);
    render();
}
static void layer_closed(void *d, struct zwlr_layer_surface_v1 *ls){ (void)d;(void)ls; O.running = 0; }
static const struct zwlr_layer_surface_v1_listener layer_listener = {
    .configure = layer_configure, .closed = layer_closed,
};

/* --------------------------------------------------------------- registry */

/* Follow the compositor's output scale (crisp at any DPI); IOSC_PANEL_SCALE
 * overrides. Logical size tracks the fullscreen layer-surface configure. */
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
    if (O.scale_env || f <= 0 || f == O.scale) return;
    O.scale = (int)f;
    render();
}
static const struct wl_output_listener output_listener = {
    .geometry = out_geometry, .mode = out_mode, .done = out_done, .scale = out_scale,
};

static void reg_global(void *d, struct wl_registry *r, uint32_t name, const char *iface, uint32_t ver)
{
    (void)d;
    if (!strcmp(iface, wl_compositor_interface.name))
        O.comp = wl_registry_bind(r, name, &wl_compositor_interface, ver < 4 ? ver : 4);
    else if (!strcmp(iface, wl_shm_interface.name))
        O.shm = wl_registry_bind(r, name, &wl_shm_interface, 1);
    else if (!strcmp(iface, wl_output_interface.name) && !O.output) {
        O.output = wl_registry_bind(r, name, &wl_output_interface, ver < 2 ? ver : 2);
        if (ver >= 2) wl_output_add_listener(O.output, &output_listener, NULL);
    } else if (!strcmp(iface, wl_seat_interface.name)) {
        O.seat = wl_registry_bind(r, name, &wl_seat_interface, ver < 5 ? ver : 5);
        wl_seat_add_listener(O.seat, &seat_listener, NULL);
    } else if (!strcmp(iface, zwlr_layer_shell_v1_interface.name))
        O.layer_shell = wl_registry_bind(r, name, &zwlr_layer_shell_v1_interface, ver < 4 ? ver : 4);
    else if (!strcmp(iface, zwlr_foreign_toplevel_manager_v1_interface.name)) {
        O.ftm = wl_registry_bind(r, name, &zwlr_foreign_toplevel_manager_v1_interface, ver < 3 ? ver : 3);
        zwlr_foreign_toplevel_manager_v1_add_listener(O.ftm, &ftm_listener, NULL);
    } else if (!strcmp(iface, zwlr_screencopy_manager_v1_interface.name)) {
        O.scm_version = (int)(ver < 3 ? ver : 3);
        O.scm = wl_registry_bind(r, name, &zwlr_screencopy_manager_v1_interface, (uint32_t)O.scm_version);
    }
}
static void reg_remove(void *d, struct wl_registry *r, uint32_t name){ (void)d;(void)r;(void)name; }
static const struct wl_registry_listener registry_listener = { .global = reg_global, .global_remove = reg_remove };

/* ------------------------------------------------------------------ main */

int main(void)
{
    signal(SIGCHLD, SIG_IGN);
    memset(&O, 0, sizeof O);
    O.width = 1440; O.height = 1080; O.scale = 2; O.running = 1;
    O.ptr_kind = -1; O.ptr_idx = -1;
    const char *es = getenv("IOSC_PANEL_SCALE");
    if (es && atoi(es) > 0) { O.scale = atoi(es); O.scale_env = 1; }
    int animate = 0;
    const char *ea = getenv("IOSC_SHELL_ANIM");
    if (ea && *ea && strcmp(ea, "0")) animate = 1;

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

    O.napps = sd_scan_apps(O.apps, APP_MAX);
    for (int i = 0; i < O.napps; i++)
        O.app_icon[i] = pi_load_surface(O.apps[i].icon[0] ? O.apps[i].icon : O.apps[i].name,
                                        O.scale);
    refilter();

    /* Freeze the desktop into the frosted backdrop BEFORE mapping (the capture
     * must not include the overview itself). */
    if (O.scm) {
        cairo_surface_t *cap = sc_capture(O.dpy, O.shm, O.scm, O.scm_version, O.output,
                                          0, 0, 0, 0);
        if (cap) {
            O.backdrop = sb_backdrop_build(cap, 8, 12);
            cairo_surface_destroy(cap);
        }
    }
    fprintf(stderr, "ioscoverview " IOSCOVERVIEW_VER ": %d app(s), foreign-toplevel=%s, backdrop=%s "
            "(layout centers on the configured output width)\n",
            O.napps, O.ftm ? "yes" : "no", O.backdrop ? "frosted" : "gradient");

    O.surf  = wl_compositor_create_surface(O.comp);
    O.layer = zwlr_layer_shell_v1_get_layer_surface(O.layer_shell, O.surf, NULL,
                ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY, "overview");
    zwlr_layer_surface_v1_add_listener(O.layer, &layer_listener, NULL);
    zwlr_layer_surface_v1_set_anchor(O.layer,
        ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP | ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM |
        ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT | ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT);
    zwlr_layer_surface_v1_set_size(O.layer, 0, 0);          /* span the whole output */
    zwlr_layer_surface_v1_set_exclusive_zone(O.layer, -1);  /* cover everything */
    zwlr_layer_surface_v1_set_keyboard_interactivity(O.layer, 1); /* search + Escape */
    O.anim_t = animate ? 0.0 : 1.0;
    wl_surface_commit(O.surf);

    /* entrance animation: a few quick frames after the first configure */
    if (animate) {
        wl_display_roundtrip(O.dpy);            /* get configure -> first frame */
        const double steps[] = { 0.35, 0.65, 0.85, 1.0 };
        for (size_t i = 0; i < sizeof steps / sizeof steps[0] && O.running; i++) {
            O.anim_t = steps[i];
            render();
            wl_display_flush(O.dpy);
            usleep(33000);
        }
    }
    O.anim_t = 1.0;

    int fd = wl_display_get_fd(O.dpy);
    while (O.running) {
        while (wl_display_prepare_read(O.dpy) != 0) wl_display_dispatch_pending(O.dpy);
        wl_display_flush(O.dpy);
        struct pollfd pfd = { .fd = fd, .events = POLLIN };
        int timeout = (O.touch_active && O.press_kind == OV_HIT_APP && !O.long_press_done) ? 50 : -1;
        int n = poll(&pfd, 1, timeout);
        if (n < 0 && errno != EINTR) { wl_display_cancel_read(O.dpy); break; }
        if (n > 0 && (pfd.revents & POLLIN)) wl_display_read_events(O.dpy);
        else wl_display_cancel_read(O.dpy);
        wl_display_dispatch_pending(O.dpy);
        maybe_pin_pressed_app();
    }
    if (O.backdrop) cairo_surface_destroy(O.backdrop);
    sd_cairo_pool_destroy(&O.surface_pool);
    wl_display_disconnect(O.dpy);
    return 0;
}

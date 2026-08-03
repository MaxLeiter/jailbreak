/*
 * iosc_internal.h — the compositor core shared between iosc.c and the protocol
 * modules split out of it (iosc_text_input.c, iosc_cursor.c, ...).
 *
 * iosc.c grew to ~9.6k lines with every Wayland protocol implementation inlined
 * into one translation unit, so everything could be `static` and reach every
 * global directly. Splitting those implementations into their own files needs
 * that shared core spelled out once: the surface/output types, the globals the
 * protocol code reads, and the handful of core helpers it calls back into.
 *
 * This is NOT a public API — it is the seam between iosc.c and its own modules.
 * The rule of thumb for what belongs here: a type used by more than one module,
 * a global more than one module touches, or a core helper (focus, repaint,
 * geometry) a module has to call. Protocol-local types and state stay private to
 * the module that owns them.
 */
#ifndef IOSC_INTERNAL_H
#define IOSC_INTERNAL_H

#include <stdint.h>
#include <stddef.h>
#include <wayland-server.h>

#include "iosc_render_plan.h"   /* struct iosc_rect, IOSC_MAX_OUTPUT_DAMAGE_RECTS */

/* ===========================================================================
 * Output
 * ======================================================================== */

/* Stable identifier for our single output. Reported identically via wl_output v4
 * name, zxdg_output_v1 name, kde_output_device_v2 name+uuid, kde_output_order_v1
 * and kde_primary_output_v1 so KDE tooling can cross-reference the one output. */
#define IOSC_OUTPUT_NAME "IOSC-1"

#define IOSC_MAX_OUTPUT_RES 32

extern struct wl_display *g_display;

extern int g_width, g_height;      /* output IOSurface size = logical * scale */
extern int g_stride;               /* real bytes-per-row (IOSurface-padded) */
extern int g_output_dpi;           /* logical desktop DPI for GTK/Pango */
extern int g_output_scale;         /* logical -> physical output pixels */
extern int g_native_mode;
extern int g_fullscreen_toplevels;
extern int g_output_transform;     /* wl_output transform */
extern int g_natural_lw, g_natural_lh;   /* launch logical size */
extern int g_advertise_transform;

extern struct wl_resource *g_output_res[IOSC_MAX_OUTPUT_RES];
extern int g_noutput_res;
extern struct wl_resource *g_xdg_output_res[IOSC_MAX_OUTPUT_RES];
extern int g_nxdg_output_res;

uint32_t now_ms(void);

/* IOSC_DEBUG=1 turns on the per-frame validation readbacks + logs. They call
 * glReadPixels (a synchronous GPU->CPU stall) and fprintf every recompose, so
 * they must stay OFF in normal operation. Event-driven logs (focus, drag, lock,
 * tablet) are not gated by this — only the per-frame spam is. Cached once. */
int iosc_debug(void);

static inline int clampi(int v, int lo, int hi)
{
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

static inline uint8_t u32_fraction_to_u8(uint32_t v)
{
    return (uint8_t)(((uint64_t)v * 255u + 0x7FFFFFFFu) / 0xFFFFFFFFu);
}

static inline int output_scale(void)
{
    return g_output_scale > 0 ? g_output_scale : 1;
}

static inline int output_logical_width(void)
{
    int s = output_scale();
    return (g_width + s - 1) / s;
}

static inline int output_logical_height(void)
{
    int s = output_scale();
    return (g_height + s - 1) / s;
}

static inline int output_px_to_mm(int px)
{
    int dpi = g_output_dpi > 0 ? g_output_dpi : 96;
    return (px * 254 + dpi * 5) / (dpi * 10);
}

static inline int buffer_to_logical(int px, int scale)
{
    int s = scale > 0 ? scale : 1;
    return (px + s - 1) / s;
}

static inline int physical_to_logical(int px)
{
    return px / output_scale();
}

void output_send_state(struct wl_resource *r);
/* wp_viewporter + wp_fractional_scale_v1 (iosc_viewport.c). */
void fractional_scale_broadcast(void);   /* re-notify wp_fractional_scale_v1 clients */
void viewporter_bind(struct wl_client *client, void *data,
                     uint32_t version, uint32_t id);
void fractional_scale_bind(struct wl_client *client, void *data,
                           uint32_t version, uint32_t id);

/* Drop a destroyed resource from one of the per-global resource lists. */
void output_res_remove(struct wl_resource **arr, int *n, struct wl_resource *r);

/* The single entry point for changing the output geometry at runtime (the KDE
 * output-management apply path and the -logical/-g runtime reconfigure both land
 * here). Returns nonzero if anything actually changed. */
int output_reconfigure_px(int pw, int ph, int transform, int scale);

/* ===========================================================================
 * KDE output-management family  (iosc_kde_output.c)
 * ======================================================================== */

void kde_output_broadcast(void);         /* kde device bursts + order + primary */
void broadcast_output_all(void);         /* wl_output + xdg_output + the two above */

void kde_output_device_bind(struct wl_client *client, void *data,
                            uint32_t version, uint32_t id);
void kde_management_bind(struct wl_client *client, void *data,
                         uint32_t version, uint32_t id);
void kde_primary_bind(struct wl_client *client, void *data,
                      uint32_t version, uint32_t id);
void kde_order_bind(struct wl_client *client, void *data,
                    uint32_t version, uint32_t id);

/* ===========================================================================
 * Surfaces
 * ======================================================================== */

enum iosc_role {
    IOSC_ROLE_NONE = 0,
    IOSC_ROLE_TOPLEVEL,
    IOSC_ROLE_POPUP,
    IOSC_ROLE_SUBSURFACE,
    IOSC_ROLE_LAYER,
    IOSC_ROLE_LOCK,      /* ext-session-lock-v1 lock surface (never in g_mapped) */
};

struct iosc_surface;

struct iosc_positioner {
    int size_w, size_h;
    int anchor_x, anchor_y, anchor_w, anchor_h;
    uint32_t anchor, gravity;
    uint32_t constraint;
    int off_x, off_y;
};

struct iosc_viewport {
    struct wl_resource *resource;
    struct iosc_surface *surface;
    int has_src;
    int src_x, src_y, src_w, src_h;
    int has_dst;
    int dst_w, dst_h;
};

struct iosc_subsurface {
    struct wl_resource *resource;
    struct iosc_surface *surface;
    struct iosc_surface *parent;
    int x, y;
    int sync;             /* wl_subsurface default is synchronized (spec) */
    int cache_pending;    /* committed while sync: the surface's existing
                           * pending_buffer/buffer_attached/gl-dirty state is left
                           * un-applied (it IS the single-level cache) until the
                           * parent's own state next applies; see
                           * surface_apply_sync_children(). */
};

struct iosc_presentation_feedback {
    struct wl_resource *resource;
    struct iosc_surface *surface;
    struct wl_list link;
};

#define IOSC_MAX_SHM_DIRTY_RECTS 16
#define IOSC_MAX_VISIBLE_RECTS 32

/* Per-surface state for a wlr layer-shell surface (role == IOSC_ROLE_LAYER).
 * Double-buffered state is simplified: requests store straight into this struct
 * and take effect at the commit-driven configure/placement (a panel sets its
 * anchor/size once before the initial commit, so atomicity is a non-issue). */
struct iosc_layer_state {
    struct wl_resource *resource;   /* zwlr_layer_surface_v1 */
    uint32_t layer;                 /* 0 background,1 bottom,2 top,3 overlay */
    uint32_t anchor;                /* ZWLR_LAYER_SURFACE_V1_ANCHOR_* bitfield */
    int32_t  excl_zone;             /* set_exclusive_zone */
    int32_t  margin_t, margin_r, margin_b, margin_l;
    uint32_t kbd_interactivity;     /* none/exclusive/on_demand */
    int32_t  req_w, req_h;          /* set_size (0 = compositor decides) */
    int      cfg_w, cfg_h;          /* size last sent in a configure */
    int      acked;                 /* client acked a configure */
    int      configured;            /* we sent the initial configure */
    char     namespace[64];
};

struct iosc_surface {
    uint32_t            window_id;       /* compositor id for native per-window input/present */
    struct wl_list      surface_link;    /* all live wl_surface resources */
    struct wl_resource *resource;        /* wl_surface */
    struct wl_resource *pending_buffer;  /* last wl_surface.attach (may be NULL) */
    int                 buffer_attached; /* attach was called this cycle */
    struct wl_resource *current_buffer;  /* committed buffer, retained for recompositing */
    struct wl_listener  buffer_destroy;  /* fires if the client destroys current_buffer */
    int                 buffer_listener_active;
    uint64_t            direct_present_seq; /* app consumer-release gates old wl_buffer */
    uint32_t            direct_surface_id;
    int                 sw, sh;          /* current buffer source dimensions */
    int                 gl_dirty;        /* wl_shm content changed since last GPU upload */
    int                 gl_dirty_rect_count;
    int                 gl_dirty_rects[IOSC_MAX_SHM_DIRTY_RECTS * 4]; /* x,y,w,h in buffer px */
    uint64_t            damage_events;
    uint64_t            damage_surface_events;
    uint64_t            damage_buffer_events;
    uint64_t            damage_full_events;
    uint64_t            damage_pixels;
    int                 dx, dy;          /* placement (top-left) on the output */
    int                 native_canvas_w, native_canvas_h, native_canvas_stride;
    int                 native_canvas_live;
    int                 native_canvas_dirty;
    int                 pending_buffer_scale;
    int                 current_buffer_scale;
    int                 pending_scale_dirty;
    int                 mapped;          /* present in the z-order list */
    int                 is_xwayland;     /* adopted X11 window (no xdg role; XWM drives close/focus) */
    enum iosc_role      role;
    struct iosc_surface *parent;         /* subsurface/popup parent, OR xdg_toplevel.set_parent (transient/modal) */
    int                 rel_x, rel_y;
    /* wl_surface.set_opaque_region bbox (surface-local logical px). The window
     * composite path uses it to keep fully-opaque windows on the fast opaque path
     * and alpha-blend the rest (CSD shadow margins). opaque_set=0 => none declared. */
    int                 opaque_set;
    int                 opaque_x0, opaque_y0, opaque_x1, opaque_y1;
    struct wl_resource *xdg_surface;     /* xdg_surface role, or NULL */
    struct wl_resource *xdg_toplevel;    /* xdg_toplevel role, or NULL */
    struct wl_resource *xdg_decoration;  /* zxdg_toplevel_decoration_v1, or NULL */
    struct wl_resource *xdg_popup;       /* xdg_popup role, or NULL */
    int                 toplevel_maximized;
    int                 toplevel_fullscreen;
    int                 toplevel_minimized;
    int                 toplevel_resizing;
    struct wl_resource *ftl_handles[8];  /* zwlr_foreign_toplevel_handle_v1 per manager */
    int                 ftl_nhandles;
    struct iosc_subsurface *subsurface;
    struct iosc_viewport *viewport;
    struct iosc_layer_state *layer;      /* allocated when role == LAYER */
    char                title[256];      /* xdg_toplevel.set_title (foreign-toplevel) */
    char                app_id[256];     /* xdg_toplevel.set_app_id (foreign-toplevel) */
    int                 configured;      /* sent the initial xdg configure */
    /* wl_surface.frame is double-buffered surface state: requests enter the
     * pending list and become compositor-visible only with wl_surface.commit. */
    struct wl_list      pending_frame_callbacks;
    struct wl_list      frame_callbacks; /* committed wl_callback resources */
    struct wl_list      presentation_feedbacks;
    /* xdg_surface.set_window_geometry: double-buffered like the rest of the
     * surface state, latched on commit. geo_set=0 falls back to the whole
     * display-sized buffer (spec default when unset). Coordinates are
     * surface-local (same space as opaque/input regions), i.e. already
     * comparable to surface_display_size()'s w/h. */
    int                 pending_geo_set;
    int                 pending_geo_x, pending_geo_y, pending_geo_w, pending_geo_h;
    int                 geo_set;
    int                 geo_x, geo_y, geo_w, geo_h;
    /* xdg_surface.get_popup positioner snapshot. A layer-shell popup's xdg_surface
     * parent is NULL per protocol (zwlr_layer_surface_v1.get_popup supplies the
     * real parent afterward, before the client's first commit); keep the
     * positioner's VALUE (not a pointer -- the client may destroy the positioner
     * object right after xdg_surface.get_popup) so the deferred placement in
     * layer_surface_get_popup() has something to place with. */
    struct iosc_positioner popup_positioner;
    int                 popup_positioner_set;
};

/* a queued frame-callback resource */
struct iosc_frame {
    struct wl_resource *resource;
    struct wl_list      link;
};

/* wl_region: union bbox of add()s; subtract() sets `complex` (a bbox can't hold a
 * hole). Used by wl_surface.set_opaque_region to gate the window opaque fast-path. */
struct iosc_region { int has, complex, x0, y0, x1, y1; };

/* Mapped surfaces in z-order: [0] = bottom, [g_nmapped-1] = top. The compositor
 * recomposites this whole list (back to front) on every commit. */
#define IOSC_MAX_SURFACES 64
extern struct iosc_surface *g_mapped[IOSC_MAX_SURFACES];
extern int g_nmapped;
extern struct wl_list g_surfaces;

void surface_unmap(struct iosc_surface *s);
void surface_raise(struct iosc_surface *s);
void native_mark_surface_dirty(struct iosc_surface *s);
void toplevel_send_configure(struct iosc_surface *s, int w, int h);
int  default_window_w(void);
int  default_window_h(void);

/* ===========================================================================
 * Repaint
 * ======================================================================== */

void recomposite_all_at(const char *reason, int line);   /* coalesced repaint */
#define recomposite_all() recomposite_all_at(__func__, __LINE__)
void recomposite_now(void);   /* synchronous repaint (callers that read the output back) */
void repaint_retry_soon(void);
void recomposite_reason_clear(void);

extern uint32_t g_present_interval_us;   /* refresh, for presentation-time feedback */
extern int g_force_output_composite;
/* Nonzero once the output damage accumulator holds a valid region for the next
 * present; a repaint requested before that has nothing to compose. */
extern int g_output_damage_valid;

void output_damage_add_rect(int x0, int y0, int x1, int y1);
void output_damage_add_full(void);
int  rect_intersects_rect(const struct iosc_rect *a, const struct iosc_rect *b);

/* The damage region of the last completed present. wlr-screencopy's
 * with_damage capture rides on this rather than tracking its own. */
extern int g_last_present_damage_valid;
extern int g_last_present_damage_rect_count;
extern struct iosc_rect g_last_present_damage_rects[IOSC_MAX_OUTPUT_DAMAGE_RECTS];

/* ===========================================================================
 * wlr-screencopy-v1  (iosc_screencopy.c)
 * ======================================================================== */

void screencopy_mgr_bind(struct wl_client *client, void *data,
                         uint32_t version, uint32_t id);

/* ===========================================================================
 * Input focus + seat
 * ======================================================================== */

/* Input focus (set by the seat code; (un)map adjusts it). */
extern struct iosc_surface *g_kbd_focus;   /* surface with keyboard focus */
extern struct iosc_surface *g_ptr_focus;   /* surface the pointer is over  */
extern struct iosc_surface *g_cursor_surface;
extern int g_cursor_visible, g_cursor_x, g_cursor_y, g_cursor_hot_x, g_cursor_hot_y;
/* Last absolute sample from UIKit. Kept separate from the visible cursor so a
 * locked pointer can produce incremental deltas while the cursor stays frozen. */
extern int g_motion_input_valid, g_motion_input_x, g_motion_input_y;

extern int g_keymap_fd;                    /* xkb keymap, sent to each wl_keyboard */

void keyboard_set_focus(struct iosc_surface *s);
void keyboard_send_mods(uint32_t depressed, uint32_t locked);
void keyboard_send_raw_key(uint32_t time, uint32_t key, uint32_t state);

int  iosc_app_cursor(void);   /* IOSC_APP_CURSOR: app draws the pointer overlay */
void app_cursor_notify(void); /* signal pointer pos/shape to the app overlay */

/* ===========================================================================
 * foreign-toplevel / taskbar  (iosc_foreign_toplevel.c)
 * ======================================================================== */

/* The surface code calls these whenever a toplevel's advertised state changes;
 * each bound manager holds a handle in s->ftl_handles[]. */
void ftl_toplevel_mapped(struct iosc_surface *s);
void ftl_toplevel_closed(struct iosc_surface *s);
void ftl_broadcast_state(struct iosc_surface *s);
void ftl_broadcast_title(struct iosc_surface *s);
void ftl_broadcast_app_id(struct iosc_surface *s);
void ftl_manager_bind(struct wl_client *client, void *data,
                      uint32_t version, uint32_t id);

/* Re-send an xdg_toplevel.configure reflecting the surface's current
 * maximized/fullscreen/minimized flags. */
void toplevel_reconfigure_state(struct iosc_surface *s);

/* ===========================================================================
 * wm control socket  (iosc_wm_socket.c)
 * ======================================================================== */

/* A tiny line protocol so a NON-Wayland client (ioscd, the panel) can raise,
 * focus or minimise a window by app_id. Returns 0 on success. */
int wm_socket_start(struct wl_event_loop *loop, const char *path);

/* Shared AF_UNIX listener plumbing (the wm socket and the app input socket both
 * use it): unlink, bind, listen, and register on_accept with the event loop. */
int unix_listen_start(struct wl_event_loop *loop, const char *path,
                      int (*on_accept)(int, uint32_t, void *));

void surface_set_minimized(struct iosc_surface *s, int minimized);

/* ===========================================================================
 * idle notify / inhibit  (iosc_idle.c)
 * ======================================================================== */

/* Every real input event calls this; it resets the idle timers and wakes any
 * client that was told the seat went idle. */
void idle_note_activity(void);
void idle_notifier_bind(struct wl_client *client, void *data,
                        uint32_t version, uint32_t id);
void idle_inhibit_mgr_bind(struct wl_client *client, void *data,
                           uint32_t version, uint32_t id);

/* ===========================================================================
 * text-input-v3 / input-method-v2 / virtual-keyboard-v1  (iosc_text_input.c)
 * ======================================================================== */

void text_input_focus_surface(struct iosc_surface *old, struct iosc_surface *next);
void input_method_update_active(void);
int  text_input_commit_text(const char *text, size_t len);

/* Content traits of the currently focused zwp_text_input_v3, for the XIOS_IN_TRAITS
 * record that tells the Xios app which iOS keyboard to raise. Returns 0 (and
 * zeroes the outputs) when nothing is focused, so callers need no null dance.
 * An accessor rather than an exported struct: struct iosc_text_input stays
 * private to iosc_text_input.c. */
int text_input_focus_traits(uint32_t *content_hint, uint32_t *content_purpose,
                            int *enabled);

/* iosc.c owns the app-side traits channel (the Xios keyboard bridge); the
 * text-input module calls it whenever the focused input's state changes. */
void input_clients_send_traits(void);

void text_input_manager_bind(struct wl_client *client, void *data,
                             uint32_t version, uint32_t id);
void input_method_manager_bind(struct wl_client *client, void *data,
                               uint32_t version, uint32_t id);
void virtual_keyboard_manager_bind(struct wl_client *client, void *data,
                                   uint32_t version, uint32_t id);

/* ===========================================================================
 * wl_pointer extensions  (iosc_pointer_ext.c)
 * ======================================================================== */

/* Report a synthesised relative delta (iosc only ever sees absolute positions,
 * so handle_motion() computes the delta and calls this). */
void relptr_send(uint32_t time, double dx, double dy);

/* Trackpad pinch/rotate, fed by XIOS_IN_GESTURE off the app input socket. */
void handle_gesture(uint32_t code, int32_t dx256, int32_t dy256,
                    uint32_t scale256, uint32_t rot256);

/* Pointer lock/confinement. handle_motion() consults both: a locked pointer
 * freezes the visible cursor and reports deltas only, and a confined one has its
 * position clamped into the region by confine_point(). */
int  pointer_locked_for(struct iosc_surface *s);
int  confine_point(struct iosc_surface *s, int *x, int *y);
void constraints_update_focus(struct iosc_surface *newfocus);
void constraints_surface_gone(struct iosc_surface *s);

void relptr_mgr_bind(struct wl_client *client, void *data,
                     uint32_t version, uint32_t id);
void ptrgest_mgr_bind(struct wl_client *client, void *data,
                      uint32_t version, uint32_t id);
void constraints_bind(struct wl_client *client, void *data,
                      uint32_t version, uint32_t id);

/* Helpers the extension modules call back into. */
void reslist_remove(struct wl_resource **arr, int *n, struct wl_resource *r);
void handle_motion(int x, int y);
void surface_output_size(struct iosc_surface *s, int *w, int *h);
void output_damage_add_cursor_at(int x, int y);

/* ===========================================================================
 * xdg-activation-v1  (iosc_activation.c)
 * ======================================================================== */

void activation_bind(struct wl_client *client, void *data,
                     uint32_t version, uint32_t id);

/* ===========================================================================
 * tablet-v2 / Apple Pencil  (iosc_tablet.c)
 * ======================================================================== */

/* One pencil sample off the app input socket (IOSC_IN_TABLET). */
void handle_pencil(int phase, int x, int y, uint32_t pressure, int tiltx, int tilty);
void pen_leave(uint32_t t);
void pen_surface_gone(struct iosc_surface *s);   /* drop the pen grab on unmap */
void tablet_mgr_bind(struct wl_client *c, void *data, uint32_t version, uint32_t id);

/* Hit-testing + focus helpers the pencil path shares with the pointer path. */
struct iosc_surface *surface_at(int x, int y);
void surface_local_coords(struct iosc_surface *s, int x, int y,
                          wl_fixed_t *sx, wl_fixed_t *sy);
void press_focus(struct iosc_surface *hit);

/* Route one real key transition to a bound input-method's keyboard grab.
 * Returns 1 if an active grab consumed the key (the caller must NOT also deliver
 * it to wl_keyboard), 0 if there is no grab and normal delivery should proceed. */
int input_method_forward_grab_key(uint32_t time, uint32_t key, uint32_t state,
                                  uint32_t depressed, uint32_t locked);

#endif /* IOSC_INTERNAL_H */

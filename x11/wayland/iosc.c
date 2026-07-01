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
 * Current scope: a small native compositor with wl_shm and IOSurface buffers,
 * GPU recomposition into the output IOSurface, basic xdg-shell windows/popups,
 * subsurfaces, keyboard/pointer input, and the scale protocols GTK/Qt expect.
 */
#include <wayland-server.h>
#include <wayland-server-protocol.h>
#include "xdg-shell-server-protocol.h"
#include "xdg-decoration-unstable-v1-server-protocol.h"
#include "xdg-activation-v1-server-protocol.h"
#include "viewporter-server-protocol.h"
#include "fractional-scale-v1-server-protocol.h"
#include "presentation-time-server-protocol.h"
#include "xdg-output-unstable-v1-server-protocol.h"
#include "text-input-unstable-v3-server-protocol.h"
#include "input-method-unstable-v2-server-protocol.h"
#include "virtual-keyboard-unstable-v1-server-protocol.h"
#include "wlr-layer-shell-unstable-v1-server-protocol.h"
#include "wlr-foreign-toplevel-management-unstable-v1-server-protocol.h"
#include "pointer-constraints-unstable-v1-server-protocol.h"
#include "relative-pointer-unstable-v1-server-protocol.h"
#include "primary-selection-unstable-v1-server-protocol.h"
#include "idle-inhibit-unstable-v1-server-protocol.h"
#include "ext-idle-notify-v1-server-protocol.h"
#include "single-pixel-buffer-v1-server-protocol.h"
#include "cursor-shape-v1-server-protocol.h"
#include "wlr-screencopy-unstable-v1-server-protocol.h"
#include "ext-session-lock-v1-server-protocol.h"
#include "tablet-v2-server-protocol.h"
#include "iosc-iosurface-server-protocol.h"

#include "xios_surface.h"
#include "iosc_gl.h"
#include "iosc_input.h"
#include "xios_input_socket.h"   /* shared AF_UNIX input reader (also used by MetaBackendIOS) */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <stdint.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>

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
static int               g_output_dpi = 96; /* logical desktop DPI for GTK/Pango */
static int               g_output_scale = 2; /* logical -> physical output pixels */

/* M1 presents one toplevel; remember it so a configure can size it fullscreen. */
struct iosc_surface;
static void clipboard_selection_send_to_client(struct wl_client *client);
static void recomposite_all(void);   /* coalesced: schedules one repaint per loop iteration */
static void recomposite_now(void);   /* synchronous repaint (callers that read the output back) */
static int  iosc_app_cursor(void);   /* IOSC_APP_CURSOR: app draws the pointer overlay */
static void app_cursor_notify(void); /* signal pointer pos/shape to the app overlay */

static uint32_t now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint32_t)(ts.tv_sec * 1000 + ts.tv_nsec / 1000000);
}

static int output_px_to_mm(int px)
{
    int dpi = g_output_dpi > 0 ? g_output_dpi : 96;
    return (px * 254 + dpi * 5) / (dpi * 10);
}

static int output_scale(void)
{
    return g_output_scale > 0 ? g_output_scale : 1;
}

static int output_logical_width(void)
{
    int s = output_scale();
    return (g_width + s - 1) / s;
}

static int output_logical_height(void)
{
    int s = output_scale();
    return (g_height + s - 1) / s;
}

static int buffer_to_logical(int px, int scale)
{
    int s = scale > 0 ? scale : 1;
    return (px + s - 1) / s;
}

static int physical_to_logical(int px)
{
    return px / output_scale();
}

/* ---- per-surface state --------------------------------------------------- */

enum iosc_role {
    IOSC_ROLE_NONE = 0,
    IOSC_ROLE_TOPLEVEL,
    IOSC_ROLE_POPUP,
    IOSC_ROLE_SUBSURFACE,
    IOSC_ROLE_LAYER,
    IOSC_ROLE_LOCK,      /* ext-session-lock-v1 lock surface (never in g_mapped) */
};

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
};

struct iosc_presentation_feedback {
    struct wl_resource *resource;
    struct iosc_surface *surface;
    struct wl_list link;
};

struct iosc_layer_state;

struct iosc_surface {
    struct wl_resource *resource;        /* wl_surface */
    struct wl_resource *pending_buffer;  /* last wl_surface.attach (may be NULL) */
    int                 buffer_attached; /* attach was called this cycle */
    struct wl_resource *current_buffer;  /* committed buffer, retained for recompositing */
    struct wl_listener  buffer_destroy;  /* fires if the client destroys current_buffer */
    int                 buffer_listener_active;
    int                 sw, sh;          /* current buffer source dimensions */
    int                 gl_dirty;        /* wl_shm content changed since last GPU upload */
    int                 dx, dy;          /* placement (top-left) on the output */
    int                 pending_buffer_scale;
    int                 current_buffer_scale;
    int                 pending_scale_dirty;
    int                 mapped;          /* present in the z-order list */
    enum iosc_role      role;
    struct iosc_surface *parent;
    int                 rel_x, rel_y;
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
    struct wl_list      frame_callbacks; /* pending wl_callback resources */
    struct wl_list      presentation_feedbacks;
};

/* a queued frame-callback resource */
struct iosc_frame {
    struct wl_resource *resource;
    struct wl_list      link;
};

/* The per-toplevel window size is logical, so high-DPI clients lay out like a
 * normal desktop while the compositor still presents into a native IOSurface. */
static int default_window_w(void)
{
    int w = output_logical_width() - 80;
    return w > 1 ? w : output_logical_width();
}

static int default_window_h(void)
{
    int h = output_logical_height() - 80;
    return h > 1 ? h : output_logical_height();
}

/* Mapped surfaces in z-order: [0] = bottom, [g_nmapped-1] = top. The compositor
 * recomposites this whole list (back to front) on every commit. */
#define IOSC_MAX_SURFACES 16
static struct iosc_surface *g_mapped[IOSC_MAX_SURFACES];
static int g_nmapped = 0;

/* Input focus (set by the seat code below; (un)map adjusts it). */
static struct iosc_surface *g_kbd_focus;   /* surface with keyboard focus */
static struct iosc_surface *g_ptr_focus;   /* surface the pointer is over  */
static struct iosc_surface *g_cursor_surface;
static int g_cursor_visible, g_cursor_x, g_cursor_y, g_cursor_hot_x, g_cursor_hot_y;

/* Drag-and-drop (wl_data_device.start_drag). While a drag is active the source
 * client holds an implicit pointer grab, and the pointer drives wl_data_device
 * enter/leave/motion/drop to the destination under the cursor (not normal
 * wl_pointer events). The offer handed to the destination forwards
 * accept/receive/finish straight to the source, so bytes stream source->dest
 * over a pipe with no compositor copy. Full impl lives with the data-device
 * code; these are forward-declared for handle_motion/handle_button + unmap. */
struct iosc_dnd {
    int                  active;
    struct wl_resource  *source;         /* wl_data_source (NULL: icon-only drag) */
    struct wl_listener   source_destroy; /* cancel the drag if the source dies */
    struct iosc_surface *origin;
    struct wl_client    *origin_client;
    struct iosc_surface *icon;           /* drag icon surface (follows the pointer) */
    struct iosc_surface *focus;          /* destination surface under the pointer */
    struct wl_resource  *offer;          /* wl_data_offer handed to focus's client */
    int                  target_accepted;/* dest called accept(mime != NULL) */
    uint32_t             action;         /* negotiated dnd action */
};
static struct iosc_dnd g_dnd;
static void dnd_update_motion(int x, int y, uint32_t t);
static void dnd_drop(void);
static void dnd_end(void);
/* start_drag is only honored against the serial of a still-held button press. */
static uint32_t g_button_serial;
static int g_button_down;
static void touch_surface_gone(struct iosc_surface *s);   /* drop touch grabs on unmap */
static void touch_cancel_all(void);
static void pen_surface_gone(struct iosc_surface *s);     /* drop the pen grab on unmap */

/* ext-session-lock-v1. While locked, the output shows ONLY the lock surface
 * (blank black until it maps) and all input is confined to it: surface_at()
 * resolves to it exclusively and keyboard_set_focus() redirects to it, so
 * normal windows can neither show nor steal focus. If the locker dies without
 * unlocking, the session STAYS locked (spec security requirement); a fresh
 * lock request may then take over and unlock. */
struct iosc_session_lock {
    struct wl_resource  *lock;         /* ext_session_lock_v1; NULL if none/abandoned */
    int                  locked;
    struct iosc_surface *surface;      /* the lock surface (single output) */
    struct wl_resource  *lock_surface; /* its ext_session_lock_surface_v1 */
};
static struct iosc_session_lock g_slock;
enum iosc_interactive_op { IOSC_INTERACTIVE_NONE, IOSC_INTERACTIVE_MOVE, IOSC_INTERACTIVE_RESIZE };
static enum iosc_interactive_op g_interactive_op;
static struct iosc_surface *g_interactive_surface;
static int g_interactive_px, g_interactive_py;
static int g_interactive_dx, g_interactive_dy;
static int g_interactive_w, g_interactive_h;
static uint32_t g_interactive_edges;
static uint64_t g_presentation_seq;
static void keyboard_set_focus(struct iosc_surface *s);
static void keyboard_send_mods(uint32_t mask);
static void keyboard_send_raw_key(uint32_t time, uint32_t key, uint32_t state);
static void text_input_focus_surface(struct iosc_surface *old, struct iosc_surface *next);
static void input_method_update_active(void);
static void input_clients_send_traits(void);
static void surface_raise(struct iosc_surface *s);
/* foreign-toplevel (zwlr_foreign_toplevel_management_v1) — taskbar/window list */
static void ftl_toplevel_mapped(struct iosc_surface *s);
static void ftl_toplevel_closed(struct iosc_surface *s);
static void ftl_broadcast_state(struct iosc_surface *s);
static void ftl_broadcast_title(struct iosc_surface *s);
static void ftl_broadcast_app_id(struct iosc_surface *s);
/* pointer-constraints (zwp_pointer_constraints_v1) + relative-pointer */
static void relptr_send(uint32_t time, double dx, double dy);
static int  pointer_locked_for(struct iosc_surface *s);
static void constraints_update_focus(struct iosc_surface *newfocus);
static int  confine_point(struct iosc_surface *s, int *x, int *y);
static void constraints_surface_gone(struct iosc_surface *s);
/* idle (ext_idle_notify_v1 + zwp_idle_inhibit_manager_v1) */
static void idle_note_activity(void);
/* primary selection (zwp_primary_selection_device_manager_v1) */
static void primary_selection_send_to_client(struct wl_client *client);

static int clampi(int v, int lo, int hi)
{
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

/* ---- layer-shell state (zwlr_layer_shell_v1) ----------------------------- */

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

/* Accumulated exclusive zones per output edge (the work area = output minus
 * these). Recomputed whenever a layer surface maps/unmaps or changes zone. */
static int g_excl_top, g_excl_bottom, g_excl_left, g_excl_right;

/* Z-band key: 0 background < 1 bottom < 2 normal toplevels < 3 top < 4 overlay.
 * g_mapped[] is kept sorted by (band, insertion order) so layers stack right. */
static int surface_band(struct iosc_surface *s)
{
    if (s->role == IOSC_ROLE_LAYER && s->layer) {
        switch (s->layer->layer) {
        case 0: return 0;   /* background */
        case 1: return 1;   /* bottom */
        case 2: return 3;   /* top */
        case 3: return 4;   /* overlay */
        default: return 2;
        }
    }
    return 2;               /* toplevels / popups / subsurfaces */
}

/* Recompute the per-edge exclusive-zone accumulators from mapped layer
 * surfaces. A positive zone reserves the edge the surface is anchored to
 * (single edge, or an edge plus the two perpendicular edges). */
static void work_area_recompute(void)
{
    g_excl_top = g_excl_bottom = g_excl_left = g_excl_right = 0;
    for (int i = 0; i < g_nmapped; i++) {
        struct iosc_surface *s = g_mapped[i];
        if (s->role != IOSC_ROLE_LAYER || !s->layer) continue;
        struct iosc_layer_state *L = s->layer;
        if (L->excl_zone <= 0) continue;
        int a = L->anchor;
        int aT = a & ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP;
        int aB = a & ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM;
        int aL = a & ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT;
        int aR = a & ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT;
        if (aT && !aB)      g_excl_top    += L->excl_zone;
        else if (aB && !aT) g_excl_bottom += L->excl_zone;
        else if (aL && !aR) g_excl_left   += L->excl_zone;
        else if (aR && !aL) g_excl_right  += L->excl_zone;
    }
}

/* The usable desktop rectangle = output minus reserved (panel) edges. */
static void work_area(int *x, int *y, int *w, int *h)
{
    int ow = output_logical_width(), oh = output_logical_height();
    *x = g_excl_left;
    *y = g_excl_top;
    *w = ow - g_excl_left - g_excl_right;
    *h = oh - g_excl_top - g_excl_bottom;
    if (*w < 1) { *x = 0; *w = ow; }
    if (*h < 1) { *y = 0; *h = oh; }
}

/* Anchored placement + served size for a layer surface. */
static void layer_compute(struct iosc_surface *s, int *cw, int *ch, int *cx, int *cy)
{
    struct iosc_layer_state *L = s->layer;
    int ow = output_logical_width(), oh = output_logical_height();
    int a = L->anchor;
    int aT = a & ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP;
    int aB = a & ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM;
    int aL = a & ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT;
    int aR = a & ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT;

    int w = L->req_w > 0 ? L->req_w
          : (aL && aR) ? ow - L->margin_l - L->margin_r : ow;
    int h = L->req_h > 0 ? L->req_h
          : (aT && aB) ? oh - L->margin_t - L->margin_b : oh;
    if (w < 1) w = ow;
    if (h < 1) h = oh;

    int x;
    if (aL && !aR)      x = L->margin_l;
    else if (aR && !aL) x = ow - w - L->margin_r;
    else                x = (ow - w) / 2;
    int y;
    if (aT && !aB)      y = L->margin_t;
    else if (aB && !aT) y = oh - h - L->margin_b;
    else                y = (oh - h) / 2;

    *cw = w; *ch = h; *cx = x; *cy = y;
}

/* The top-most surface that may hold keyboard focus (topmost toplevel, or a
 * layer surface that requested keyboard interactivity). */
static struct iosc_surface *topmost_focusable(void)
{
    for (int i = g_nmapped - 1; i >= 0; i--) {
        struct iosc_surface *s = g_mapped[i];
        if (s->role == IOSC_ROLE_TOPLEVEL) return s;
        if (s->role == IOSC_ROLE_LAYER && s->layer &&
            s->layer->kbd_interactivity != ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_NONE)
            return s;
    }
    return NULL;
}

/* Compute the anchored size and send a layer_surface.configure the client acks. */
static void layer_send_configure(struct iosc_surface *s)
{
    struct iosc_layer_state *L = s->layer;
    if (!L || !L->resource) return;
    int cw, ch, cx, cy;
    layer_compute(s, &cw, &ch, &cx, &cy);
    L->cfg_w = cw;
    L->cfg_h = ch;
    L->configured = 1;
    uint32_t serial = wl_display_next_serial(g_display);
    zwlr_layer_surface_v1_send_configure(L->resource, serial,
                                         (uint32_t)cw, (uint32_t)ch);
}

static void surface_display_size(struct iosc_surface *s, int *w, int *h)
{
    int scale = s->current_buffer_scale > 0 ? s->current_buffer_scale : 1;
    if (s->viewport && s->viewport->has_dst) {
        *w = s->viewport->dst_w;
        *h = s->viewport->dst_h;
    } else if (s->viewport && s->viewport->has_src) {
        *w = buffer_to_logical(s->viewport->src_w, scale);
        *h = buffer_to_logical(s->viewport->src_h, scale);
    } else {
        *w = buffer_to_logical(s->sw, scale);
        *h = buffer_to_logical(s->sh, scale);
    }
}

static void surface_source_rect(struct iosc_surface *s, int *x, int *y, int *w, int *h)
{
    if (s->viewport && s->viewport->has_src) {
        *x = s->viewport->src_x;
        *y = s->viewport->src_y;
        *w = s->viewport->src_w;
        *h = s->viewport->src_h;
    } else {
        *x = 0;
        *y = 0;
        *w = s->sw;
        *h = s->sh;
    }
    if (*x < 0) *x = 0;
    if (*y < 0) *y = 0;
    if (*x + *w > s->sw) *w = s->sw - *x;
    if (*y + *h > s->sh) *h = s->sh - *y;
}

static void surface_place_child(struct iosc_surface *s)
{
    if (!s->parent) return;
    s->dx = s->parent->dx + s->rel_x;
    s->dy = s->parent->dy + s->rel_y;
}

static void presentation_feedback_destroy(struct wl_resource *r)
{
    struct iosc_presentation_feedback *fb = wl_resource_get_user_data(r);
    if (!fb) return;
    wl_list_remove(&fb->link);
    free(fb);
}

static void presentation_present_surface(struct iosc_surface *s)
{
    if (wl_list_empty(&s->presentation_feedbacks)) return;
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    uint64_t sec = (uint64_t)ts.tv_sec;
    uint64_t seq = ++g_presentation_seq;
    struct iosc_presentation_feedback *fb, *tmp;
    wl_list_for_each_safe(fb, tmp, &s->presentation_feedbacks, link) {
        wp_presentation_feedback_send_presented(
            fb->resource,
            (uint32_t)(sec >> 32), (uint32_t)sec, (uint32_t)ts.tv_nsec,
            16666666u,
            (uint32_t)(seq >> 32), (uint32_t)seq,
            0);
        wl_resource_destroy(fb->resource);
    }
}

static void presentation_discard_surface(struct iosc_surface *s)
{
    struct iosc_presentation_feedback *fb, *tmp;
    wl_list_for_each_safe(fb, tmp, &s->presentation_feedbacks, link) {
        wp_presentation_feedback_send_discarded(fb->resource);
        wl_resource_destroy(fb->resource);
    }
}

/* CPU-fallback blit of the top wl_shm surface. Kept simple; the ANGLE/GPU path is
 * the native path and handles IOSurface clients. */
static void cpu_blit_shm(struct iosc_surface *s)
{
    struct wl_resource *buffer = s->current_buffer;
    struct wl_shm_buffer *shm = wl_shm_buffer_get(buffer);
    if (!shm) return;
    int dw = 0, dh = 0, sx = 0, sy = 0, src_w = 0, src_h = 0;
    surface_display_size(s, &dw, &dh);
    surface_source_rect(s, &sx, &sy, &src_w, &src_h);
    int os = output_scale();
    int dxp = s->dx * os, dyp = s->dy * os, dwp = dw * os, dhp = dh * os;
    if (dwp <= 0 || dhp <= 0 || src_w <= 0 || src_h <= 0) return;
    wl_shm_buffer_begin_access(shm);
    const uint8_t *src = wl_shm_buffer_get_data(shm);
    int src_stride = wl_shm_buffer_get_stride(shm);
    int max_y = dyp + dhp; if (max_y > g_height) max_y = g_height;
    int max_x = dxp + dwp; if (max_x > g_width) max_x = g_width;
    for (int y = dyp; y < max_y; y++) {
        int src_y = sy + (int)((long long)(y - dyp) * src_h / dhp);
        uint32_t *dst = (uint32_t *)(g_fb + (size_t)y * g_stride);
        const uint32_t *row = (const uint32_t *)(src + (size_t)src_y * src_stride);
        for (int x = dxp; x < max_x; x++) {
            int src_x = sx + (int)((long long)(x - dxp) * src_w / dwp);
            dst[x] = row[src_x];
        }
    }
    wl_shm_buffer_end_access(shm);
}

/* ---- iosc_iosurface: zero-copy GPU buffers (ANGLE-Metal clients) ---------- */

/* A wl_buffer backed by a client IOSurface imported over the iosc_iosurface
 * protocol (see iosc-iosurface.xml). The compositor reached into the client's
 * task to look the surface up; ib->surface is a retained IOSurfaceRef (opaque). */
struct iosc_iosurface_buffer {
    void *surface;   /* imported IOSurfaceRef (from xios_import_client_iosurface) */
    int   w, h;
};

static void iosurface_buffer_destroy(struct wl_client *c, struct wl_resource *r)
{ (void)c; wl_resource_destroy(r); }
static const struct wl_buffer_interface iosurface_buffer_impl = {
    .destroy = iosurface_buffer_destroy,
};
static void iosurface_buffer_resource_destroy(struct wl_resource *r)
{
    struct iosc_iosurface_buffer *ib = wl_resource_get_user_data(r);
    if (!ib) return;
    if (ib->surface) {
        iosc_gl_forget_iosurface(ib->surface);   /* drop the cached GL texture/pbuffer */
        xios_release_client_iosurface(ib->surface);
    }
    free(ib);
}

/* ---- single-pixel-buffer-v1: 1x1 solid-colour wl_buffer ------------------- */

/* A wp_single_pixel_buffer is a 1x1 wl_buffer holding a premultiplied RGBA colour
 * (each channel a value/0xFFFFFFFF fraction). Clients (GTK, CSD shadows, solid
 * backdrops) attach it and scale it up with wp_viewporter. We store the colour as
 * BGRA8 so the composite path can feed it straight to iosc_gl_draw_shm as a 1x1
 * texture; GL sampling of the single texel fills the whole destination rect. */
struct iosc_single_pixel_buffer {
    uint8_t bgra[4];   /* BGRA8, premultiplied (matches the wl_shm output format) */
};

static void spb_buffer_destroy(struct wl_client *c, struct wl_resource *r)
{ (void)c; wl_resource_destroy(r); }
static const struct wl_buffer_interface spb_buffer_impl = {
    .destroy = spb_buffer_destroy,
};
static void spb_buffer_resource_destroy(struct wl_resource *r)
{
    free(wl_resource_get_user_data(r));
}

static void spb_mgr_destroy(struct wl_client *c, struct wl_resource *r)
{ (void)c; wl_resource_destroy(r); }

static void spb_mgr_create_u32_rgba(struct wl_client *c, struct wl_resource *r,
                                    uint32_t id, uint32_t rr, uint32_t gg,
                                    uint32_t bb, uint32_t aa)
{ (void)r;
    struct iosc_single_pixel_buffer *spb = calloc(1, sizeof(*spb));
    if (!spb) { wl_client_post_no_memory(c); return; }
    /* uint32 fraction (value/0xFFFFFFFF) -> 8-bit; +0x800000 rounds to nearest. */
    spb->bgra[0] = (uint8_t)((bb + 0x800000u) >> 24);
    spb->bgra[1] = (uint8_t)((gg + 0x800000u) >> 24);
    spb->bgra[2] = (uint8_t)((rr + 0x800000u) >> 24);
    spb->bgra[3] = (uint8_t)((aa + 0x800000u) >> 24);
    struct wl_resource *buf = wl_resource_create(c, &wl_buffer_interface, 1, id);
    if (!buf) { free(spb); wl_client_post_no_memory(c); return; }
    wl_resource_set_implementation(buf, &spb_buffer_impl, spb, spb_buffer_resource_destroy);
}

static const struct wp_single_pixel_buffer_manager_v1_interface spb_mgr_impl = {
    .destroy = spb_mgr_destroy,
    .create_u32_rgba_buffer = spb_mgr_create_u32_rgba,
};

static void spb_mgr_bind(struct wl_client *client, void *data, uint32_t version, uint32_t id)
{ (void)data;
    struct wl_resource *r = wl_resource_create(client,
        &wp_single_pixel_buffer_manager_v1_interface, version, id);
    if (!r) { wl_client_post_no_memory(client); return; }
    wl_resource_set_implementation(r, &spb_mgr_impl, NULL, NULL);
}

/* ---- surface buffer retention + z-order management (M2) ------------------- */

/* Draw one surface's current buffer as a GPU quad at a logical output position. */
static void composite_surface_at(struct iosc_surface *s, int lx, int ly)
{
    struct wl_resource *buf = s->current_buffer;
    if (!buf) return;
    int dw = 0, dh = 0;
    int sx = 0, sy = 0, src_w = 0, src_h = 0;
    surface_display_size(s, &dw, &dh);
    surface_source_rect(s, &sx, &sy, &src_w, &src_h);
    if (dw <= 0 || dh <= 0 || src_w <= 0 || src_h <= 0) return;
    int os = output_scale();
    int dxp = lx * os, dyp = ly * os, dwp = dw * os, dhp = dh * os;
    struct wl_shm_buffer *shm = wl_shm_buffer_get(buf);
    if (shm) {
        /* Cache one GL texture per surface (keyed by `s`), re-uploaded only when
         * the surface committed new content (gl_dirty). A recomposite driven by a
         * cursor move re-draws every window but uploads none of them. */
        wl_shm_buffer_begin_access(shm);
        iosc_gl_draw_shm(s, s->gl_dirty, wl_shm_buffer_get_data(shm),
                         wl_shm_buffer_get_width(shm), wl_shm_buffer_get_height(shm),
                         wl_shm_buffer_get_stride(shm), sx, sy, src_w, src_h,
                         dxp, dyp, dwp, dhp);
        wl_shm_buffer_end_access(shm);
        s->gl_dirty = 0;
    } else if (wl_resource_instance_of(buf, &wl_buffer_interface, &iosurface_buffer_impl)) {
        struct iosc_iosurface_buffer *ib = wl_resource_get_user_data(buf);
        if (ib && ib->surface)
            iosc_gl_draw_iosurface(ib->surface, ib->w, ib->h, sx, sy, src_w, src_h,
                                   dxp, dyp, dwp, dhp);
    } else if (wl_resource_instance_of(buf, &wl_buffer_interface, &spb_buffer_impl)) {
        struct iosc_single_pixel_buffer *spb = wl_resource_get_user_data(buf);
        if (spb)   /* 1x1 texel, sampled across the whole destination rect (uncached) */
            iosc_gl_draw_shm(NULL, 1, spb->bgra, 1, 1, 4, 0, 0, 1, 1, dxp, dyp, dwp, dhp);
    }
}

static void composite_one(struct iosc_surface *s)
{
    composite_surface_at(s, s->dx, s->dy);
}

/* ---- cursor-shape-v1: compositor-drawn named cursors --------------------- *
 * iosc loads no XCursor theme; clients that use cursor-shape-v1 (GTK4/Adwaita
 * PREFER it and then never upload a wl_pointer cursor surface) would otherwise
 * get no cursor. We rasterize a small built-in set of premultiplied-BGRA bitmaps
 * procedurally and draw the chosen shape in composite_cursor(), so the pointer
 * never vanishes and the common shapes read correctly. A set_shape and a client
 * wl_pointer.set_cursor supersede each other (last request wins). */

#define IOSC_CUR_DIM 24                 /* max logical bitmap size (px) */
static uint32_t g_named_cursor;         /* wp_cursor_shape enum; 0 = use client surface */
static uint8_t  g_cur_bmp[IOSC_CUR_DIM * IOSC_CUR_DIM * 4];   /* premultiplied BGRA */
static int      g_cur_w, g_cur_h, g_cur_hotx, g_cur_hoty;

static void cur_px(int x, int y, uint8_t r, uint8_t g, uint8_t b, uint8_t a)
{
    if (x < 0 || y < 0 || x >= g_cur_w || y >= g_cur_h) return;
    uint8_t *p = &g_cur_bmp[(y * g_cur_w + x) * 4];
    p[0] = (uint8_t)((unsigned)b * a / 255);
    p[1] = (uint8_t)((unsigned)g * a / 255);
    p[2] = (uint8_t)((unsigned)r * a / 255);
    p[3] = a;
}
static void cur_fill(int x, int y) { cur_px(x, y, 0, 0, 0, 255); }         /* black */
static void cur_hline(int x0, int x1, int y) { for (int x = x0; x <= x1; x++) cur_fill(x, y); }
static void cur_vline(int x, int y0, int y1) { for (int y = y0; y <= y1; y++) cur_fill(x, y); }

/* Give every black glyph a 1px white halo so it reads on any background. */
static void cur_outline(void)
{
    static const int dx[8] = { -1, 1, 0, 0, -1, -1, 1, 1 };
    static const int dy[8] = { 0, 0, -1, 1, -1, 1, -1, 1 };
    uint8_t snap[IOSC_CUR_DIM * IOSC_CUR_DIM];
    for (int i = 0; i < g_cur_w * g_cur_h; i++) snap[i] = g_cur_bmp[i * 4 + 3];
    for (int y = 0; y < g_cur_h; y++)
        for (int x = 0; x < g_cur_w; x++) {
            if (snap[y * g_cur_w + x]) continue;
            for (int k = 0; k < 8; k++) {
                int nx = x + dx[k], ny = y + dy[k];
                if (nx >= 0 && ny >= 0 && nx < g_cur_w && ny < g_cur_h &&
                    snap[ny * g_cur_w + nx]) { cur_px(x, y, 255, 255, 255, 255); break; }
            }
        }
}

/* Classic left_ptr arrow, hotspot at the tip (0,0). Authored 12x19 mask. */
static void cur_build_arrow(void)
{
    static const char *art[19] = {
        "X           ", "XX          ", "XXX         ", "XXXX        ",
        "XXXXX       ", "XXXXXX      ", "XXXXXXX     ", "XXXXXXXX    ",
        "XXXXXXXXX   ", "XXXXXXXXXX  ", "XXXXXXXXXXX ", "XXXXXXXXXXXX",
        "XXXXXXX     ", "XXXXXXX     ", "XXXX XXX    ", "XXX  XXX    ",
        "XX    XXX   ", "       XXX  ", "       XXX  ",
    };
    for (int y = 0; y < 19; y++)
        for (int x = 0; art[y][x]; x++)
            if (art[y][x] == 'X') cur_fill(x, y);
    cur_outline();
    g_cur_hotx = 0; g_cur_hoty = 0;
}

static void cur_build_ibeam(void)
{
    int cx = 5, top = 2, bot = 18;
    cur_vline(cx, top, bot);
    cur_hline(cx - 2, cx + 2, top);     cur_hline(cx - 2, cx + 2, bot);
    cur_hline(cx - 1, cx + 1, top + 1); cur_hline(cx - 1, cx + 1, bot - 1);
    cur_outline();
    g_cur_hotx = cx; g_cur_hoty = (top + bot) / 2;
}

static void cur_build_cross(void)
{
    int c = 10;
    cur_hline(1, 19, c); cur_vline(c, 1, 19);
    cur_outline();
    g_cur_hotx = c; g_cur_hoty = c;
}

/* dir: 0=ns 1=ew 2=nesw 3=nwse. Hotspot centre. */
static void cur_build_resize(int dir)
{
    int c = 10;
    if (dir == 0) {
        cur_vline(c, 2, 18);
        for (int i = 0; i <= 4; i++) { cur_hline(c - i, c + i, 2 + i); cur_hline(c - i, c + i, 18 - i); }
    } else if (dir == 1) {
        cur_hline(2, 18, c);
        for (int i = 0; i <= 4; i++) { cur_vline(2 + i, c - i, c + i); cur_vline(18 - i, c - i, c + i); }
    } else {
        for (int t = 3; t <= 17; t++) { int u = (dir == 3) ? t : (20 - t); cur_fill(t, u); cur_fill(t, u + 1); }
    }
    cur_outline();
    g_cur_hotx = c; g_cur_hoty = c;
}

static void cur_build_move(void)
{
    int c = 10;
    cur_hline(3, 17, c); cur_vline(c, 3, 17);
    for (int i = 0; i <= 4; i++) {
        cur_hline(c - i, c + i, 3 + i); cur_hline(c - i, c + i, 17 - i);
        cur_vline(3 + i, c - i, c + i); cur_vline(17 - i, c - i, c + i);
    }
    cur_outline();
    g_cur_hotx = c; g_cur_hoty = c;
}

/* not_allowed / no_drop: circle + slash (trig-free distance test). */
static void cur_build_noentry(void)
{
    int c = 10, rad = 8;
    for (int y = 0; y < g_cur_h; y++)
        for (int x = 0; x < g_cur_w; x++) {
            int d2 = (x - c) * (x - c) + (y - c) * (y - c);
            if (d2 <= rad * rad && d2 >= (rad - 2) * (rad - 2)) cur_fill(x, y);
        }
    for (int t = -(rad - 1); t <= (rad - 1); t++) { cur_fill(c + t, c + t); cur_fill(c + t + 1, c + t); }
    cur_outline();
    g_cur_hotx = c; g_cur_hoty = c;
}

static void cursor_build_shape(uint32_t shape)
{
    g_cur_w = IOSC_CUR_DIM; g_cur_h = IOSC_CUR_DIM;
    memset(g_cur_bmp, 0, sizeof(g_cur_bmp));
    g_cur_hotx = 0; g_cur_hoty = 0;
    switch (shape) {
        case WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_TEXT:
        case WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_VERTICAL_TEXT: cur_build_ibeam(); break;
        case WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_CROSSHAIR:
        case WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_CELL:          cur_build_cross(); break;
        case WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_N_RESIZE:
        case WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_S_RESIZE:
        case WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_NS_RESIZE:
        case WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_ROW_RESIZE:    cur_build_resize(0); break;
        case WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_E_RESIZE:
        case WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_W_RESIZE:
        case WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_EW_RESIZE:
        case WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_COL_RESIZE:    cur_build_resize(1); break;
        case WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_NE_RESIZE:
        case WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_SW_RESIZE:
        case WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_NESW_RESIZE:   cur_build_resize(2); break;
        case WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_NW_RESIZE:
        case WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_SE_RESIZE:
        case WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_NWSE_RESIZE:   cur_build_resize(3); break;
        case WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_MOVE:
        case WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_ALL_SCROLL:    cur_build_move(); break;
        case WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_NOT_ALLOWED:
        case WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_NO_DROP:       cur_build_noentry(); break;
        default:                                            cur_build_arrow(); break;
    }
}

static void composite_named_cursor(void)
{
    if (!g_cur_w || !g_cur_h) return;
    int os = output_scale();
    int lx = g_cursor_x - g_cur_hotx, ly = g_cursor_y - g_cur_hoty;
    iosc_gl_begin_cursor();
    iosc_gl_draw_shm(NULL, 1, g_cur_bmp, g_cur_w, g_cur_h, g_cur_w * 4,
                     0, 0, g_cur_w, g_cur_h,
                     lx * os, ly * os, g_cur_w * os, g_cur_h * os);
    iosc_gl_end_cursor();
}

static void cshape_dev_destroy(struct wl_client *c, struct wl_resource *r)
{ (void)c; wl_resource_destroy(r); }

static void cshape_dev_set_shape(struct wl_client *c, struct wl_resource *r,
                                 uint32_t serial, uint32_t shape)
{ (void)c; (void)serial;
    if (shape < 1 || shape > WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_ZOOM_OUT) {
        wl_resource_post_error(r, WP_CURSOR_SHAPE_DEVICE_V1_ERROR_INVALID_SHAPE,
                               "invalid cursor shape %u", shape);
        return;
    }
    g_named_cursor = shape;         /* named shape supersedes any client surface cursor */
    g_cursor_surface = NULL;
    cursor_build_shape(shape);
    g_cursor_visible = 1;
    if (iosc_app_cursor()) app_cursor_notify();   /* overlay: push the new shape, no repaint */
    else recomposite_all();
}

static const struct wp_cursor_shape_device_v1_interface cshape_dev_impl = {
    .destroy = cshape_dev_destroy,
    .set_shape = cshape_dev_set_shape,
};

static void cshape_mgr_destroy(struct wl_client *c, struct wl_resource *r)
{ (void)c; wl_resource_destroy(r); }

static void cshape_make_device(struct wl_client *c, struct wl_resource *r, uint32_t id)
{
    struct wl_resource *dev = wl_resource_create(c, &wp_cursor_shape_device_v1_interface,
                                                 wl_resource_get_version(r), id);
    if (!dev) { wl_client_post_no_memory(c); return; }
    wl_resource_set_implementation(dev, &cshape_dev_impl, NULL, NULL);
}
static void cshape_mgr_get_pointer(struct wl_client *c, struct wl_resource *r,
                                   uint32_t id, struct wl_resource *pointer)
{ (void)pointer; cshape_make_device(c, r, id); }
static void cshape_mgr_get_tablet_tool_v2(struct wl_client *c, struct wl_resource *r,
                                          uint32_t id, struct wl_resource *tool)
{ (void)tool; cshape_make_device(c, r, id); }

static const struct wp_cursor_shape_manager_v1_interface cshape_mgr_impl = {
    .destroy = cshape_mgr_destroy,
    .get_pointer = cshape_mgr_get_pointer,
    .get_tablet_tool_v2 = cshape_mgr_get_tablet_tool_v2,
};

static void cshape_mgr_bind(struct wl_client *client, void *data, uint32_t version, uint32_t id)
{ (void)data;
    struct wl_resource *r = wl_resource_create(client, &wp_cursor_shape_manager_v1_interface, version, id);
    if (!r) { wl_client_post_no_memory(client); return; }
    wl_resource_set_implementation(r, &cshape_mgr_impl, NULL, NULL);
}

static void composite_cursor(void)
{
    if (iosc_app_cursor()) return;   /* the app draws the pointer as a present-side overlay */
    if (g_named_cursor) { if (g_cursor_visible) composite_named_cursor(); return; }
    if (!g_cursor_visible || !g_cursor_surface || !g_cursor_surface->current_buffer) return;
    /* The cursor is a premultiplied ARGB8888 wl_shm surface: blend it so its alpha is
     * honored, otherwise the transparent pixels around the arrow draw as a black box. */
    iosc_gl_begin_cursor();
    composite_surface_at(g_cursor_surface,
                         g_cursor_x - g_cursor_hot_x,
                         g_cursor_y - g_cursor_hot_y);
    iosc_gl_end_cursor();
}

/* IOSC_PROBE classifier: map a BGRA output pixel to a legend char for the app-space
 * map below. Tolerant match (GL_LINEAR sampling + GPU rounding shift colours a bit). */
static char probe_ch(uint32_t p)
{
    int b = p & 0xff, g = (p >> 8) & 0xff, r = (p >> 16) & 0xff;
#define IOSC_NEAR(v, t) ((v) >= (t) - 28 && (v) <= (t) + 28)
    if (IOSC_NEAR(b,0)   && IOSC_NEAR(g,0)   && IOSC_NEAR(r,0))   return '.';  /* black bg        */
    if (IOSC_NEAR(b,128) && IOSC_NEAR(g,128) && IOSC_NEAR(r,0))   return 't';  /* teal clear      */
    if (IOSC_NEAR(b,0)   && IOSC_NEAR(g,128) && IOSC_NEAR(r,255)) return 'O';  /* orange triangle */
    if (IOSC_NEAR(b,143) && IOSC_NEAR(g,58)  && IOSC_NEAR(r,32))  return 'b';  /* blue field      */
    if (IOSC_NEAR(b,48)  && IOSC_NEAR(g,192) && IOSC_NEAR(r,48))  return 'g';  /* green border    */
    if (IOSC_NEAR(b,32)  && IOSC_NEAR(g,32)  && IOSC_NEAR(r,224)) return 'r';  /* red diagonal    */
#undef IOSC_NEAR
    return '?';
}

/* IOSC_DEBUG=1 turns on the per-frame validation readbacks + logs. They call
 * glReadPixels (a synchronous GPU->CPU stall) and fprintf every recompose, so
 * they must stay OFF in normal operation. Event-driven logs (focus, drag, lock,
 * tablet) are not gated by this — only the per-frame spam is. Cached once. */
static int iosc_debug(void)
{
    static int v = -1;
    if (v < 0) v = getenv("IOSC_DEBUG") ? 1 : 0;
    return v;
}

/* IOSC_APP_CURSOR=1: hand the pointer to a present-side overlay in the Xios app.
 * iosc stops compositing the cursor into the output IOSurface and instead signals
 * position + shape over the app socket (xios_notify_cursor), so a plain cursor
 * MOVE costs one 32-byte socket write and ZERO recomposite (the P0.2/P0.4 capstone)
 * instead of a full-screen GPU repaint. Off by default = classic composited cursor
 * (no regression); the lead flips it on in the batched Xios rebuild that adds the
 * overlay + typed-socket support. */
static int iosc_app_cursor(void)
{
    static int v = -1;
    if (v < 0) v = getenv("IOSC_APP_CURSOR") ? 1 : 0;
    return v;
}

/* Signal the current pointer position + shape to the app's cursor overlay. The
 * shape is the wp_cursor_shape id for a named cursor; a client-supplied cursor
 * surface maps to the default arrow for now (bitmap streaming is a v2 — see the
 * XIOS_MSG_CURSOR payload). shape 0 = hidden. */
static void app_cursor_notify(void)
{
    int shape = !g_cursor_visible ? 0
              : g_named_cursor ? (int)g_named_cursor
              : WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_DEFAULT;   /* client surface -> default */
    xios_notify_cursor(g_cursor_x, g_cursor_y, g_cursor_visible, shape);
}

/* Recomposite ALL mapped surfaces back-to-front onto the output, on the GPU.
 * Synchronous: paints immediately. Most callers should use recomposite_all()
 * (coalesced) instead; recomposite_now() is for paths that read the output back
 * in the same call (screencopy). */
static void recomposite_now(void)
{
    if (iosc_gl_ok()) {
        iosc_gl_begin();   /* clears the output to black (desktop background) */
        if (g_slock.locked) {
            /* Session locked: ONLY the lock surface may show (blank until it
             * maps); windows, layer shells and the drag icon must not leak. */
            if (g_slock.surface && g_slock.surface->current_buffer)
                composite_one(g_slock.surface);
            composite_cursor();
            iosc_gl_end();
            xios_notify_dirty();
            if (iosc_debug())
                fprintf(stderr, "iosc: recomposited (session locked; lock surface %s)\n",
                        g_slock.surface && g_slock.surface->current_buffer ? "shown" : "pending");
            return;
        }
        for (int i = 0; i < g_nmapped; i++)
            composite_one(g_mapped[i]);
        /* Drag icon rides above the windows, just under the cursor (blended). */
        if (g_dnd.active && g_dnd.icon && g_dnd.icon->current_buffer) {
            iosc_gl_begin_cursor();
            composite_surface_at(g_dnd.icon, g_cursor_x, g_cursor_y);
            iosc_gl_end_cursor();
        }
        composite_cursor();
        iosc_gl_end();
        xios_notify_dirty();
        /* Validation (IOSC_DEBUG only — each readback is a synchronous GPU->CPU
         * stall): read every window's EXPOSED top-left corner (a lower window's
         * center is occluded by the one cascaded over it), proving each is present
         * at its placement; `center` shows the top window wins the overlap. */
        if (iosc_debug()) {
            fprintf(stderr, "iosc: recomposited %d surface(s) on GPU:", g_nmapped);
            for (int i = 0; i < g_nmapped; i++) {
                struct iosc_surface *s = g_mapped[i];
                int os = output_scale();
                uint32_t px = iosc_gl_read_at((s->dx + 30) * os, (s->dy + 30) * os);
                fprintf(stderr, " [w%d @%d,%d corner=0x%08x]", i, s->dx, s->dy, px);
            }
            fprintf(stderr, " overlap-center=0x%08x\n", iosc_gl_read_center());
        }
        /* IOSC_PROBE=1: app-space 2D map of the WHOLE output (top-left origin = what
         * the app actually displays), rows top->bottom, cols left->right. Legend:
         * '.'=bg t=teal O=orange b=blue g=green r=red ?=other. Reveals both window
         * placement and content orientation source-agnostically. For the GPU triangle
         * (apex up) UPRIGHT looks like an orange wedge narrow at TOP, wide at BOTTOM;
         * for the wl_shm client the red diagonal runs top-left -> bottom-right. */
        if (getenv("IOSC_PROBE")) {
            fprintf(stderr, "iosc: app-space %dx%d map (top-left origin):\n",
                    g_width, g_height);
            for (int ry = 0; ry <= 12; ry++) {
                int y = (int)((long)ry * (g_height - 1) / 12);
                char row[40]; int rc = 0;
                for (int rx = 0; rx <= 24; rx++) {
                    int x = (int)((long)rx * (g_width - 1) / 24);
                    row[rc++] = probe_ch(xios_read_output_pixel(x, y));
                }
                row[rc] = 0;
                fprintf(stderr, "   %s\n", row);
            }
        }
        return;
    }
    /* CPU fallback: only the top surface, top-left (no multi-surface on CPU). */
    if (g_nmapped == 0) return;
    struct iosc_surface *s = g_mapped[g_nmapped - 1];
    if (!s->current_buffer) return;
    if (wl_shm_buffer_get(s->current_buffer)) cpu_blit_shm(s);
    else if (output_scale() == 1 &&
             wl_resource_instance_of(s->current_buffer, &wl_buffer_interface, &iosurface_buffer_impl)) {
        struct iosc_iosurface_buffer *ib = wl_resource_get_user_data(s->current_buffer);
        if (ib && ib->surface) xios_blit_client_iosurface(ib->surface);
    }
    xios_notify_dirty();
}

/* Coalesce repaints: a burst of commits, input events, or state changes in one
 * event-loop iteration all funnel through recomposite_all(), but we only paint
 * ONCE — scheduled as a one-shot idle that runs after the current events are
 * processed, before the loop blocks again. Without this, e.g. an input-socket
 * read that drains several motion messages, or several clients committing on the
 * same wakeup, each forced a full GPU recomposite. */
static int g_recompose_scheduled;
static void recompose_idle(void *data)
{
    (void)data;
    g_recompose_scheduled = 0;
    recomposite_now();
}
static void recomposite_all(void)
{
    if (g_recompose_scheduled) return;
    struct wl_event_loop *loop = g_display ? wl_display_get_event_loop(g_display) : NULL;
    /* Before the event loop is running (early bring-up), paint synchronously. */
    if (!loop || !wl_event_loop_add_idle(loop, recompose_idle, NULL)) {
        recomposite_now();
        return;
    }
    g_recompose_scheduled = 1;
}

/* ---- wlr-screencopy-v1: screenshots (SOFTWARE readback; GPU-blit later) --- *
 * A client (grim, xdg-desktop-portal, spectacle) binds the manager, asks to
 * capture the output (or a sub-region), receives a `buffer` event advertising the
 * format/size/stride to allocate, allocates a wl_shm buffer, and calls copy().
 * We read the composited output IOSurface back into that buffer via
 * xios_read_output_region() -- the SOFTWARE path. The clean seam for a future GPU
 * blit (output IOSurface -> the client's IOSurface-backed buffer, no CPU
 * round-trip) is xios_read_output_region()'s body plus a fast-path here; the
 * protocol code below stays unchanged. */

struct iosc_screencopy_frame {
    struct wl_resource *resource;
    int      x, y, w, h;       /* capture rect in output (physical) px */
    int      stride;           /* advertised buffer stride (w*4) */
    uint32_t format;           /* advertised wl_shm format */
    int      with_cursor;      /* overlay_cursor: include the pointer in the shot */
    int      used;             /* copy() may be called at most once */
};

static void screencopy_frame_res_destroy(struct wl_resource *r)
{ free(wl_resource_get_user_data(r)); }

static void screencopy_frame_destroy(struct wl_client *c, struct wl_resource *r)
{ (void)c; wl_resource_destroy(r); }

/* Read the composited output into the client's wl_shm buffer, honouring
 * overlay_cursor by recompositing without the pointer when it isn't wanted. */
static void screencopy_do_copy(struct iosc_screencopy_frame *f, struct wl_resource *buffer)
{
    struct wl_shm_buffer *shm = wl_shm_buffer_get(buffer);
    if (!shm ||
        wl_shm_buffer_get_format(shm) != f->format ||
        wl_shm_buffer_get_width(shm)  != f->w ||
        wl_shm_buffer_get_height(shm) != f->h ||
        wl_shm_buffer_get_stride(shm) != f->stride) {
        zwlr_screencopy_frame_v1_send_failed(f->resource);
        return;
    }

    int restore_cursor = 0;
    if (!f->with_cursor && g_cursor_visible) { g_cursor_visible = 0; restore_cursor = 1; }
    recomposite_now();          /* synchronous: the readback below needs THIS frame */

    wl_shm_buffer_begin_access(shm);
    int rc = xios_read_output_region(f->x, f->y, f->w, f->h,
                                     wl_shm_buffer_get_data(shm), f->stride);
    wl_shm_buffer_end_access(shm);

    if (restore_cursor) { g_cursor_visible = 1; recomposite_now(); }

    if (rc != 0) { zwlr_screencopy_frame_v1_send_failed(f->resource); return; }

    /* Top-left origin, no transform: no y-invert. Then report ready. */
    zwlr_screencopy_frame_v1_send_flags(f->resource, 0);
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    uint64_t sec = (uint64_t)ts.tv_sec;
    zwlr_screencopy_frame_v1_send_ready(f->resource,
        (uint32_t)(sec >> 32), (uint32_t)sec, (uint32_t)ts.tv_nsec);
}

static void screencopy_frame_copy(struct wl_client *c, struct wl_resource *r,
                                  struct wl_resource *buffer)
{ (void)c;
    struct iosc_screencopy_frame *f = wl_resource_get_user_data(r);
    if (!f) return;
    if (f->used) {
        wl_resource_post_error(r, ZWLR_SCREENCOPY_FRAME_V1_ERROR_ALREADY_USED,
                               "screencopy frame already used");
        return;
    }
    f->used = 1;
    screencopy_do_copy(f, buffer);
}

static void screencopy_frame_copy_with_damage(struct wl_client *c, struct wl_resource *r,
                                              struct wl_resource *buffer)
{
    /* We don't track per-frame damage; a full copy is correct (just not optimal).
     * The damage event is optional, so we simply don't send one. */
    screencopy_frame_copy(c, r, buffer);
}

static const struct zwlr_screencopy_frame_v1_interface screencopy_frame_impl = {
    .copy = screencopy_frame_copy,
    .destroy = screencopy_frame_destroy,
    .copy_with_damage = screencopy_frame_copy_with_damage,
};

/* Create + advertise a frame for the given capture rect (already clamped). */
static void screencopy_new_frame(struct wl_client *c, struct wl_resource *mgr,
                                 uint32_t id, int overlay_cursor,
                                 int x, int y, int w, int h)
{
    struct iosc_screencopy_frame *f = calloc(1, sizeof(*f));
    if (!f) { wl_client_post_no_memory(c); return; }
    f->x = x; f->y = y; f->w = w; f->h = h;
    f->stride = w * 4;
    f->format = WL_SHM_FORMAT_XRGB8888;    /* opaque BGRA8 in memory == our output */
    f->with_cursor = overlay_cursor;
    f->resource = wl_resource_create(c, &zwlr_screencopy_frame_v1_interface,
                                     wl_resource_get_version(mgr), id);
    if (!f->resource) { free(f); wl_client_post_no_memory(c); return; }
    wl_resource_set_implementation(f->resource, &screencopy_frame_impl, f,
                                   screencopy_frame_res_destroy);
    zwlr_screencopy_frame_v1_send_buffer(f->resource, f->format,
                                         (uint32_t)w, (uint32_t)h, (uint32_t)f->stride);
    if (wl_resource_get_version(f->resource) >= ZWLR_SCREENCOPY_FRAME_V1_BUFFER_DONE_SINCE_VERSION)
        zwlr_screencopy_frame_v1_send_buffer_done(f->resource);
}

static void screencopy_capture_output(struct wl_client *c, struct wl_resource *mgr,
                                      uint32_t id, int32_t overlay_cursor,
                                      struct wl_resource *output)
{ (void)output;
    screencopy_new_frame(c, mgr, id, overlay_cursor, 0, 0, g_width, g_height);
}

static void screencopy_capture_output_region(struct wl_client *c, struct wl_resource *mgr,
                                             uint32_t id, int32_t overlay_cursor,
                                             struct wl_resource *output,
                                             int32_t x, int32_t y, int32_t w, int32_t h)
{ (void)output;
    if (x < 0) { w += x; x = 0; }
    if (y < 0) { h += y; y = 0; }
    if (x + w > g_width)  w = g_width  - x;
    if (y + h > g_height) h = g_height - y;
    if (w <= 0 || h <= 0) { x = 0; y = 0; w = 1; h = 1; }   /* degenerate -> 1px */
    screencopy_new_frame(c, mgr, id, overlay_cursor, x, y, w, h);
}

static void screencopy_mgr_destroy(struct wl_client *c, struct wl_resource *r)
{ (void)c; wl_resource_destroy(r); }

static const struct zwlr_screencopy_manager_v1_interface screencopy_mgr_impl = {
    .capture_output = screencopy_capture_output,
    .capture_output_region = screencopy_capture_output_region,
    .destroy = screencopy_mgr_destroy,
};

static void screencopy_mgr_bind(struct wl_client *client, void *data, uint32_t version, uint32_t id)
{ (void)data;
    struct wl_resource *r = wl_resource_create(client, &zwlr_screencopy_manager_v1_interface, version, id);
    if (!r) { wl_client_post_no_memory(client); return; }
    wl_resource_set_implementation(r, &screencopy_mgr_impl, NULL, NULL);
}

static void on_buffer_destroyed(struct wl_listener *l, void *data)
{
    (void)data;
    struct iosc_surface *s = wl_container_of(l, s, buffer_destroy);
    s->current_buffer = NULL;          /* listener auto-removed by libwayland */
    s->buffer_listener_active = 0;
}

/* Replace a surface's current buffer; release the old one (double-buffering). */
static void surface_set_buffer(struct iosc_surface *s, struct wl_resource *buf,
                               int sw, int sh, int send_release_on_old)
{
    if (s->current_buffer && s->current_buffer != buf) {
        if (s->buffer_listener_active) {
            wl_list_remove(&s->buffer_destroy.link);
            s->buffer_listener_active = 0;
        }
        if (send_release_on_old) wl_buffer_send_release(s->current_buffer);
    }
    s->current_buffer = buf;
    s->sw = sw; s->sh = sh;
    s->gl_dirty = 1;   /* new committed content: the cached shm texture is stale */
    if (buf && !s->buffer_listener_active) {
        s->buffer_destroy.notify = on_buffer_destroyed;
        wl_resource_add_destroy_listener(buf, &s->buffer_destroy);
        s->buffer_listener_active = 1;
    }
}

/* Add/remove a surface from the z-order list. Placement: layer surfaces are
 * anchored, children track their parent, toplevels cascade inside the work area.
 * The list stays sorted by z-band so panels/overlays stack above toplevels. */
static void surface_map(struct iosc_surface *s)
{
    if (s->mapped || g_nmapped >= IOSC_MAX_SURFACES) return;
    if (s->role == IOSC_ROLE_LAYER && s->layer) {
        int cw, ch, cx, cy;
        layer_compute(s, &cw, &ch, &cx, &cy);
        s->dx = cx;
        s->dy = cy;
    } else if (s->parent) {
        surface_place_child(s);
    } else {
        int wx, wy, ww, wh;
        work_area(&wx, &wy, &ww, &wh);
        int n = 0;                     /* cascade by toplevel count, not band */
        for (int i = 0; i < g_nmapped; i++)
            if (g_mapped[i]->role == IOSC_ROLE_TOPLEVEL) n++;
        s->dx = wx + 40 + n * 70;      /* cascade so windows visibly overlap */
        s->dy = wy + 40 + n * 70;
    }
    /* Insert at the end of this surface's z-band (first index with a higher band). */
    int band = surface_band(s);
    int idx = g_nmapped;
    for (int i = 0; i < g_nmapped; i++)
        if (surface_band(g_mapped[i]) > band) { idx = i; break; }
    for (int j = g_nmapped; j > idx; j--) g_mapped[j] = g_mapped[j - 1];
    g_mapped[idx] = s;
    g_nmapped++;
    s->mapped = 1;
    if (s->role == IOSC_ROLE_LAYER) work_area_recompute();
    fprintf(stderr, "iosc: surface mapped role=%d band=%d at (%d,%d); %d window(s)\n",
            s->role, band, s->dx, s->dy, g_nmapped);
    if (s->role == IOSC_ROLE_TOPLEVEL)
        ftl_toplevel_mapped(s);        /* announce to taskbar/foreign-toplevel clients */
    if (s->role == IOSC_ROLE_TOPLEVEL || s->role == IOSC_ROLE_POPUP)
        keyboard_set_focus(s);         /* newest shell surface takes keyboard focus */
    else if (s->role == IOSC_ROLE_LAYER && s->layer &&
             s->layer->kbd_interactivity != ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_NONE)
        keyboard_set_focus(s);         /* on_demand/exclusive layer takes focus */
}
static void surface_unmap(struct iosc_surface *s)
{
    /* A surface leaving mid-drag: a gone destination just drops the drag focus; a
     * gone origin/icon cancels the whole drag. Checked before the mapped gate
     * because the drag icon never maps yet still funnels through here from
     * surface_resource_destroy. */
    if (g_dnd.active) {
        if (g_dnd.focus == s) { g_dnd.focus = NULL; g_dnd.offer = NULL; g_dnd.target_accepted = 0; }
        if (g_dnd.origin == s || g_dnd.icon == s) {
            if (g_dnd.source) wl_data_source_send_cancelled(g_dnd.source);
            dnd_end();
        }
    }
    /* The lock surface going away mid-lock: back to a blank locked screen (the
     * session itself stays locked). Also before the mapped gate: never mapped. */
    if (g_slock.surface == s) {
        if (g_slock.lock_surface) wl_resource_set_user_data(g_slock.lock_surface, NULL);
        g_slock.lock_surface = NULL;
        g_slock.surface = NULL;
        if (g_kbd_focus == s) keyboard_set_focus(NULL);
        recomposite_all();
    }
    if (!s->mapped) return;
    if (s->role == IOSC_ROLE_TOPLEVEL)
        ftl_toplevel_closed(s);        /* remove from taskbar/foreign-toplevel clients */
    for (int i = 0; i < g_nmapped; i++)
        if (g_mapped[i] == s) {
            for (int j = i; j < g_nmapped - 1; j++) g_mapped[j] = g_mapped[j + 1];
            g_nmapped--;
            break;
        }
    s->mapped = 0;
    if (s->role == IOSC_ROLE_LAYER && s->layer) {
        /* Per protocol an unmapped layer surface returns to its post-get_layer_
         * surface state; a re-map redoes the no-buffer-commit -> configure dance. */
        s->layer->configured = 0;
        s->layer->acked = 0;
        work_area_recompute();
    }
    /* Drop focus that pointed at us; hand it to the top focusable window. */
    if (g_ptr_focus == s) g_ptr_focus = NULL;
    constraints_surface_gone(s);       /* release any pointer lock/confine on us */
    touch_surface_gone(s);             /* cancel touch sequences grabbed to us */
    pen_surface_gone(s);               /* pen leaves with its surface too */
    if (g_kbd_focus == s)
        keyboard_set_focus(topmost_focusable());
}

static void iosurface_factory_create_buffer(struct wl_client *client,
        struct wl_resource *res, uint32_t id, uint32_t mach_port_name,
        int32_t width, int32_t height, uint32_t format)
{
    (void)width; (void)height; (void)format;
    pid_t pid = 0; uid_t uid = 0; gid_t gid = 0;
    wl_client_get_credentials(client, &pid, &uid, &gid);

    int iw = 0, ih = 0;
    void *surf = xios_import_client_iosurface((int)pid, mach_port_name, &iw, &ih);

    struct iosc_iosurface_buffer *ib = calloc(1, sizeof(*ib));
    if (!ib) { if (surf) xios_release_client_iosurface(surf);
               wl_client_post_no_memory(client); return; }
    ib->surface = surf; ib->w = iw; ib->h = ih;

    struct wl_resource *buf = wl_resource_create(client, &wl_buffer_interface, 1, id);
    if (!buf) { if (surf) xios_release_client_iosurface(surf); free(ib);
                wl_client_post_no_memory(client); return; }
    wl_resource_set_implementation(buf, &iosurface_buffer_impl, ib,
                                   iosurface_buffer_resource_destroy);

    if (!surf) {
        wl_resource_post_error(res, IOSC_IOSURFACE_ERROR_IMPORT_FAILED,
                               "IOSurface import failed (pid=%d port=0x%x)",
                               (int)pid, mach_port_name);
        return;
    }
    fprintf(stderr, "iosc: imported client IOSurface as wl_buffer %dx%d (pid=%d)\n",
            iw, ih, (int)pid);
}
static void iosurface_factory_destroy(struct wl_client *c, struct wl_resource *r)
{ (void)c; wl_resource_destroy(r); }
static const struct iosc_iosurface_interface iosurface_factory_impl = {
    .destroy = iosurface_factory_destroy,
    .create_buffer = iosurface_factory_create_buffer,
};
static void iosc_iosurface_bind(struct wl_client *client, void *data,
                                uint32_t version, uint32_t id)
{
    (void)data;
    struct wl_resource *r = wl_resource_create(client, &iosc_iosurface_interface,
                                               version, id);
    if (!r) { wl_client_post_no_memory(client); return; }
    wl_resource_set_implementation(r, &iosurface_factory_impl, NULL, NULL);
    fprintf(stderr, "iosc: client bound iosc_iosurface v%u\n", version);
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
{ (void)c; (void)x; (void)y; (void)w; (void)h;
  struct iosc_surface *s = wl_resource_get_user_data(r);
  if (s) s->gl_dirty = 1;   /* in-place redraw (no re-attach): re-upload on next composite */ }

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
    int need_recomposite = 0;
    int send_presented = 0;

    if (s->pending_scale_dirty) {
        s->current_buffer_scale = s->pending_buffer_scale > 0 ? s->pending_buffer_scale : 1;
        s->pending_scale_dirty = 0;
        need_recomposite = s->mapped;
    }

    /* Layer-shell handshake: the client's first commit carries no buffer; reply
     * with a configure it acks before attaching a buffer to map. Once mapped, a
     * geometry change (anchor/size/zone) re-places it and re-serves only if the
     * anchored size actually changed (so this doesn't ping-pong on every frame). */
    if (s->role == IOSC_ROLE_LAYER && s->layer) {
        struct iosc_layer_state *L = s->layer;
        if (!L->configured && !s->buffer_attached) {
            layer_send_configure(s);
        } else if (L->configured && s->mapped) {
            int cw, ch, cx, cy;
            layer_compute(s, &cw, &ch, &cx, &cy);
            s->dx = cx;
            s->dy = cy;
            if (cw != L->cfg_w || ch != L->cfg_h) layer_send_configure(s);
            work_area_recompute();
            need_recomposite = 1;
        }
    }

    if (s->buffer_attached) {
        struct wl_resource *buf = s->pending_buffer;
        s->pending_buffer  = NULL;
        s->buffer_attached = 0;

        if (buf) {
            /* source dims from the buffer type */
            int sw = 0, sh = 0;
            struct wl_shm_buffer *shm = wl_shm_buffer_get(buf);
            if (shm) { sw = wl_shm_buffer_get_width(shm); sh = wl_shm_buffer_get_height(shm); }
            else if (wl_resource_instance_of(buf, &wl_buffer_interface, &iosurface_buffer_impl)) {
                struct iosc_iosurface_buffer *ib = wl_resource_get_user_data(buf);
                if (ib) { sw = ib->w; sh = ib->h; }
            }
            else if (wl_resource_instance_of(buf, &wl_buffer_interface, &spb_buffer_impl)) {
                sw = 1; sh = 1;   /* single-pixel buffer; scaled up via viewporter */
            }
            surface_set_buffer(s, buf, sw, sh, 1);
            if (!s->mapped &&
                (s->role == IOSC_ROLE_TOPLEVEL ||
                 s->role == IOSC_ROLE_POPUP ||
                 s->role == IOSC_ROLE_SUBSURFACE ||
                 (s->role == IOSC_ROLE_LAYER && s->layer && s->layer->configured)))
                surface_map(s);
        } else {
            /* NULL buffer attach + commit = unmap the surface */
            surface_set_buffer(s, NULL, 0, 0, 1);
            surface_unmap(s);
        }
        need_recomposite = 1;
        send_presented = 1;
    }

    if (need_recomposite) recomposite_all();
    if (send_presented) presentation_present_surface(s);

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
{ (void)c;
    struct iosc_surface *s = wl_resource_get_user_data(r);
    if (scale < 1) {
        wl_resource_post_error(r, WL_SURFACE_ERROR_INVALID_SCALE,
                               "invalid buffer scale %d", scale);
        return;
    }
    s->pending_buffer_scale = scale;
    s->pending_scale_dirty = 1;
}
static void surface_damage_buffer(struct wl_client *c, struct wl_resource *r,
                                  int32_t x, int32_t y, int32_t w, int32_t h)
{ (void)c; (void)x; (void)y; (void)w; (void)h;
  struct iosc_surface *s = wl_resource_get_user_data(r);
  if (s) s->gl_dirty = 1; }

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
    int was_mapped = s->mapped;
    surface_unmap(s);
    iosc_gl_forget_shm(s);   /* evict the per-surface shm texture (address may be reused) */
    /* Drop the retained buffer's destroy listener (client is going away; no
     * release needed). */
    if (s->buffer_listener_active) {
        wl_list_remove(&s->buffer_destroy.link);
        s->buffer_listener_active = 0;
    }
    if (s->viewport) {
        s->viewport->surface = NULL;
        s->viewport = NULL;
    }
    if (s->xdg_decoration) {
        wl_resource_set_user_data(s->xdg_decoration, NULL);
        s->xdg_decoration = NULL;
    }
    if (s->subsurface) {
        s->subsurface->surface = NULL;
        s->subsurface = NULL;
    }
    if (s->layer) {
        /* wl_surface is going away first; disarm the layer_surface resource so
         * its destructor doesn't touch freed memory, then free the layer state. */
        if (s->layer->resource)
            wl_resource_set_user_data(s->layer->resource, NULL);
        free(s->layer);
        s->layer = NULL;
        work_area_recompute();
    }
    if (s->xdg_popup) wl_resource_set_user_data(s->xdg_popup, NULL);
    if (g_cursor_surface == s) {
        g_cursor_surface = NULL;
        g_cursor_visible = 0;
    }
    s->current_buffer = NULL;
    presentation_discard_surface(s);
    struct iosc_frame *f, *tmp;
    wl_list_for_each_safe(f, tmp, &s->frame_callbacks, link) {
        wl_resource_destroy(f->resource);
        wl_list_remove(&f->link);
        free(f);
    }
    free(s);
    if (was_mapped) recomposite_all();   /* repaint without the closed window */
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
    wl_list_init(&s->presentation_feedbacks);
    s->pending_buffer_scale = 1;
    s->current_buffer_scale = 1;
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

/* ---- wp_viewporter + wp_fractional_scale --------------------------------- */

static void viewport_resource_destroy(struct wl_resource *r)
{
    struct iosc_viewport *vp = wl_resource_get_user_data(r);
    if (!vp) return;
    if (vp->surface && vp->surface->viewport == vp)
        vp->surface->viewport = NULL;
    free(vp);
}

static void viewport_destroy(struct wl_client *c, struct wl_resource *r)
{ (void)c; wl_resource_destroy(r); }
static void viewport_set_source(struct wl_client *c, struct wl_resource *r,
                                wl_fixed_t x, wl_fixed_t y,
                                wl_fixed_t w, wl_fixed_t h)
{
    (void)c;
    struct iosc_viewport *vp = wl_resource_get_user_data(r);
    if (!vp) return;
    wl_fixed_t unset = wl_fixed_from_int(-1);
    if (x == unset && y == unset && w == unset && h == unset) {
        vp->has_src = 0;
        return;
    }
    vp->has_src = 1;
    vp->src_x = wl_fixed_to_int(x);
    vp->src_y = wl_fixed_to_int(y);
    vp->src_w = wl_fixed_to_int(w);
    vp->src_h = wl_fixed_to_int(h);
}
static void viewport_set_destination(struct wl_client *c, struct wl_resource *r,
                                     int32_t w, int32_t h)
{
    (void)c;
    struct iosc_viewport *vp = wl_resource_get_user_data(r);
    if (!vp) return;
    if (w == -1 && h == -1) {
        vp->has_dst = 0;
        return;
    }
    vp->has_dst = 1;
    vp->dst_w = w;
    vp->dst_h = h;
}
static const struct wp_viewport_interface viewport_impl = {
    .destroy = viewport_destroy,
    .set_source = viewport_set_source,
    .set_destination = viewport_set_destination,
};

static void viewporter_destroy(struct wl_client *c, struct wl_resource *r)
{ (void)c; wl_resource_destroy(r); }
static void viewporter_get_viewport(struct wl_client *c, struct wl_resource *r,
                                    uint32_t id, struct wl_resource *surface)
{
    struct iosc_surface *s = wl_resource_get_user_data(surface);
    if (s->viewport) {
        wl_resource_post_error(r, WP_VIEWPORTER_ERROR_VIEWPORT_EXISTS,
                               "surface already has a viewport");
        return;
    }
    struct iosc_viewport *vp = calloc(1, sizeof(*vp));
    if (!vp) { wl_client_post_no_memory(c); return; }
    struct wl_resource *vr = wl_resource_create(c, &wp_viewport_interface,
                                                wl_resource_get_version(r), id);
    if (!vr) { free(vp); wl_client_post_no_memory(c); return; }
    vp->resource = vr;
    vp->surface = s;
    s->viewport = vp;
    wl_resource_set_implementation(vr, &viewport_impl, vp, viewport_resource_destroy);
}
static const struct wp_viewporter_interface viewporter_impl = {
    .destroy = viewporter_destroy,
    .get_viewport = viewporter_get_viewport,
};
static void viewporter_bind(struct wl_client *client, void *data, uint32_t version, uint32_t id)
{
    (void)data;
    struct wl_resource *r = wl_resource_create(client, &wp_viewporter_interface, version, id);
    if (!r) { wl_client_post_no_memory(client); return; }
    wl_resource_set_implementation(r, &viewporter_impl, NULL, NULL);
}

static void fractional_scale_destroy(struct wl_client *c, struct wl_resource *r)
{ (void)c; wl_resource_destroy(r); }
static const struct wp_fractional_scale_v1_interface fractional_scale_impl = {
    .destroy = fractional_scale_destroy,
};
static void fractional_manager_destroy(struct wl_client *c, struct wl_resource *r)
{ (void)c; wl_resource_destroy(r); }
static void fractional_manager_get(struct wl_client *c, struct wl_resource *r,
                                   uint32_t id, struct wl_resource *surface)
{
    (void)surface;
    struct wl_resource *sr = wl_resource_create(c, &wp_fractional_scale_v1_interface,
                                                wl_resource_get_version(r), id);
    if (!sr) { wl_client_post_no_memory(c); return; }
    wl_resource_set_implementation(sr, &fractional_scale_impl, NULL, NULL);
    wp_fractional_scale_v1_send_preferred_scale(sr, (uint32_t)(output_scale() * 120));
}
static const struct wp_fractional_scale_manager_v1_interface fractional_manager_impl = {
    .destroy = fractional_manager_destroy,
    .get_fractional_scale = fractional_manager_get,
};
static void fractional_scale_bind(struct wl_client *client, void *data, uint32_t version, uint32_t id)
{
    (void)data;
    struct wl_resource *r = wl_resource_create(client, &wp_fractional_scale_manager_v1_interface,
                                               version, id);
    if (!r) { wl_client_post_no_memory(client); return; }
    wl_resource_set_implementation(r, &fractional_manager_impl, NULL, NULL);
}

/* ---- wp_presentation ----------------------------------------------------- */

static void presentation_destroy(struct wl_client *c, struct wl_resource *r)
{ (void)c; wl_resource_destroy(r); }
static void presentation_feedback(struct wl_client *c, struct wl_resource *r,
                                  struct wl_resource *surface, uint32_t callback)
{
    struct iosc_surface *s = wl_resource_get_user_data(surface);
    struct iosc_presentation_feedback *fb = calloc(1, sizeof(*fb));
    if (!fb) { wl_client_post_no_memory(c); return; }
    fb->resource = wl_resource_create(c, &wp_presentation_feedback_interface,
                                      wl_resource_get_version(r), callback);
    if (!fb->resource) { free(fb); wl_client_post_no_memory(c); return; }
    fb->surface = s;
    wl_resource_set_implementation(fb->resource, NULL, fb, presentation_feedback_destroy);
    wl_list_insert(&s->presentation_feedbacks, &fb->link);
}
static const struct wp_presentation_interface presentation_impl = {
    .destroy = presentation_destroy,
    .feedback = presentation_feedback,
};
static void presentation_bind(struct wl_client *client, void *data, uint32_t version, uint32_t id)
{
    (void)data;
    struct wl_resource *r = wl_resource_create(client, &wp_presentation_interface,
                                               version, id);
    if (!r) { wl_client_post_no_memory(client); return; }
    wl_resource_set_implementation(r, &presentation_impl, NULL, NULL);
    wp_presentation_send_clock_id(r, (uint32_t)CLOCK_MONOTONIC);
}

/* ---- xdg-decoration ------------------------------------------------------ */

static void decoration_configure_client_side(struct iosc_surface *s)
{
    if (!s || !s->xdg_decoration || !s->xdg_surface) return;
    zxdg_toplevel_decoration_v1_send_configure(
        s->xdg_decoration, ZXDG_TOPLEVEL_DECORATION_V1_MODE_CLIENT_SIDE);
    xdg_surface_send_configure(s->xdg_surface, wl_display_next_serial(g_display));
}

static void decoration_resource_destroy(struct wl_resource *r)
{
    struct iosc_surface *s = wl_resource_get_user_data(r);
    if (s && s->xdg_decoration == r)
        s->xdg_decoration = NULL;
}

static void decoration_destroy(struct wl_client *c, struct wl_resource *r)
{ (void)c; wl_resource_destroy(r); }
static void decoration_set_mode(struct wl_client *c, struct wl_resource *r, uint32_t mode)
{
    (void)c; (void)mode;
    decoration_configure_client_side(wl_resource_get_user_data(r));
}
static void decoration_unset_mode(struct wl_client *c, struct wl_resource *r)
{
    (void)c;
    decoration_configure_client_side(wl_resource_get_user_data(r));
}
static const struct zxdg_toplevel_decoration_v1_interface decoration_impl = {
    .destroy = decoration_destroy,
    .set_mode = decoration_set_mode,
    .unset_mode = decoration_unset_mode,
};

static void decoration_manager_destroy(struct wl_client *c, struct wl_resource *r)
{ (void)c; wl_resource_destroy(r); }
static void decoration_manager_get(struct wl_client *c, struct wl_resource *r,
                                   uint32_t id, struct wl_resource *toplevel)
{
    struct iosc_surface *s = wl_resource_get_user_data(toplevel);
    if (s->xdg_decoration) {
        wl_resource_post_error(r, ZXDG_TOPLEVEL_DECORATION_V1_ERROR_ALREADY_CONSTRUCTED,
                               "toplevel already has a decoration object");
        return;
    }
    struct wl_resource *dr = wl_resource_create(c, &zxdg_toplevel_decoration_v1_interface,
                                                wl_resource_get_version(r), id);
    if (!dr) { wl_client_post_no_memory(c); return; }
    s->xdg_decoration = dr;
    wl_resource_set_implementation(dr, &decoration_impl, s, decoration_resource_destroy);
    decoration_configure_client_side(s);
}
static const struct zxdg_decoration_manager_v1_interface decoration_manager_impl = {
    .destroy = decoration_manager_destroy,
    .get_toplevel_decoration = decoration_manager_get,
};
static void decoration_manager_bind(struct wl_client *client, void *data,
                                    uint32_t version, uint32_t id)
{
    (void)data;
    struct wl_resource *r = wl_resource_create(client, &zxdg_decoration_manager_v1_interface,
                                               version, id);
    if (!r) { wl_client_post_no_memory(client); return; }
    wl_resource_set_implementation(r, &decoration_manager_impl, NULL, NULL);
}

/* ---- xdg-activation ------------------------------------------------------ */

struct iosc_activation_token {
    int used;
};

static uint32_t g_activation_token_id;

static void activation_token_destroy_resource(struct wl_resource *r)
{
    free(wl_resource_get_user_data(r));
}

static void activation_token_set_serial(struct wl_client *c, struct wl_resource *r,
                                        uint32_t serial, struct wl_resource *seat)
{ (void)c; (void)r; (void)serial; (void)seat; }
static void activation_token_set_app_id(struct wl_client *c, struct wl_resource *r,
                                        const char *app_id)
{ (void)c; (void)r; (void)app_id; }
static void activation_token_set_surface(struct wl_client *c, struct wl_resource *r,
                                         struct wl_resource *surface)
{ (void)c; (void)r; (void)surface; }
static void activation_token_commit(struct wl_client *c, struct wl_resource *r)
{
    (void)c;
    struct iosc_activation_token *tok = wl_resource_get_user_data(r);
    if (tok->used) {
        wl_resource_post_error(r, XDG_ACTIVATION_TOKEN_V1_ERROR_ALREADY_USED,
                               "activation token already committed");
        return;
    }
    tok->used = 1;
    char token[32];
    snprintf(token, sizeof(token), "iosc-%u", ++g_activation_token_id);
    xdg_activation_token_v1_send_done(r, token);
}
static void activation_token_destroy(struct wl_client *c, struct wl_resource *r)
{ (void)c; wl_resource_destroy(r); }
static const struct xdg_activation_token_v1_interface activation_token_impl = {
    .set_serial = activation_token_set_serial,
    .set_app_id = activation_token_set_app_id,
    .set_surface = activation_token_set_surface,
    .commit = activation_token_commit,
    .destroy = activation_token_destroy,
};

static void activation_destroy(struct wl_client *c, struct wl_resource *r)
{ (void)c; wl_resource_destroy(r); }
static void activation_get_token(struct wl_client *c, struct wl_resource *r, uint32_t id)
{
    struct iosc_activation_token *tok = calloc(1, sizeof(*tok));
    if (!tok) { wl_client_post_no_memory(c); return; }
    struct wl_resource *tr = wl_resource_create(c, &xdg_activation_token_v1_interface,
                                                wl_resource_get_version(r), id);
    if (!tr) { free(tok); wl_client_post_no_memory(c); return; }
    wl_resource_set_implementation(tr, &activation_token_impl, tok,
                                   activation_token_destroy_resource);
}
static void activation_activate(struct wl_client *c, struct wl_resource *r,
                                const char *token, struct wl_resource *surface)
{
    (void)c; (void)r; (void)token;
    struct iosc_surface *s = wl_resource_get_user_data(surface);
    if (!s || !s->mapped) return;
    surface_raise(s);
    keyboard_set_focus(s);
    recomposite_all();
}
static const struct xdg_activation_v1_interface activation_impl = {
    .destroy = activation_destroy,
    .get_activation_token = activation_get_token,
    .activate = activation_activate,
};
static void activation_bind(struct wl_client *client, void *data, uint32_t version, uint32_t id)
{
    (void)data;
    struct wl_resource *r = wl_resource_create(client, &xdg_activation_v1_interface,
                                               version, id);
    if (!r) { wl_client_post_no_memory(client); return; }
    wl_resource_set_implementation(r, &activation_impl, NULL, NULL);
}

/* ---- xdg_shell ----------------------------------------------------------- */

static int has_x(uint32_t edge)
{
    return edge == XDG_POSITIONER_ANCHOR_LEFT ||
           edge == XDG_POSITIONER_ANCHOR_RIGHT ||
           edge == XDG_POSITIONER_ANCHOR_TOP_LEFT ||
           edge == XDG_POSITIONER_ANCHOR_BOTTOM_LEFT ||
           edge == XDG_POSITIONER_ANCHOR_TOP_RIGHT ||
           edge == XDG_POSITIONER_ANCHOR_BOTTOM_RIGHT;
}

static int has_y(uint32_t edge)
{
    return edge == XDG_POSITIONER_ANCHOR_TOP ||
           edge == XDG_POSITIONER_ANCHOR_BOTTOM ||
           edge == XDG_POSITIONER_ANCHOR_TOP_LEFT ||
           edge == XDG_POSITIONER_ANCHOR_TOP_RIGHT ||
           edge == XDG_POSITIONER_ANCHOR_BOTTOM_LEFT ||
           edge == XDG_POSITIONER_ANCHOR_BOTTOM_RIGHT;
}

static int is_left(uint32_t edge)
{
    return edge == XDG_POSITIONER_ANCHOR_LEFT ||
           edge == XDG_POSITIONER_ANCHOR_TOP_LEFT ||
           edge == XDG_POSITIONER_ANCHOR_BOTTOM_LEFT;
}

static int is_right(uint32_t edge)
{
    return edge == XDG_POSITIONER_ANCHOR_RIGHT ||
           edge == XDG_POSITIONER_ANCHOR_TOP_RIGHT ||
           edge == XDG_POSITIONER_ANCHOR_BOTTOM_RIGHT;
}

static int is_top(uint32_t edge)
{
    return edge == XDG_POSITIONER_ANCHOR_TOP ||
           edge == XDG_POSITIONER_ANCHOR_TOP_LEFT ||
           edge == XDG_POSITIONER_ANCHOR_TOP_RIGHT;
}

static int is_bottom(uint32_t edge)
{
    return edge == XDG_POSITIONER_ANCHOR_BOTTOM ||
           edge == XDG_POSITIONER_ANCHOR_BOTTOM_LEFT ||
           edge == XDG_POSITIONER_ANCHOR_BOTTOM_RIGHT;
}

static uint32_t flip_x_edges(uint32_t edges, uint32_t left, uint32_t right)
{
    uint32_t out = edges & ~(left | right);
    if (edges & left) out |= right;
    if (edges & right) out |= left;
    return out;
}

static uint32_t flip_y_edges(uint32_t edges, uint32_t top, uint32_t bottom)
{
    uint32_t out = edges & ~(top | bottom);
    if (edges & top) out |= bottom;
    if (edges & bottom) out |= top;
    return out;
}

static void popup_calc_position(const struct iosc_positioner *p,
                                uint32_t anchor, uint32_t gravity,
                                int *out_x, int *out_y)
{
    int ax = p->anchor_x + (is_right(anchor) ? p->anchor_w :
                            is_left(anchor) ? 0 : p->anchor_w / 2);
    int ay = p->anchor_y + (is_bottom(anchor) ? p->anchor_h :
                            is_top(anchor) ? 0 : p->anchor_h / 2);
    int x = ax + p->off_x;
    int y = ay + p->off_y;
    if (is_left(gravity)) x -= p->size_w;
    else if (!is_right(gravity) && !has_x(gravity)) x -= p->size_w / 2;
    if (is_top(gravity)) y -= p->size_h;
    else if (!is_bottom(gravity) && !has_y(gravity)) y -= p->size_h / 2;
    *out_x = x;
    *out_y = y;
}

static int popup_fits(int x, int y, int w, int h)
{
    return x >= 0 && y >= 0 &&
           x + w <= output_logical_width() &&
           y + h <= output_logical_height();
}

static void popup_place(struct iosc_surface *s, const struct iosc_positioner *p)
{
    int x = 0, y = 0;
    popup_calc_position(p, p->anchor, p->gravity, &x, &y);
    int abs_x = s->parent->dx + x;
    int abs_y = s->parent->dy + y;
    if (!popup_fits(abs_x, abs_y, p->size_w, p->size_h) &&
        (p->constraint & XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_FLIP_X)) {
        uint32_t anchor = flip_x_edges(p->anchor, XDG_POSITIONER_ANCHOR_LEFT,
                                       XDG_POSITIONER_ANCHOR_RIGHT);
        uint32_t gravity = flip_x_edges(p->gravity, XDG_POSITIONER_GRAVITY_LEFT,
                                        XDG_POSITIONER_GRAVITY_RIGHT);
        int fx = 0, fy = 0;
        popup_calc_position(p, anchor, gravity, &fx, &fy);
        if (popup_fits(s->parent->dx + fx, s->parent->dy + fy, p->size_w, p->size_h)) {
            x = fx;
            y = fy;
            abs_x = s->parent->dx + x;
            abs_y = s->parent->dy + y;
        }
    }
    if (!popup_fits(abs_x, abs_y, p->size_w, p->size_h) &&
        (p->constraint & XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_FLIP_Y)) {
        uint32_t anchor = flip_y_edges(p->anchor, XDG_POSITIONER_ANCHOR_TOP,
                                       XDG_POSITIONER_ANCHOR_BOTTOM);
        uint32_t gravity = flip_y_edges(p->gravity, XDG_POSITIONER_GRAVITY_TOP,
                                        XDG_POSITIONER_GRAVITY_BOTTOM);
        int fx = 0, fy = 0;
        popup_calc_position(p, anchor, gravity, &fx, &fy);
        if (popup_fits(s->parent->dx + fx, s->parent->dy + fy, p->size_w, p->size_h)) {
            x = fx;
            y = fy;
            abs_x = s->parent->dx + x;
            abs_y = s->parent->dy + y;
        }
    }

    int max_x = output_logical_width() - p->size_w;
    int max_y = output_logical_height() - p->size_h;
    if (max_x < 0) max_x = 0;
    if (max_y < 0) max_y = 0;
    if (p->constraint & XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_SLIDE_X)
        abs_x = clampi(abs_x, 0, max_x);
    if (p->constraint & XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_SLIDE_Y)
        abs_y = clampi(abs_y, 0, max_y);
    s->rel_x = abs_x - s->parent->dx;
    s->rel_y = abs_y - s->parent->dy;
    surface_place_child(s);
}

static void popup_send_configure(struct iosc_surface *s, int token)
{
    int w = 0, h = 0;
    surface_display_size(s, &w, &h);
    if (w <= 0) w = 1;
    if (h <= 0) h = 1;
    if (token) xdg_popup_send_repositioned(s->xdg_popup, (uint32_t)token);
    xdg_popup_send_configure(s->xdg_popup, s->rel_x, s->rel_y, w, h);
    xdg_surface_send_configure(s->xdg_surface, wl_display_next_serial(g_display));
}

static void positioner_destroy_resource(struct wl_resource *r)
{
    free(wl_resource_get_user_data(r));
}

static void xp_destroy(struct wl_client *c, struct wl_resource *r)
{ (void)c; wl_resource_destroy(r); }
static void xp_set_size(struct wl_client *c, struct wl_resource *r, int32_t w, int32_t h)
{ (void)c; struct iosc_positioner *p = wl_resource_get_user_data(r); p->size_w = w; p->size_h = h; }
static void xp_set_anchor_rect(struct wl_client *c, struct wl_resource *r,
                               int32_t x, int32_t y, int32_t w, int32_t h)
{ (void)c; struct iosc_positioner *p = wl_resource_get_user_data(r);
  p->anchor_x = x; p->anchor_y = y; p->anchor_w = w; p->anchor_h = h; }
static void xp_set_anchor(struct wl_client *c, struct wl_resource *r, uint32_t anchor)
{ (void)c; struct iosc_positioner *p = wl_resource_get_user_data(r); p->anchor = anchor; }
static void xp_set_gravity(struct wl_client *c, struct wl_resource *r, uint32_t gravity)
{ (void)c; struct iosc_positioner *p = wl_resource_get_user_data(r); p->gravity = gravity; }
static void xp_set_constraint_adjustment(struct wl_client *c, struct wl_resource *r, uint32_t a)
{ (void)c; struct iosc_positioner *p = wl_resource_get_user_data(r); p->constraint = a; }
static void xp_set_offset(struct wl_client *c, struct wl_resource *r, int32_t x, int32_t y)
{ (void)c; struct iosc_positioner *p = wl_resource_get_user_data(r); p->off_x = x; p->off_y = y; }
static void xp_set_reactive(struct wl_client *c, struct wl_resource *r)
{ (void)c; (void)r; }
static void xp_set_parent_size(struct wl_client *c, struct wl_resource *r, int32_t w, int32_t h)
{ (void)c; (void)r; (void)w; (void)h; }
static void xp_set_parent_configure(struct wl_client *c, struct wl_resource *r, uint32_t serial)
{ (void)c; (void)r; (void)serial; }
static const struct xdg_positioner_interface positioner_impl = {
    .destroy = xp_destroy, .set_size = xp_set_size, .set_anchor_rect = xp_set_anchor_rect,
    .set_anchor = xp_set_anchor, .set_gravity = xp_set_gravity,
    .set_constraint_adjustment = xp_set_constraint_adjustment, .set_offset = xp_set_offset,
    .set_reactive = xp_set_reactive, .set_parent_size = xp_set_parent_size,
    .set_parent_configure = xp_set_parent_configure,
};

static void popup_resource_destroy(struct wl_resource *r)
{
    struct iosc_surface *s = wl_resource_get_user_data(r);
    if (!s) return;
    surface_unmap(s);
    s->xdg_popup = NULL;
    s->role = IOSC_ROLE_NONE;
    recomposite_all();
}

static void popup_destroy(struct wl_client *c, struct wl_resource *r)
{ (void)c; wl_resource_destroy(r); }
static void popup_grab(struct wl_client *c, struct wl_resource *r,
                       struct wl_resource *seat, uint32_t serial)
{ (void)c; (void)r; (void)seat; (void)serial; }
static void popup_reposition(struct wl_client *c, struct wl_resource *r,
                             struct wl_resource *positioner, uint32_t token)
{
    (void)c;
    struct iosc_surface *s = wl_resource_get_user_data(r);
    struct iosc_positioner *p = wl_resource_get_user_data(positioner);
    popup_place(s, p);
    popup_send_configure(s, (int)token);
    if (s->mapped) recomposite_all();
}
static const struct xdg_popup_interface popup_impl = {
    .destroy = popup_destroy, .grab = popup_grab, .reposition = popup_reposition,
};

static void toplevel_send_configure(struct iosc_surface *s, int w, int h)
{
    if (!s || !s->xdg_toplevel || !s->xdg_surface) return;
    struct wl_array states;
    wl_array_init(&states);
    uint32_t *st = wl_array_add(&states, sizeof(uint32_t));
    if (st) *st = XDG_TOPLEVEL_STATE_ACTIVATED;
    if (s->toplevel_maximized) {
        st = wl_array_add(&states, sizeof(uint32_t));
        if (st) *st = XDG_TOPLEVEL_STATE_MAXIMIZED;
    }
    if (s->toplevel_fullscreen) {
        st = wl_array_add(&states, sizeof(uint32_t));
        if (st) *st = XDG_TOPLEVEL_STATE_FULLSCREEN;
    }
    if (s->toplevel_resizing) {
        st = wl_array_add(&states, sizeof(uint32_t));
        if (st) *st = XDG_TOPLEVEL_STATE_RESIZING;
    }
    if (wl_resource_get_version(s->xdg_toplevel) >= XDG_TOPLEVEL_CONFIGURE_BOUNDS_SINCE_VERSION)
        xdg_toplevel_send_configure_bounds(s->xdg_toplevel,
                                           output_logical_width(), output_logical_height());
    xdg_toplevel_send_configure(s->xdg_toplevel, w, h, &states);
    wl_array_release(&states);

    uint32_t serial = wl_display_next_serial(g_display);
    xdg_surface_send_configure(s->xdg_surface, serial);
    s->configured = 1;
}

/* Send the initial configure that lets a client map. */
static void send_initial_configure(struct iosc_surface *s)
{
    toplevel_send_configure(s, default_window_w(), default_window_h());
}

static void toplevel_reconfigure_state(struct iosc_surface *s)
{
    if (s->toplevel_fullscreen) {
        /* Fullscreen covers the whole output, ignoring reserved panel edges. */
        s->dx = 0;
        s->dy = 0;
        toplevel_send_configure(s, output_logical_width(), output_logical_height());
    } else if (s->toplevel_maximized) {
        /* Maximize fills the work area so it doesn't draw under the panel. */
        int wx, wy, ww, wh;
        work_area(&wx, &wy, &ww, &wh);
        s->dx = wx;
        s->dy = wy;
        toplevel_send_configure(s, ww, wh);
    } else {
        toplevel_send_configure(s, default_window_w(), default_window_h());
    }
    if (s->mapped) recomposite_all();
}

static int resize_has_left(uint32_t edges)
{
    return edges == XDG_TOPLEVEL_RESIZE_EDGE_LEFT ||
           edges == XDG_TOPLEVEL_RESIZE_EDGE_TOP_LEFT ||
           edges == XDG_TOPLEVEL_RESIZE_EDGE_BOTTOM_LEFT;
}

static int resize_has_right(uint32_t edges)
{
    return edges == XDG_TOPLEVEL_RESIZE_EDGE_RIGHT ||
           edges == XDG_TOPLEVEL_RESIZE_EDGE_TOP_RIGHT ||
           edges == XDG_TOPLEVEL_RESIZE_EDGE_BOTTOM_RIGHT;
}

static int resize_has_top(uint32_t edges)
{
    return edges == XDG_TOPLEVEL_RESIZE_EDGE_TOP ||
           edges == XDG_TOPLEVEL_RESIZE_EDGE_TOP_LEFT ||
           edges == XDG_TOPLEVEL_RESIZE_EDGE_TOP_RIGHT;
}

static int resize_has_bottom(uint32_t edges)
{
    return edges == XDG_TOPLEVEL_RESIZE_EDGE_BOTTOM ||
           edges == XDG_TOPLEVEL_RESIZE_EDGE_BOTTOM_LEFT ||
           edges == XDG_TOPLEVEL_RESIZE_EDGE_BOTTOM_RIGHT;
}

static void interactive_begin(struct iosc_surface *s, enum iosc_interactive_op op, uint32_t edges)
{
    if (!s || !s->xdg_toplevel) return;
    int w = 0, h = 0;
    surface_display_size(s, &w, &h);
    g_interactive_op = op;
    g_interactive_surface = s;
    g_interactive_edges = edges;
    g_interactive_px = g_cursor_x;
    g_interactive_py = g_cursor_y;
    g_interactive_dx = s->dx;
    g_interactive_dy = s->dy;
    g_interactive_w = w;
    g_interactive_h = h;
    if (op == IOSC_INTERACTIVE_RESIZE) {
        s->toplevel_resizing = 1;
        toplevel_send_configure(s, w > 1 ? w : 1, h > 1 ? h : 1);
    }
}

static void interactive_update(int x, int y)
{
    struct iosc_surface *s = g_interactive_surface;
    if (!s || g_interactive_op == IOSC_INTERACTIVE_NONE) return;
    int dx = x - g_interactive_px;
    int dy = y - g_interactive_py;
    int wx, wy, ww, wh;
    work_area(&wx, &wy, &ww, &wh);   /* keep windows out from under the panel */
    if (g_interactive_op == IOSC_INTERACTIVE_MOVE) {
        int w = 0, h = 0;
        surface_display_size(s, &w, &h);
        int max_x = wx + ww - (w > 0 ? w : 1);
        int max_y = wy + wh - (h > 0 ? h : 1);
        if (max_x < wx) max_x = wx;
        if (max_y < wy) max_y = wy;
        s->dx = clampi(g_interactive_dx + dx, wx, max_x);
        s->dy = clampi(g_interactive_dy + dy, wy, max_y);
        recomposite_all();
        return;
    }
    int nx = g_interactive_dx, ny = g_interactive_dy;
    int nw = g_interactive_w, nh = g_interactive_h;
    if (resize_has_left(g_interactive_edges)) { nx = g_interactive_dx + dx; nw = g_interactive_w - dx; }
    if (resize_has_right(g_interactive_edges)) nw = g_interactive_w + dx;
    if (resize_has_top(g_interactive_edges)) { ny = g_interactive_dy + dy; nh = g_interactive_h - dy; }
    if (resize_has_bottom(g_interactive_edges)) nh = g_interactive_h + dy;
    nw = clampi(nw, 80, ww);
    nh = clampi(nh, 60, wh);
    nx = clampi(nx, wx, wx + ww - nw);
    ny = clampi(ny, wy, wy + wh - nh);
    s->dx = nx;
    s->dy = ny;
    toplevel_send_configure(s, nw, nh);
    recomposite_all();
}

static void interactive_end(void)
{
    if (g_interactive_surface && g_interactive_op == IOSC_INTERACTIVE_RESIZE) {
        struct iosc_surface *s = g_interactive_surface;
        int w = 0, h = 0;
        surface_display_size(s, &w, &h);
        s->toplevel_resizing = 0;
        toplevel_send_configure(s, w > 1 ? w : 1, h > 1 ? h : 1);
    }
    g_interactive_surface = NULL;
    g_interactive_op = IOSC_INTERACTIVE_NONE;
    g_interactive_edges = 0;
}

/* xdg_toplevel */
static void xt_destroy(struct wl_client *c, struct wl_resource *r){ (void)c; wl_resource_destroy(r); }
static void xt_set_parent(struct wl_client *c, struct wl_resource *r, struct wl_resource *p){ (void)c;(void)r;(void)p; }
static void xt_set_title(struct wl_client *c, struct wl_resource *r, const char *t)
{ (void)c; struct iosc_surface *s = wl_resource_get_user_data(r);
  if (s) { snprintf(s->title, sizeof(s->title), "%s", t ? t : ""); ftl_broadcast_title(s); }
  if (iosc_debug()) fprintf(stderr, "iosc: toplevel title=\"%s\"\n", t ? t : ""); }
static void xt_set_app_id(struct wl_client *c, struct wl_resource *r, const char *a)
{ (void)c; struct iosc_surface *s = wl_resource_get_user_data(r);
  if (s) { snprintf(s->app_id, sizeof(s->app_id), "%s", a ? a : ""); ftl_broadcast_app_id(s); }
  if (iosc_debug()) fprintf(stderr, "iosc: toplevel app_id=\"%s\"\n", a ? a : ""); }
static void xt_show_window_menu(struct wl_client *c, struct wl_resource *r, struct wl_resource *seat, uint32_t serial, int32_t x, int32_t y){ (void)c;(void)r;(void)seat;(void)serial;(void)x;(void)y; }
static void xt_move(struct wl_client *c, struct wl_resource *r, struct wl_resource *seat, uint32_t serial)
{ (void)c; (void)seat; (void)serial; interactive_begin(wl_resource_get_user_data(r), IOSC_INTERACTIVE_MOVE, 0); }
static void xt_resize(struct wl_client *c, struct wl_resource *r, struct wl_resource *seat, uint32_t serial, uint32_t edges)
{ (void)c; (void)seat; (void)serial; interactive_begin(wl_resource_get_user_data(r), IOSC_INTERACTIVE_RESIZE, edges); }
static void xt_set_max_size(struct wl_client *c, struct wl_resource *r, int32_t w, int32_t h){ (void)c;(void)r;(void)w;(void)h; }
static void xt_set_min_size(struct wl_client *c, struct wl_resource *r, int32_t w, int32_t h){ (void)c;(void)r;(void)w;(void)h; }
static void xt_set_maximized(struct wl_client *c, struct wl_resource *r)
{ (void)c; struct iosc_surface *s = wl_resource_get_user_data(r);
  if (s) { s->toplevel_maximized = 1; toplevel_reconfigure_state(s); ftl_broadcast_state(s); } }
static void xt_unset_maximized(struct wl_client *c, struct wl_resource *r)
{ (void)c; struct iosc_surface *s = wl_resource_get_user_data(r);
  if (s) { s->toplevel_maximized = 0; toplevel_reconfigure_state(s); ftl_broadcast_state(s); } }
static void xt_set_fullscreen(struct wl_client *c, struct wl_resource *r, struct wl_resource *out)
{ (void)c; (void)out; struct iosc_surface *s = wl_resource_get_user_data(r);
  if (s) { s->toplevel_fullscreen = 1; toplevel_reconfigure_state(s); ftl_broadcast_state(s); } }
static void xt_unset_fullscreen(struct wl_client *c, struct wl_resource *r)
{ (void)c; struct iosc_surface *s = wl_resource_get_user_data(r);
  if (s) { s->toplevel_fullscreen = 0; toplevel_reconfigure_state(s); ftl_broadcast_state(s); } }
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
    s->role = IOSC_ROLE_TOPLEVEL;
    s->xdg_toplevel = tl;
    fprintf(stderr, "iosc: xdg_toplevel created -> sending initial configure %dx%d\n",
            default_window_w(), default_window_h());
    send_initial_configure(s);
}
static void xs_get_popup(struct wl_client *c, struct wl_resource *r, uint32_t id,
                         struct wl_resource *parent, struct wl_resource *positioner)
{
    struct iosc_surface *s = wl_resource_get_user_data(r);
    struct iosc_surface *ps = wl_resource_get_user_data(parent);
    struct iosc_positioner *pos = wl_resource_get_user_data(positioner);
    struct wl_resource *p = wl_resource_create(c, &xdg_popup_interface,
                                               wl_resource_get_version(r), id);
    if (!p) { wl_client_post_no_memory(c); return; }
    wl_resource_set_implementation(p, &popup_impl, s, popup_resource_destroy);
    s->role = IOSC_ROLE_POPUP;
    s->parent = ps;
    s->xdg_popup = p;
    popup_place(s, pos);
    popup_send_configure(s, 0);
    fprintf(stderr, "iosc: xdg_popup configured at parent-relative (%d,%d)\n",
            s->rel_x, s->rel_y);
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
    struct iosc_positioner *pos = calloc(1, sizeof(*pos));
    if (!pos) { wl_client_post_no_memory(c); return; }
    pos->anchor_w = 1;
    pos->anchor_h = 1;
    pos->size_w = 1;
    pos->size_h = 1;
    struct wl_resource *p = wl_resource_create(c, &xdg_positioner_interface,
                                               wl_resource_get_version(r), id);
    if (!p) { free(pos); wl_client_post_no_memory(c); return; }
    wl_resource_set_implementation(p, &positioner_impl, pos, positioner_destroy_resource);
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

/* ---- GTK4 enablement globals: wl_output, wl_seat, wl_subcompositor, ------- *
 * ---- wl_data_device_manager. GDK-wayland wants these before it will behave  *
 * like a normal desktop client.                                              */

/* wl_output + xdg-output: one native IOSurface output, exposed as a scaled
 * logical desktop region to Wayland clients. */
static void output_release(struct wl_client *c, struct wl_resource *r)
{ (void)c; wl_resource_destroy(r); }
static const struct wl_output_interface output_impl = {
    .release = output_release,
};

static void output_send_done(struct wl_resource *r)
{
    if (wl_resource_get_version(r) >= WL_OUTPUT_DONE_SINCE_VERSION)
        wl_output_send_done(r);
}

static void output_send_state(struct wl_resource *r)
{
    uint32_t version = wl_resource_get_version(r);
    wl_output_send_geometry(r, 0, 0, output_px_to_mm(g_width), output_px_to_mm(g_height),
                            WL_OUTPUT_SUBPIXEL_UNKNOWN,
                            "iosc", "IOSurface", WL_OUTPUT_TRANSFORM_NORMAL);
    wl_output_send_mode(r, WL_OUTPUT_MODE_CURRENT | WL_OUTPUT_MODE_PREFERRED,
                        g_width, g_height, 60000);
    if (version >= WL_OUTPUT_SCALE_SINCE_VERSION)
        wl_output_send_scale(r, output_scale());
    if (version >= WL_OUTPUT_NAME_SINCE_VERSION)
        wl_output_send_name(r, "IOSC-1");
    if (version >= WL_OUTPUT_DESCRIPTION_SINCE_VERSION)
        wl_output_send_description(r, "iosc native IOSurface output");
    output_send_done(r);
}

static void output_bind(struct wl_client *client, void *data, uint32_t version, uint32_t id)
{
    (void)data;
    struct wl_resource *r = wl_resource_create(client, &wl_output_interface, version, id);
    if (!r) { wl_client_post_no_memory(client); return; }
    wl_resource_set_implementation(r, &output_impl, NULL, NULL);
    output_send_state(r);
}

static void xdg_output_destroy(struct wl_client *c, struct wl_resource *r)
{ (void)c; wl_resource_destroy(r); }
static const struct zxdg_output_v1_interface xdg_output_impl = {
    .destroy = xdg_output_destroy,
};

static void xdg_output_manager_destroy(struct wl_client *c, struct wl_resource *r)
{ (void)c; wl_resource_destroy(r); }

static void xdg_output_manager_get(struct wl_client *c, struct wl_resource *r,
                                   uint32_t id, struct wl_resource *output)
{
    struct wl_resource *xo = wl_resource_create(c, &zxdg_output_v1_interface,
                                                wl_resource_get_version(r), id);
    if (!xo) { wl_client_post_no_memory(c); return; }
    wl_resource_set_implementation(xo, &xdg_output_impl, NULL, NULL);
    zxdg_output_v1_send_logical_position(xo, 0, 0);
    zxdg_output_v1_send_logical_size(xo, output_logical_width(), output_logical_height());
    if (wl_resource_get_version(xo) >= ZXDG_OUTPUT_V1_NAME_SINCE_VERSION)
        zxdg_output_v1_send_name(xo, "IOSC-1");
    if (wl_resource_get_version(xo) >= ZXDG_OUTPUT_V1_DESCRIPTION_SINCE_VERSION)
        zxdg_output_v1_send_description(xo, "iosc native IOSurface output");
    if (wl_resource_get_version(xo) < 3)
        zxdg_output_v1_send_done(xo);
    output_send_done(output);
}

static const struct zxdg_output_manager_v1_interface xdg_output_manager_impl = {
    .destroy = xdg_output_manager_destroy,
    .get_xdg_output = xdg_output_manager_get,
};

static void xdg_output_manager_bind(struct wl_client *client, void *data,
                                    uint32_t version, uint32_t id)
{
    (void)data;
    struct wl_resource *r = wl_resource_create(client, &zxdg_output_manager_v1_interface,
                                               version, id);
    if (!r) { wl_client_post_no_memory(client); return; }
    wl_resource_set_implementation(r, &xdg_output_manager_impl, NULL, NULL);
}

/* ---- seat input: pointer + keyboard (real) -------------------------------- *
 * iosc now exposes input. The Xios app forwards UIKit touch + the iOS keyboard
 * over a small AF_UNIX socket (see input socket below); we translate those into
 * wl_pointer / wl_keyboard events for the focused surface. Per-client input
 * resources are tracked so we can address the focused surface's own client. */

#define BTN_LEFT 0x110   /* linux/input-event-codes.h */

/* tracked input resources (across all clients) */
#define IOSC_MAX_SEATRES 32
static struct wl_resource *g_kbd[IOSC_MAX_SEATRES]; static int g_nkbd;
static struct wl_resource *g_ptr[IOSC_MAX_SEATRES]; static int g_nptr;
static struct wl_resource *g_tch[IOSC_MAX_SEATRES]; static int g_ntch;

static int g_keymap_fd = -1;               /* xkb keymap, sent to each wl_keyboard */
static int g_have_keyboard = 0;            /* keymap loaded => advertise KEYBOARD cap */
static uint32_t g_kbd_mods = 0;            /* last modifiers mask sent to focus     */
static struct wl_event_source *g_refocus_timer;  /* deferred focus re-assert (see below) */

static void reslist_remove(struct wl_resource **arr, int *n, struct wl_resource *r)
{
    for (int i = 0; i < *n; i++)
        if (arr[i] == r) { arr[i] = arr[--(*n)]; return; }
}

/* Surface-local pointer coords helper + top-most surface under an output point. */
static struct iosc_surface *surface_at(int x, int y)
{
    /* Session locked: input may reach only the (fullscreen, at 0,0) lock surface. */
    if (g_slock.locked)
        return (g_slock.surface && g_slock.surface->current_buffer) ? g_slock.surface : NULL;
    for (int i = g_nmapped - 1; i >= 0; i--) {
        struct iosc_surface *s = g_mapped[i];
        int w = 0, h = 0;
        surface_display_size(s, &w, &h);
        if (x >= s->dx && x < s->dx + w && y >= s->dy && y < s->dy + h)
            return s;
    }
    return NULL;
}

/* ---- text input ----------------------------------------------------------- */

#define IOSC_MAX_TEXT_INPUTS 64

struct iosc_text_input {
    struct wl_resource *resource;
    struct wl_client *client;
    struct iosc_surface *focus_surface;
    int pending_enabled;
    int enabled;
    char *surrounding;
    int32_t cursor, anchor;
    uint32_t change_cause;
    uint32_t content_hint, content_purpose;
    int32_t rect_x, rect_y, rect_w, rect_h;
    uint32_t serial;
};

static struct iosc_text_input *g_text_inputs[IOSC_MAX_TEXT_INPUTS];
static int g_ntext_inputs;

struct iosc_input_popup {
    struct wl_resource *resource;
    struct iosc_surface *surface;
};

struct iosc_input_method {
    struct wl_resource *resource;
    int active;
    uint32_t done_count;
    char *commit_text;
    char *preedit_text;
    int32_t preedit_begin, preedit_end;
    uint32_t delete_before, delete_after;
    struct wl_resource *keyboard_grab;
    struct iosc_input_popup *popups[8];
    int npopups;
};

struct iosc_virtual_keyboard {
    struct wl_resource *resource;
    int has_keymap;
};

static struct iosc_input_method *g_input_method;

static void text_input_reset_state(struct iosc_text_input *ti)
{
    if (!ti) return;
    ti->pending_enabled = 0;
    ti->enabled = 0;
    free(ti->surrounding);
    ti->surrounding = NULL;
    ti->cursor = 0;
    ti->anchor = 0;
    ti->change_cause = ZWP_TEXT_INPUT_V3_CHANGE_CAUSE_INPUT_METHOD;
    ti->content_hint = ZWP_TEXT_INPUT_V3_CONTENT_HINT_NONE;
    ti->content_purpose = ZWP_TEXT_INPUT_V3_CONTENT_PURPOSE_NORMAL;
    ti->rect_x = ti->rect_y = ti->rect_w = ti->rect_h = 0;
}

static void text_input_focus_surface(struct iosc_surface *old, struct iosc_surface *next)
{
    struct wl_client *old_client = old ? wl_resource_get_client(old->resource) : NULL;
    struct wl_client *next_client = next ? wl_resource_get_client(next->resource) : NULL;
    for (int i = 0; i < g_ntext_inputs; i++) {
        struct iosc_text_input *ti = g_text_inputs[i];
        if (!ti || !ti->resource) continue;
        if (old && ti->focus_surface == old && ti->client == old_client) {
            zwp_text_input_v3_send_leave(ti->resource, old->resource);
            ti->focus_surface = NULL;
            text_input_reset_state(ti);
        }
        if (next && ti->client == next_client) {
            ti->focus_surface = next;
            zwp_text_input_v3_send_enter(ti->resource, next->resource);
        }
    }
    input_method_update_active();
    input_clients_send_traits();
}

static struct iosc_text_input *text_input_for_focus(void)
{
    if (!g_kbd_focus) return NULL;
    struct wl_client *client = wl_resource_get_client(g_kbd_focus->resource);
    for (int i = 0; i < g_ntext_inputs; i++) {
        struct iosc_text_input *ti = g_text_inputs[i];
        if (ti && ti->client == client && ti->focus_surface == g_kbd_focus && ti->enabled)
            return ti;
    }
    return NULL;
}

static int text_input_commit_text(const char *text, size_t len)
{
    struct iosc_text_input *ti = text_input_for_focus();
    if (!ti || !text || len == 0) return 0;
    char *copy = malloc(len + 1);
    if (!copy) return -1;
    memcpy(copy, text, len);
    copy[len] = 0;
    zwp_text_input_v3_send_commit_string(ti->resource, copy);
    zwp_text_input_v3_send_done(ti->resource, ti->serial);
    free(copy);
    return 1;
}

static void input_method_clear_pending(struct iosc_input_method *im)
{
    if (!im) return;
    free(im->commit_text);
    free(im->preedit_text);
    im->commit_text = NULL;
    im->preedit_text = NULL;
    im->preedit_begin = im->preedit_end = 0;
    im->delete_before = im->delete_after = 0;
}

static void input_method_send_done(struct iosc_input_method *im)
{
    if (!im || !im->resource) return;
    zwp_input_method_v2_send_done(im->resource);
    im->done_count++;
}

static void input_method_send_state(struct iosc_input_method *im, struct iosc_text_input *ti, int activate)
{
    if (!im || !im->resource || !ti) return;
    if (activate) zwp_input_method_v2_send_activate(im->resource);
    zwp_input_method_v2_send_surrounding_text(im->resource, ti->surrounding ? ti->surrounding : "",
                                              (uint32_t)ti->cursor, (uint32_t)ti->anchor);
    zwp_input_method_v2_send_text_change_cause(im->resource, ti->change_cause);
    zwp_input_method_v2_send_content_type(im->resource, ti->content_hint, ti->content_purpose);
    input_method_send_done(im);
    for (int i = 0; i < im->npopups; i++) {
        struct iosc_input_popup *p = im->popups[i];
        if (p && p->resource)
            zwp_input_popup_surface_v2_send_text_input_rectangle(p->resource, ti->rect_x, ti->rect_y,
                                                                 ti->rect_w, ti->rect_h);
    }
}

static void input_method_update_active(void)
{
    if (!g_input_method || !g_input_method->resource) return;
    struct iosc_text_input *ti = text_input_for_focus();
    if (ti) {
        input_method_send_state(g_input_method, ti, !g_input_method->active);
        g_input_method->active = 1;
    } else if (g_input_method->active) {
        zwp_input_method_v2_send_deactivate(g_input_method->resource);
        input_method_send_done(g_input_method);
        g_input_method->active = 0;
        input_method_clear_pending(g_input_method);
    }
}

static void input_method_commit_string(struct wl_client *c, struct wl_resource *r, const char *text)
{ (void)c;
    struct iosc_input_method *im = wl_resource_get_user_data(r);
    if (!im) return;
    char *copy = strdup(text ? text : "");
    if (!copy) { wl_client_post_no_memory(c); return; }
    free(im->commit_text);
    im->commit_text = copy;
}

static void input_method_set_preedit_string(struct wl_client *c, struct wl_resource *r,
                                            const char *text, int32_t begin, int32_t end)
{ (void)c;
    struct iosc_input_method *im = wl_resource_get_user_data(r);
    if (!im) return;
    char *copy = strdup(text ? text : "");
    if (!copy) { wl_client_post_no_memory(c); return; }
    free(im->preedit_text);
    im->preedit_text = copy;
    im->preedit_begin = begin;
    im->preedit_end = end;
}

static void input_method_delete_surrounding_text(struct wl_client *c, struct wl_resource *r,
                                                 uint32_t before, uint32_t after)
{ (void)c;
    struct iosc_input_method *im = wl_resource_get_user_data(r);
    if (!im) return;
    im->delete_before = before;
    im->delete_after = after;
}

static void input_method_commit(struct wl_client *c, struct wl_resource *r, uint32_t serial)
{ (void)c;
    struct iosc_input_method *im = wl_resource_get_user_data(r);
    struct iosc_text_input *ti = text_input_for_focus();
    if (!im || !ti || !im->active || serial != im->done_count) {
        input_method_clear_pending(im);
        return;
    }
    int sent = 0;
    if (im->delete_before || im->delete_after) {
        zwp_text_input_v3_send_delete_surrounding_text(ti->resource, im->delete_before, im->delete_after);
        sent = 1;
    }
    if (im->commit_text && im->commit_text[0]) {
        zwp_text_input_v3_send_commit_string(ti->resource, im->commit_text);
        sent = 1;
    }
    if (im->preedit_text) {
        zwp_text_input_v3_send_preedit_string(ti->resource, im->preedit_text,
                                              im->preedit_begin, im->preedit_end);
        sent = 1;
    }
    if (sent) zwp_text_input_v3_send_done(ti->resource, ti->serial);
    input_method_clear_pending(im);
}

static void input_popup_destroy(struct wl_client *c, struct wl_resource *r)
{ (void)c; wl_resource_destroy(r); }

static const struct zwp_input_popup_surface_v2_interface input_popup_impl = {
    .destroy = input_popup_destroy,
};

static void input_popup_resource_destroy(struct wl_resource *r)
{
    struct iosc_input_popup *p = wl_resource_get_user_data(r);
    if (!p) return;
    if (g_input_method) {
        for (int i = 0; i < g_input_method->npopups; i++)
            if (g_input_method->popups[i] == p) {
                g_input_method->popups[i] = g_input_method->popups[--g_input_method->npopups];
                break;
            }
    }
    free(p);
}

static void input_method_get_popup_surface(struct wl_client *c, struct wl_resource *r,
                                           uint32_t id, struct wl_resource *surface)
{
    struct iosc_input_method *im = wl_resource_get_user_data(r);
    if (!im || im->npopups >= 8) { wl_client_post_no_memory(c); return; }
    struct iosc_input_popup *p = calloc(1, sizeof(*p));
    if (!p) { wl_client_post_no_memory(c); return; }
    p->surface = wl_resource_get_user_data(surface);
    p->resource = wl_resource_create(c, &zwp_input_popup_surface_v2_interface,
                                     wl_resource_get_version(r), id);
    if (!p->resource) { free(p); wl_client_post_no_memory(c); return; }
    wl_resource_set_implementation(p->resource, &input_popup_impl, p,
                                   input_popup_resource_destroy);
    im->popups[im->npopups++] = p;
}

static void input_method_grab_release(struct wl_client *c, struct wl_resource *r)
{ (void)c; wl_resource_destroy(r); }

static const struct zwp_input_method_keyboard_grab_v2_interface input_method_grab_impl = {
    .release = input_method_grab_release,
};

static void input_method_grab_destroy(struct wl_resource *r)
{
    if (g_input_method && g_input_method->keyboard_grab == r)
        g_input_method->keyboard_grab = NULL;
}

static void input_method_grab_keyboard(struct wl_client *c, struct wl_resource *r, uint32_t id)
{
    struct iosc_input_method *im = wl_resource_get_user_data(r);
    if (!im) { wl_client_post_no_memory(c); return; }
    struct wl_resource *grab = wl_resource_create(c, &zwp_input_method_keyboard_grab_v2_interface,
                                                  wl_resource_get_version(r), id);
    if (!grab) { wl_client_post_no_memory(c); return; }
    if (im->keyboard_grab) wl_resource_destroy(im->keyboard_grab);
    im->keyboard_grab = grab;
    wl_resource_set_implementation(grab, &input_method_grab_impl, NULL, input_method_grab_destroy);
    if (g_keymap_fd >= 0)
        zwp_input_method_keyboard_grab_v2_send_keymap(grab, WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1,
                                                      g_keymap_fd, iosc_input_keymap_size());
    zwp_input_method_keyboard_grab_v2_send_repeat_info(grab, 25, 600);
}

static void input_method_destroy(struct wl_client *c, struct wl_resource *r)
{ (void)c; wl_resource_destroy(r); }

static const struct zwp_input_method_v2_interface input_method_impl = {
    .commit_string = input_method_commit_string,
    .set_preedit_string = input_method_set_preedit_string,
    .delete_surrounding_text = input_method_delete_surrounding_text,
    .commit = input_method_commit,
    .get_input_popup_surface = input_method_get_popup_surface,
    .grab_keyboard = input_method_grab_keyboard,
    .destroy = input_method_destroy,
};

static void input_method_resource_destroy(struct wl_resource *r)
{
    struct iosc_input_method *im = wl_resource_get_user_data(r);
    if (!im) return;
    if (im->keyboard_grab) wl_resource_destroy(im->keyboard_grab);
    while (im->npopups > 0)
        wl_resource_destroy(im->popups[im->npopups - 1]->resource);
    input_method_clear_pending(im);
    if (g_input_method == im) g_input_method = NULL;
    free(im);
}

static void input_method_manager_get_input_method(struct wl_client *c, struct wl_resource *r,
                                                  struct wl_resource *seat, uint32_t id)
{ (void)seat;
    struct iosc_input_method *im = calloc(1, sizeof(*im));
    if (!im) { wl_client_post_no_memory(c); return; }
    struct wl_resource *res = wl_resource_create(c, &zwp_input_method_v2_interface,
                                                 wl_resource_get_version(r), id);
    if (!res) { free(im); wl_client_post_no_memory(c); return; }
    im->resource = res;
    wl_resource_set_implementation(res, &input_method_impl, im, input_method_resource_destroy);
    if (g_input_method) {
        zwp_input_method_v2_send_unavailable(res);
        return;
    }
    g_input_method = im;
    input_method_update_active();
}

static void input_method_manager_destroy(struct wl_client *c, struct wl_resource *r)
{ (void)c; wl_resource_destroy(r); }

static const struct zwp_input_method_manager_v2_interface input_method_manager_impl = {
    .get_input_method = input_method_manager_get_input_method,
    .destroy = input_method_manager_destroy,
};

static void input_method_manager_bind(struct wl_client *client, void *data, uint32_t version, uint32_t id)
{ (void)data;
    struct wl_resource *r = wl_resource_create(client, &zwp_input_method_manager_v2_interface,
                                               version, id);
    if (!r) { wl_client_post_no_memory(client); return; }
    wl_resource_set_implementation(r, &input_method_manager_impl, NULL, NULL);
}

static void virtual_keyboard_keymap(struct wl_client *c, struct wl_resource *r,
                                    uint32_t format, int32_t fd, uint32_t size)
{ (void)c; (void)format; (void)size;
    struct iosc_virtual_keyboard *vk = wl_resource_get_user_data(r);
    if (vk) vk->has_keymap = 1;
    if (fd >= 0) close(fd);
}

static void virtual_keyboard_key(struct wl_client *c, struct wl_resource *r,
                                 uint32_t time, uint32_t key, uint32_t state)
{ (void)c;
    struct iosc_virtual_keyboard *vk = wl_resource_get_user_data(r);
    if (!vk || !vk->has_keymap) {
        wl_resource_post_error(r, ZWP_VIRTUAL_KEYBOARD_V1_ERROR_NO_KEYMAP,
                               "virtual keyboard key before keymap");
        return;
    }
    keyboard_send_raw_key(time ? time : now_ms(), key, state);
}

static void virtual_keyboard_modifiers(struct wl_client *c, struct wl_resource *r,
                                       uint32_t depressed, uint32_t latched,
                                       uint32_t locked, uint32_t group)
{ (void)c; (void)group;
    struct iosc_virtual_keyboard *vk = wl_resource_get_user_data(r);
    if (!vk || !vk->has_keymap) {
        wl_resource_post_error(r, ZWP_VIRTUAL_KEYBOARD_V1_ERROR_NO_KEYMAP,
                               "virtual keyboard modifiers before keymap");
        return;
    }
    keyboard_send_mods(depressed | latched | locked);
}

static void virtual_keyboard_destroy(struct wl_client *c, struct wl_resource *r)
{ (void)c; wl_resource_destroy(r); }

static const struct zwp_virtual_keyboard_v1_interface virtual_keyboard_impl = {
    .keymap = virtual_keyboard_keymap,
    .key = virtual_keyboard_key,
    .modifiers = virtual_keyboard_modifiers,
    .destroy = virtual_keyboard_destroy,
};

static void virtual_keyboard_resource_destroy(struct wl_resource *r)
{
    free(wl_resource_get_user_data(r));
}

static void virtual_keyboard_manager_create(struct wl_client *c, struct wl_resource *r,
                                            struct wl_resource *seat, uint32_t id)
{ (void)seat;
    struct iosc_virtual_keyboard *vk = calloc(1, sizeof(*vk));
    if (!vk) { wl_client_post_no_memory(c); return; }
    vk->resource = wl_resource_create(c, &zwp_virtual_keyboard_v1_interface,
                                      wl_resource_get_version(r), id);
    if (!vk->resource) { free(vk); wl_client_post_no_memory(c); return; }
    wl_resource_set_implementation(vk->resource, &virtual_keyboard_impl, vk,
                                   virtual_keyboard_resource_destroy);
}

static const struct zwp_virtual_keyboard_manager_v1_interface virtual_keyboard_manager_impl = {
    .create_virtual_keyboard = virtual_keyboard_manager_create,
};

static void virtual_keyboard_manager_bind(struct wl_client *client, void *data, uint32_t version, uint32_t id)
{ (void)data;
    struct wl_resource *r = wl_resource_create(client, &zwp_virtual_keyboard_manager_v1_interface,
                                               version, id);
    if (!r) { wl_client_post_no_memory(client); return; }
    wl_resource_set_implementation(r, &virtual_keyboard_manager_impl, NULL, NULL);
}

static void text_input_destroy(struct wl_client *c, struct wl_resource *r)
{ (void)c; wl_resource_destroy(r); }

static void text_input_enable(struct wl_client *c, struct wl_resource *r)
{ (void)c; struct iosc_text_input *ti = wl_resource_get_user_data(r); if (ti) ti->pending_enabled = 1; }

static void text_input_disable(struct wl_client *c, struct wl_resource *r)
{ (void)c; struct iosc_text_input *ti = wl_resource_get_user_data(r); if (ti) ti->pending_enabled = 0; }

static void text_input_set_surrounding_text(struct wl_client *c, struct wl_resource *r,
                                            const char *text, int32_t cursor, int32_t anchor)
{ (void)c;
    struct iosc_text_input *ti = wl_resource_get_user_data(r);
    if (!ti) return;
    char *copy = strdup(text ? text : "");
    if (!copy) { wl_client_post_no_memory(c); return; }
    free(ti->surrounding);
    ti->surrounding = copy;
    ti->cursor = cursor;
    ti->anchor = anchor;
}

static void text_input_set_text_change_cause(struct wl_client *c, struct wl_resource *r, uint32_t cause)
{ (void)c; struct iosc_text_input *ti = wl_resource_get_user_data(r); if (ti) ti->change_cause = cause; }

static void text_input_set_content_type(struct wl_client *c, struct wl_resource *r,
                                        uint32_t hint, uint32_t purpose)
{ (void)c;
    struct iosc_text_input *ti = wl_resource_get_user_data(r);
    if (!ti) return;
    ti->content_hint = hint;
    ti->content_purpose = purpose;
}

static void text_input_set_cursor_rectangle(struct wl_client *c, struct wl_resource *r,
                                            int32_t x, int32_t y, int32_t w, int32_t h)
{ (void)c;
    struct iosc_text_input *ti = wl_resource_get_user_data(r);
    if (!ti) return;
    ti->rect_x = x;
    ti->rect_y = y;
    ti->rect_w = w;
    ti->rect_h = h;
}

static void text_input_commit(struct wl_client *c, struct wl_resource *r)
{ (void)c;
    struct iosc_text_input *ti = wl_resource_get_user_data(r);
    if (!ti) return;
    ti->enabled = ti->pending_enabled;
    zwp_text_input_v3_send_done(r, ++ti->serial);
    input_method_update_active();
    input_clients_send_traits();
}

static const struct zwp_text_input_v3_interface text_input_impl = {
    .destroy = text_input_destroy,
    .enable = text_input_enable,
    .disable = text_input_disable,
    .set_surrounding_text = text_input_set_surrounding_text,
    .set_text_change_cause = text_input_set_text_change_cause,
    .set_content_type = text_input_set_content_type,
    .set_cursor_rectangle = text_input_set_cursor_rectangle,
    .commit = text_input_commit,
};

static void text_input_resource_destroy(struct wl_resource *r)
{
    struct iosc_text_input *ti = wl_resource_get_user_data(r);
    if (!ti) return;
    for (int i = 0; i < g_ntext_inputs; i++)
        if (g_text_inputs[i] == ti) {
            g_text_inputs[i] = g_text_inputs[--g_ntext_inputs];
            break;
        }
    free(ti->surrounding);
    free(ti);
    input_method_update_active();
    input_clients_send_traits();
}

static void text_input_manager_destroy(struct wl_client *c, struct wl_resource *r)
{ (void)c; wl_resource_destroy(r); }

static void text_input_manager_get_text_input(struct wl_client *c, struct wl_resource *r,
                                              uint32_t id, struct wl_resource *seat)
{ (void)seat;
    if (g_ntext_inputs >= IOSC_MAX_TEXT_INPUTS) { wl_client_post_no_memory(c); return; }
    struct iosc_text_input *ti = calloc(1, sizeof(*ti));
    if (!ti) { wl_client_post_no_memory(c); return; }
    ti->client = c;
    ti->change_cause = ZWP_TEXT_INPUT_V3_CHANGE_CAUSE_INPUT_METHOD;
    ti->content_purpose = ZWP_TEXT_INPUT_V3_CONTENT_PURPOSE_NORMAL;
    ti->resource = wl_resource_create(c, &zwp_text_input_v3_interface,
                                      wl_resource_get_version(r), id);
    if (!ti->resource) { free(ti); wl_client_post_no_memory(c); return; }
    wl_resource_set_implementation(ti->resource, &text_input_impl, ti,
                                   text_input_resource_destroy);
    g_text_inputs[g_ntext_inputs++] = ti;
    if (g_kbd_focus && wl_resource_get_client(g_kbd_focus->resource) == c) {
        ti->focus_surface = g_kbd_focus;
        zwp_text_input_v3_send_enter(ti->resource, g_kbd_focus->resource);
    }
}

static const struct zwp_text_input_manager_v3_interface text_input_manager_impl = {
    .destroy = text_input_manager_destroy,
    .get_text_input = text_input_manager_get_text_input,
};

static void text_input_manager_bind(struct wl_client *client, void *data, uint32_t version, uint32_t id)
{ (void)data;
    struct wl_resource *r = wl_resource_create(client, &zwp_text_input_manager_v3_interface,
                                               version, id);
    if (!r) { wl_client_post_no_memory(client); return; }
    wl_resource_set_implementation(r, &text_input_manager_impl, NULL, NULL);
}

/* ---- keyboard ------------------------------------------------------------- */

static void input_release(struct wl_client *c, struct wl_resource *r){ (void)c; wl_resource_destroy(r); }

/* Low-level wl_keyboard leave/enter to a surface's owning client. */
static void kbd_send_leave(struct iosc_surface *s)
{
    if (!s) return;
    struct wl_client *c = wl_resource_get_client(s->resource);
    uint32_t serial = wl_display_next_serial(g_display);
    for (int i = 0; i < g_nkbd; i++)
        if (wl_resource_get_client(g_kbd[i]) == c)
            wl_keyboard_send_leave(g_kbd[i], serial, s->resource);
}
static void kbd_send_enter(struct iosc_surface *s)
{
    if (!s) return;
    struct wl_client *c = wl_resource_get_client(s->resource);
    struct wl_array keys; wl_array_init(&keys);
    uint32_t es = wl_display_next_serial(g_display);
    for (int i = 0; i < g_nkbd; i++)
        if (wl_resource_get_client(g_kbd[i]) == c) {
            wl_keyboard_send_enter(g_kbd[i], es, s->resource, &keys);
            wl_keyboard_send_modifiers(g_kbd[i], es, 0, 0, 0, 0);
        }
    wl_array_release(&keys);
}

/* Set keyboard focus (enter/leave). After focusing a real surface we arm a one-shot
 * timer that re-asserts focus (leave+enter): GTK4's FIRST toplevel can take keyboard
 * focus on the window before its child widget tree (the terminal) is realized, so
 * accelerators fire but typed text goes nowhere; a deferred re-enter, once the widget
 * has realized, makes GTK focus the actual text widget. (Subsequent windows already
 * focus their content correctly, but re-asserting is harmless.) */
static void keyboard_set_focus(struct iosc_surface *s)
{
    /* Session locked: all keyboard focus belongs to the lock surface (or nothing
     * until it maps); windows mapping/unmapping underneath can't steal it. */
    if (g_slock.locked && s != g_slock.surface)
        s = g_slock.surface;
    if (g_kbd_focus == s) return;
    struct iosc_surface *old = g_kbd_focus;
    kbd_send_leave(old);
    text_input_focus_surface(old, s);
    g_kbd_focus = s;
    g_kbd_mods = 0;
    ftl_broadcast_state(old);          /* focus moved: update ACTIVATED on the taskbar */
    ftl_broadcast_state(s);
    if (s) {
        kbd_send_enter(s);
        int nk = 0;
        struct wl_client *nc = wl_resource_get_client(s->resource);
        for (int i = 0; i < g_nkbd; i++) if (wl_resource_get_client(g_kbd[i]) == nc) nk++;
        fprintf(stderr, "iosc: keyboard focus -> surface %p (%d kbd resource(s))\n",
                (void *)s, nk);
        clipboard_selection_send_to_client(nc);
        primary_selection_send_to_client(nc);
        if (g_refocus_timer) wl_event_source_timer_update(g_refocus_timer, 600);
    }
}

/* Deferred focus re-assert (armed by keyboard_set_focus). One-shot leave+enter. */
static int refocus_cb(void *data)
{
    (void)data;
    if (g_kbd_focus) {
        kbd_send_leave(g_kbd_focus);
        kbd_send_enter(g_kbd_focus);
        wl_display_flush_clients(g_display);
        fprintf(stderr, "iosc: deferred keyboard-focus re-assert on %p\n", (void *)g_kbd_focus);
    }
    return 0;
}

/* Send one modifiers mask to the focused client's keyboards (only on change). */
static void keyboard_send_mods(uint32_t mask)
{
    if (!g_kbd_focus || mask == g_kbd_mods) return;
    g_kbd_mods = mask;
    struct wl_client *fc = wl_resource_get_client(g_kbd_focus->resource);
    uint32_t serial = wl_display_next_serial(g_display);
    for (int i = 0; i < g_nkbd; i++)
        if (wl_resource_get_client(g_kbd[i]) == fc)
            wl_keyboard_send_modifiers(g_kbd[i], serial, mask, 0, 0, 0);
}

static void keyboard_send_raw_key(uint32_t time, uint32_t key, uint32_t state)
{
    if (!g_kbd_focus) return;
    struct wl_client *fc = wl_resource_get_client(g_kbd_focus->resource);
    uint32_t serial = wl_display_next_serial(g_display);
    for (int i = 0; i < g_nkbd; i++)
        if (wl_resource_get_client(g_kbd[i]) == fc)
            wl_keyboard_send_key(g_kbd[i], serial, time, key, state);
}

static int input_method_forward_grab_key(uint32_t time, uint32_t key, uint32_t state, uint32_t mods)
{
    if (!g_input_method || !g_input_method->active || !g_input_method->keyboard_grab) return 0;
    struct wl_resource *grab = g_input_method->keyboard_grab;
    uint32_t serial = wl_display_next_serial(g_display);
    zwp_input_method_keyboard_grab_v2_send_modifiers(grab, serial, mods, 0, 0, 0);
    zwp_input_method_keyboard_grab_v2_send_key(grab, serial, time, key, state);
    return 1;
}

/* A key "tap": one X keysym + the app's armed ctrl/alt/shift. Resolve to an evdev
 * keycode (+ whether Shift is needed for the symbol) and bracket the key with the
 * right modifier mask, then press + release. */
static void handle_key(uint32_t keysym, uint32_t appmods)
{
    idle_note_activity();
    if (!g_kbd_focus) return;
    uint32_t evdev = 0; int needs_shift = 0;
    if (iosc_input_lookup(keysym, &evdev, &needs_shift) != 0) {
        fprintf(stderr, "iosc: key keysym 0x%x not in keymap\n", keysym);
        return;
    }
    int want_shift = needs_shift || (appmods & 1);
    uint32_t mask = (want_shift ? iosc_input_mod_shift() : 0)
                  | ((appmods & 2) ? iosc_input_mod_ctrl() : 0)
                  | ((appmods & 4) ? iosc_input_mod_alt()  : 0);

    struct wl_client *fc = wl_resource_get_client(g_kbd_focus->resource);
    int nk = 0;
    for (int i = 0; i < g_nkbd; i++) if (wl_resource_get_client(g_kbd[i]) == fc) nk++;
    fprintf(stderr, "iosc: key keysym=0x%x -> evdev=%u shift=%d mask=0x%x to %d kbd(s)\n",
            keysym, evdev, want_shift, mask, nk);
    uint32_t t = now_ms();
    if (input_method_forward_grab_key(t, evdev, WL_KEYBOARD_KEY_STATE_PRESSED, mask) &&
        input_method_forward_grab_key(t, evdev, WL_KEYBOARD_KEY_STATE_RELEASED, 0))
        return;
    keyboard_send_mods(mask);
    keyboard_send_raw_key(t, evdev, WL_KEYBOARD_KEY_STATE_PRESSED);
    keyboard_send_raw_key(t, evdev, WL_KEYBOARD_KEY_STATE_RELEASED);
    keyboard_send_mods(0);
}

/* ---- pointer -------------------------------------------------------------- */

static void pointer_frame_client(struct wl_client *cl)
{
    for (int i = 0; i < g_nptr; i++)
        if (wl_resource_get_client(g_ptr[i]) == cl &&
            wl_resource_get_version(g_ptr[i]) >= WL_POINTER_FRAME_SINCE_VERSION)
            wl_pointer_send_frame(g_ptr[i]);
}

static void handle_motion(int x, int y)
{
    idle_note_activity();
    int prev_x = g_cursor_x, prev_y = g_cursor_y;

    /* pointer-constraints: a LOCKED pointer freezes the cursor in place and the
     * client navigates purely by relative-pointer deltas (games, 3D viewports,
     * gnome-shell mouse-look). Suppress all absolute pointer events + the cursor
     * move; only report the relative delta. */
    if (pointer_locked_for(g_ptr_focus)) {
        double rdx = (double)(x - prev_x), rdy = (double)(y - prev_y);
        if (rdx != 0.0 || rdy != 0.0) relptr_send(now_ms(), rdx, rdy);
        return;
    }
    /* A CONFINED pointer is clamped to its surface's rectangle. */
    if (g_ptr_focus) confine_point(g_ptr_focus, &x, &y);

    int moved = (x != g_cursor_x || y != g_cursor_y);
    g_cursor_x = x;
    g_cursor_y = y;
    /* An active drag drives wl_data_device (enter/motion/leave) + the drag icon,
     * not normal wl_pointer events. */
    if (g_dnd.active) {
        dnd_update_motion(x, y, now_ms());
        if (moved) recomposite_all();          /* move the drag icon */
        return;
    }
    if (g_interactive_op != IOSC_INTERACTIVE_NONE) {
        interactive_update(x, y);
        return;
    }
    struct iosc_surface *hit = surface_at(x, y);
    uint32_t t = now_ms();
    /* relative-pointer: deltas go to whoever holds pointer focus, lock or not. */
    {
        double rdx = (double)(x - prev_x), rdy = (double)(y - prev_y);
        if (g_ptr_focus && (rdx != 0.0 || rdy != 0.0)) relptr_send(t, rdx, rdy);
    }
    if (hit != g_ptr_focus) {
        uint32_t serial = wl_display_next_serial(g_display);
        if (g_ptr_focus) {
            struct wl_client *oc = wl_resource_get_client(g_ptr_focus->resource);
            for (int i = 0; i < g_nptr; i++)
                if (wl_resource_get_client(g_ptr[i]) == oc)
                    wl_pointer_send_leave(g_ptr[i], serial, g_ptr_focus->resource);
            pointer_frame_client(oc);
        }
        g_ptr_focus = hit;
        constraints_update_focus(hit);
        if (hit) {
            struct wl_client *nc = wl_resource_get_client(hit->resource);
            wl_fixed_t sx = wl_fixed_from_int(x - hit->dx), sy = wl_fixed_from_int(y - hit->dy);
            for (int i = 0; i < g_nptr; i++)
                if (wl_resource_get_client(g_ptr[i]) == nc)
                    wl_pointer_send_enter(g_ptr[i], serial, hit->resource, sx, sy);
            pointer_frame_client(nc);
        }
    }
    if (g_ptr_focus) {
        struct wl_client *fc = wl_resource_get_client(g_ptr_focus->resource);
        wl_fixed_t sx = wl_fixed_from_int(x - g_ptr_focus->dx);
        wl_fixed_t sy = wl_fixed_from_int(y - g_ptr_focus->dy);
        for (int i = 0; i < g_nptr; i++)
            if (wl_resource_get_client(g_ptr[i]) == fc)
                wl_pointer_send_motion(g_ptr[i], t, sx, sy);
        pointer_frame_client(fc);
    }
    if (moved) {
        if (iosc_app_cursor())
            app_cursor_notify();          /* overlay: one socket write, no recomposite */
        else if (g_cursor_visible)
            recomposite_all();            /* classic: repaint to move the composited cursor */
    }
}

/* Raise a surface to the top of ITS z-band (clicked window comes forward, but a
 * toplevel never jumps above the panel/overlay band). */
static void surface_raise(struct iosc_surface *s)
{
    int idx = -1;
    for (int i = 0; i < g_nmapped; i++) if (g_mapped[i] == s) { idx = i; break; }
    if (idx < 0) return;
    int band = surface_band(s);
    int top = idx;                         /* highest index still in this band */
    for (int i = idx + 1; i < g_nmapped; i++) {
        if (surface_band(g_mapped[i]) > band) break;
        top = i;
    }
    if (top == idx) return;
    for (int i = idx; i < top; i++) g_mapped[i] = g_mapped[i + 1];
    g_mapped[top] = s;
}

static void handle_button(int btn, int down)
{
    (void)btn;
    idle_note_activity();
    g_button_down = down;
    /* During a drag the button is owned by the grab: releasing it performs the
     * drop (or cancels); a press is swallowed. */
    if (g_dnd.active) {
        if (!down) dnd_drop();
        return;
    }
    if (!down && g_interactive_op != IOSC_INTERACTIVE_NONE) {
        interactive_end();
        return;
    }
    if (down && g_ptr_focus) {
        struct iosc_surface *pf = g_ptr_focus;
        /* A panel (layer surface with keyboard_interactivity=none) must never
         * steal focus or reorder; it still gets its pointer events below. */
        int take_focus = !(pf->role == IOSC_ROLE_LAYER && pf->layer &&
            pf->layer->kbd_interactivity == ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_NONE);
        if (take_focus) {
            int was_top = (g_nmapped > 0 && g_mapped[g_nmapped - 1] == pf);
            surface_raise(pf);
            keyboard_set_focus(pf);
            if (!was_top) recomposite_all();   /* show the raised window on top */
        }
    }
    if (!g_ptr_focus) return;
    struct wl_client *fc = wl_resource_get_client(g_ptr_focus->resource);
    uint32_t serial = wl_display_next_serial(g_display);
    uint32_t t = now_ms();
    if (down) g_button_serial = serial;
    for (int i = 0; i < g_nptr; i++)
        if (wl_resource_get_client(g_ptr[i]) == fc)
            wl_pointer_send_button(g_ptr[i], serial, t, BTN_LEFT,
                                   down ? WL_POINTER_BUTTON_STATE_PRESSED
                                        : WL_POINTER_BUTTON_STATE_RELEASED);
    pointer_frame_client(fc);
}

/* ---- touch (wl_touch; fed by IOSC_IN_TOUCH from the app or the injector) --- *
 * Wayland touch semantics: the surface that receives `down` for a touch id owns
 * that id's whole sequence (motion/up follow it even if the finger wanders off
 * the window); each id is independent, so this is real multitouch. Events go to
 * the owning surface's client only, batched per-event with a frame. */

#define IOSC_TOUCH_UP     0     /* wire phases in iosc_in_msg.state */
#define IOSC_TOUCH_DOWN   1
#define IOSC_TOUCH_MOTION 2
#define IOSC_TOUCH_CANCEL 3

#define IOSC_MAX_TOUCH_POINTS 10
struct iosc_touch_point {
    int active;
    int id;                        /* touch id from the app (UITouch slot) */
    struct iosc_surface *surface;  /* implicit grab: the surface that got down */
};
static struct iosc_touch_point g_touch_points[IOSC_MAX_TOUCH_POINTS];

static void touch_frame_client(struct wl_client *cl)
{
    for (int i = 0; i < g_ntch; i++)
        if (wl_resource_get_client(g_tch[i]) == cl)
            wl_touch_send_frame(g_tch[i]);
}

static void touch_cancel_client(struct wl_client *cl)
{
    for (int i = 0; i < g_ntch; i++)
        if (wl_resource_get_client(g_tch[i]) == cl)
            wl_touch_send_cancel(g_tch[i]);
}

/* One wl_touch.cancel wipes every in-flight point of that client, so cancel each
 * involved client once and deactivate all its points together. */
static void touch_cancel_all(void)
{
    for (int i = 0; i < IOSC_MAX_TOUCH_POINTS; i++) {
        struct iosc_touch_point *p = &g_touch_points[i];
        if (!p->active) continue;
        p->active = 0;
        if (!p->surface) continue;
        struct wl_client *cl = wl_resource_get_client(p->surface->resource);
        touch_cancel_client(cl);
        for (int j = i + 1; j < IOSC_MAX_TOUCH_POINTS; j++)
            if (g_touch_points[j].active && g_touch_points[j].surface &&
                wl_resource_get_client(g_touch_points[j].surface->resource) == cl)
                g_touch_points[j].active = 0;
    }
}

static void touch_surface_gone(struct iosc_surface *s)
{
    int cancelled = 0;
    for (int i = 0; i < IOSC_MAX_TOUCH_POINTS; i++) {
        struct iosc_touch_point *p = &g_touch_points[i];
        if (!p->active || p->surface != s) continue;
        if (!cancelled) {
            touch_cancel_client(wl_resource_get_client(s->resource));
            cancelled = 1;
        }
        p->active = 0;
    }
}

static struct iosc_touch_point *touch_point_by_id(int id)
{
    for (int i = 0; i < IOSC_MAX_TOUCH_POINTS; i++)
        if (g_touch_points[i].active && g_touch_points[i].id == id)
            return &g_touch_points[i];
    return NULL;
}

static void handle_touch(int id, int phase, int x, int y)
{
    idle_note_activity();
    if (phase == IOSC_TOUCH_CANCEL) {
        touch_cancel_all();
        return;
    }
    if (phase == IOSC_TOUCH_DOWN) {
        struct iosc_surface *hit = surface_at(x, y);   /* honors session lock */
        if (!hit) return;
        struct iosc_touch_point *p = touch_point_by_id(id);
        if (!p)
            for (int i = 0; i < IOSC_MAX_TOUCH_POINTS; i++)
                if (!g_touch_points[i].active) { p = &g_touch_points[i]; break; }
        if (!p) return;                                /* all slots busy */
        p->active = 1;
        p->id = id;
        p->surface = hit;
        /* Same focus-on-press rules as the pointer: raise + keyboard focus,
         * except for no-keyboard layer panels. */
        int take_focus = !(hit->role == IOSC_ROLE_LAYER && hit->layer &&
            hit->layer->kbd_interactivity == ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_NONE);
        if (take_focus) {
            int was_top = (g_nmapped > 0 && g_mapped[g_nmapped - 1] == hit);
            surface_raise(hit);
            keyboard_set_focus(hit);
            if (!was_top) recomposite_all();
        }
        struct wl_client *cl = wl_resource_get_client(hit->resource);
        uint32_t serial = wl_display_next_serial(g_display);
        uint32_t t = now_ms();
        for (int i = 0; i < g_ntch; i++)
            if (wl_resource_get_client(g_tch[i]) == cl)
                wl_touch_send_down(g_tch[i], serial, t, hit->resource, id,
                                   wl_fixed_from_int(x - hit->dx),
                                   wl_fixed_from_int(y - hit->dy));
        touch_frame_client(cl);
        return;
    }
    /* MOTION / UP go to the point's grab surface, coords relative to it. */
    struct iosc_touch_point *p = touch_point_by_id(id);
    if (!p || !p->surface) return;
    struct wl_client *cl = wl_resource_get_client(p->surface->resource);
    uint32_t t = now_ms();
    if (phase == IOSC_TOUCH_MOTION) {
        for (int i = 0; i < g_ntch; i++)
            if (wl_resource_get_client(g_tch[i]) == cl)
                wl_touch_send_motion(g_tch[i], t, id,
                                     wl_fixed_from_int(x - p->surface->dx),
                                     wl_fixed_from_int(y - p->surface->dy));
        touch_frame_client(cl);
    } else if (phase == IOSC_TOUCH_UP) {
        uint32_t serial = wl_display_next_serial(g_display);
        for (int i = 0; i < g_ntch; i++)
            if (wl_resource_get_client(g_tch[i]) == cl)
                wl_touch_send_up(g_tch[i], serial, t, id);
        touch_frame_client(cl);
        p->active = 0;
    }
}

/* ---- tablet-v2 (Apple Pencil; fed by IOSC_IN_TABLET) ----------------------- *
 * One virtual tablet ("Apple Pencil") with one PEN tool advertising PRESSURE +
 * TILT, announced to every zwp_tablet_seat_v2 as it is created. The iPad 7 has
 * no hover, so each stroke is bracketed proximity_in .. down .. motion ..
 * up .. proximity_out; like touch, the surface under the pen at `down` owns
 * the whole stroke. */

#define IOSC_PEN_UP     0     /* wire phases in iosc_in_msg.state */
#define IOSC_PEN_DOWN   1
#define IOSC_PEN_MOTION 2
#define IOSC_PEN_CANCEL 3

#define IOSC_MAX_TABLET_SEATS 16
struct iosc_tablet_seat {          /* one per zwp_tablet_seat_v2 resource */
    struct wl_resource *seat;
    struct wl_resource *tablet;    /* zwp_tablet_v2 announced on it */
    struct wl_resource *tool;      /* zwp_tablet_tool_v2 (the pen) */
};
static struct iosc_tablet_seat *g_tablet_seats[IOSC_MAX_TABLET_SEATS];
static int g_ntablet_seats;

static struct iosc_surface *g_pen_focus;   /* surface owning the current stroke */
static int g_pen_down;

static struct iosc_tablet_seat *tablet_seat_for_client(struct wl_client *cl)
{
    for (int i = 0; i < g_ntablet_seats; i++)
        if (g_tablet_seats[i] && g_tablet_seats[i]->seat &&
            wl_resource_get_client(g_tablet_seats[i]->seat) == cl)
            return g_tablet_seats[i];
    return NULL;
}

/* End the current stroke: up (if the tip is down) + proximity_out. */
static void pen_leave(uint32_t t)
{
    if (!g_pen_focus) return;
    struct iosc_tablet_seat *ts =
        tablet_seat_for_client(wl_resource_get_client(g_pen_focus->resource));
    if (ts && ts->tool) {
        if (g_pen_down)
            zwp_tablet_tool_v2_send_up(ts->tool);
        zwp_tablet_tool_v2_send_proximity_out(ts->tool);
        zwp_tablet_tool_v2_send_frame(ts->tool, t);
    }
    g_pen_focus = NULL;
    g_pen_down = 0;
}

static void pen_surface_gone(struct iosc_surface *s)
{
    if (g_pen_focus == s) pen_leave(now_ms());
}

static void pen_send_axes(struct iosc_tablet_seat *ts, struct iosc_surface *s,
                          int x, int y, uint32_t pressure, int tiltx, int tilty)
{
    zwp_tablet_tool_v2_send_motion(ts->tool, wl_fixed_from_int(x - s->dx),
                                   wl_fixed_from_int(y - s->dy));
    zwp_tablet_tool_v2_send_pressure(ts->tool, pressure > 65535u ? 65535u : pressure);
    zwp_tablet_tool_v2_send_tilt(ts->tool, wl_fixed_from_int(tiltx),
                                 wl_fixed_from_int(tilty));
}

static void handle_pencil(int phase, int x, int y, uint32_t pressure, int tiltx, int tilty)
{
    idle_note_activity();
    uint32_t t = now_ms();
    if (phase == IOSC_PEN_CANCEL) { pen_leave(t); return; }
    if (phase == IOSC_PEN_DOWN) {
        struct iosc_surface *hit = surface_at(x, y);   /* honors session lock */
        if (hit != g_pen_focus) pen_leave(t);
        if (!hit) return;
        /* Same focus-on-press rules as pointer/touch. */
        int take_focus = !(hit->role == IOSC_ROLE_LAYER && hit->layer &&
            hit->layer->kbd_interactivity == ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_NONE);
        if (take_focus) {
            int was_top = (g_nmapped > 0 && g_mapped[g_nmapped - 1] == hit);
            surface_raise(hit);
            keyboard_set_focus(hit);
            if (!was_top) recomposite_all();
        }
        int entering = (g_pen_focus != hit);
        g_pen_focus = hit;
        g_pen_down = 1;
        struct iosc_tablet_seat *ts =
            tablet_seat_for_client(wl_resource_get_client(hit->resource));
        if (!ts || !ts->tool || !ts->tablet) return;   /* client has no tablet seat */
        if (entering)
            zwp_tablet_tool_v2_send_proximity_in(ts->tool, wl_display_next_serial(g_display),
                                                 ts->tablet, hit->resource);
        pen_send_axes(ts, hit, x, y, pressure, tiltx, tilty);
        zwp_tablet_tool_v2_send_down(ts->tool, wl_display_next_serial(g_display));
        zwp_tablet_tool_v2_send_frame(ts->tool, t);
        return;
    }
    /* MOTION / UP belong to the stroke's grab surface. */
    if (!g_pen_focus) return;
    struct iosc_tablet_seat *ts =
        tablet_seat_for_client(wl_resource_get_client(g_pen_focus->resource));
    if (!ts || !ts->tool) {
        if (phase == IOSC_PEN_UP) { g_pen_focus = NULL; g_pen_down = 0; }
        return;
    }
    if (phase == IOSC_PEN_MOTION) {
        pen_send_axes(ts, g_pen_focus, x, y, pressure, tiltx, tilty);
        zwp_tablet_tool_v2_send_frame(ts->tool, t);
    } else if (phase == IOSC_PEN_UP) {
        pen_leave(t);   /* up + proximity_out + frame */
    }
}

/* -- protocol plumbing: manager / seat / tablet / tool objects -------------- */

static void tablet_tool_set_cursor(struct wl_client *c, struct wl_resource *r, uint32_t serial,
                                   struct wl_resource *surf, int32_t hx, int32_t hy)
{ (void)c; (void)r; (void)serial; (void)surf; (void)hx; (void)hy; }   /* pen has no cursor here */
static void tablet_obj_destroy_req(struct wl_client *c, struct wl_resource *r)
{ (void)c; wl_resource_destroy(r); }
static const struct zwp_tablet_tool_v2_interface tablet_tool_impl = {
    .set_cursor = tablet_tool_set_cursor,
    .destroy = tablet_obj_destroy_req,
};
static const struct zwp_tablet_v2_interface tablet_impl = {
    .destroy = tablet_obj_destroy_req,
};

static void tablet_tool_res_destroy(struct wl_resource *r)
{
    struct iosc_tablet_seat *ts = wl_resource_get_user_data(r);
    if (ts && ts->tool == r) ts->tool = NULL;
}
static void tablet_res_destroy(struct wl_resource *r)
{
    struct iosc_tablet_seat *ts = wl_resource_get_user_data(r);
    if (ts && ts->tablet == r) ts->tablet = NULL;
}
static void tablet_seat_res_destroy(struct wl_resource *r)
{
    struct iosc_tablet_seat *ts = wl_resource_get_user_data(r);
    if (!ts) return;
    /* Disarm surviving child resources so their destructors don't touch us. */
    if (ts->tool)   wl_resource_set_user_data(ts->tool, NULL);
    if (ts->tablet) wl_resource_set_user_data(ts->tablet, NULL);
    for (int i = 0; i < g_ntablet_seats; i++)
        if (g_tablet_seats[i] == ts) {
            g_tablet_seats[i] = g_tablet_seats[--g_ntablet_seats];
            break;
        }
    free(ts);
}

static const struct zwp_tablet_seat_v2_interface tablet_seat_impl = {
    .destroy = tablet_obj_destroy_req,
};

static void tablet_mgr_get_tablet_seat(struct wl_client *c, struct wl_resource *r,
                                       uint32_t id, struct wl_resource *seat)
{ (void)seat;
    if (g_ntablet_seats >= IOSC_MAX_TABLET_SEATS) { wl_client_post_no_memory(c); return; }
    struct iosc_tablet_seat *ts = calloc(1, sizeof(*ts));
    if (!ts) { wl_client_post_no_memory(c); return; }
    uint32_t v = wl_resource_get_version(r);
    ts->seat   = wl_resource_create(c, &zwp_tablet_seat_v2_interface, v, id);
    ts->tablet = wl_resource_create(c, &zwp_tablet_v2_interface, v, 0);
    ts->tool   = wl_resource_create(c, &zwp_tablet_tool_v2_interface, v, 0);
    if (!ts->seat || !ts->tablet || !ts->tool) {
        if (ts->seat)   wl_resource_destroy(ts->seat);
        if (ts->tablet) wl_resource_destroy(ts->tablet);
        if (ts->tool)   wl_resource_destroy(ts->tool);
        free(ts);
        wl_client_post_no_memory(c);
        return;
    }
    wl_resource_set_implementation(ts->seat,   &tablet_seat_impl, ts, tablet_seat_res_destroy);
    wl_resource_set_implementation(ts->tablet, &tablet_impl,      ts, tablet_res_destroy);
    wl_resource_set_implementation(ts->tool,   &tablet_tool_impl, ts, tablet_tool_res_destroy);
    g_tablet_seats[g_ntablet_seats++] = ts;
    /* Announce the pencil: tablet first, then the pen tool with its axes. */
    zwp_tablet_seat_v2_send_tablet_added(ts->seat, ts->tablet);
    zwp_tablet_v2_send_name(ts->tablet, "Apple Pencil");
    zwp_tablet_v2_send_path(ts->tablet, "iosc/pencil");
    zwp_tablet_v2_send_done(ts->tablet);
    zwp_tablet_seat_v2_send_tool_added(ts->seat, ts->tool);
    zwp_tablet_tool_v2_send_type(ts->tool, ZWP_TABLET_TOOL_V2_TYPE_PEN);
    zwp_tablet_tool_v2_send_capability(ts->tool, ZWP_TABLET_TOOL_V2_CAPABILITY_PRESSURE);
    zwp_tablet_tool_v2_send_capability(ts->tool, ZWP_TABLET_TOOL_V2_CAPABILITY_TILT);
    zwp_tablet_tool_v2_send_done(ts->tool);
    fprintf(stderr, "iosc: tablet seat created (now %d)\n", g_ntablet_seats);
}

static const struct zwp_tablet_manager_v2_interface tablet_mgr_impl = {
    .get_tablet_seat = tablet_mgr_get_tablet_seat,
    .destroy = tablet_obj_destroy_req,
};
static void tablet_mgr_bind(struct wl_client *c, void *data, uint32_t version, uint32_t id)
{ (void)data;
    struct wl_resource *r = wl_resource_create(c, &zwp_tablet_manager_v2_interface, version, id);
    if (!r) { wl_client_post_no_memory(c); return; }
    wl_resource_set_implementation(r, &tablet_mgr_impl, NULL, NULL);
}

/* ---- wl_pointer / wl_keyboard / wl_touch resources ------------------------ */

static void pointer_set_cursor(struct wl_client *c, struct wl_resource *r, uint32_t serial,
                               struct wl_resource *surf, int32_t hx, int32_t hy)
{ (void)r; (void)serial;
    if (g_ptr_focus && wl_resource_get_client(g_ptr_focus->resource) != c)
        return;
    g_named_cursor = 0;   /* a client cursor surface supersedes any cursor-shape */
    g_cursor_surface = surf ? wl_resource_get_user_data(surf) : NULL;
    g_cursor_hot_x = hx;
    g_cursor_hot_y = hy;
    g_cursor_visible = g_cursor_surface != NULL;
    if (iosc_app_cursor()) app_cursor_notify();   /* overlay: push shape/visibility, no repaint */
    else recomposite_all();
}
static const struct wl_pointer_interface pointer_impl = { .set_cursor = pointer_set_cursor, .release = input_release };
static const struct wl_keyboard_interface keyboard_impl = { .release = input_release };
static const struct wl_touch_interface touch_impl = { .release = input_release };

static void pointer_res_destroy(struct wl_resource *r){ reslist_remove(g_ptr, &g_nptr, r); }
static void keyboard_res_destroy(struct wl_resource *r){ reslist_remove(g_kbd, &g_nkbd, r); }
static void touch_res_destroy(struct wl_resource *r){ reslist_remove(g_tch, &g_ntch, r); }

static void seat_get_pointer(struct wl_client *c, struct wl_resource *r, uint32_t id)
{
    struct wl_resource *p = wl_resource_create(c, &wl_pointer_interface, wl_resource_get_version(r), id);
    if (!p) return;
    wl_resource_set_implementation(p, &pointer_impl, NULL, pointer_res_destroy);
    if (g_nptr < IOSC_MAX_SEATRES) g_ptr[g_nptr++] = p;
    fprintf(stderr, "iosc: wl_pointer bound (now %d)\n", g_nptr);
}
static void seat_get_keyboard(struct wl_client *c, struct wl_resource *r, uint32_t id)
{
    struct wl_resource *k = wl_resource_create(c, &wl_keyboard_interface, wl_resource_get_version(r), id);
    if (!k) return;
    wl_resource_set_implementation(k, &keyboard_impl, NULL, keyboard_res_destroy);
    if (g_nkbd < IOSC_MAX_SEATRES) g_kbd[g_nkbd++] = k;
    fprintf(stderr, "iosc: wl_keyboard bound (now %d)\n", g_nkbd);
    /* Hand over the keymap immediately (the client mmaps it for xkb). */
    if (g_keymap_fd >= 0)
        wl_keyboard_send_keymap(k, WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1,
                                g_keymap_fd, iosc_input_keymap_size());
    if (wl_resource_get_version(k) >= WL_KEYBOARD_REPEAT_INFO_SINCE_VERSION)
        wl_keyboard_send_repeat_info(k, 25, 600);
    /* If this client already owns the focused surface, send it enter now. */
    if (g_kbd_focus && wl_resource_get_client(g_kbd_focus->resource) == c) {
        struct wl_array keys; wl_array_init(&keys);
        uint32_t es = wl_display_next_serial(g_display);
        wl_keyboard_send_enter(k, es, g_kbd_focus->resource, &keys);
        wl_keyboard_send_modifiers(k, es, 0, 0, 0, 0);
        wl_array_release(&keys);
    }
}
static void seat_get_touch(struct wl_client *c, struct wl_resource *r, uint32_t id)
{
    struct wl_resource *t = wl_resource_create(c, &wl_touch_interface, wl_resource_get_version(r), id);
    if (!t) return;
    wl_resource_set_implementation(t, &touch_impl, NULL, touch_res_destroy);
    if (g_ntch < IOSC_MAX_SEATRES) g_tch[g_ntch++] = t;
    fprintf(stderr, "iosc: wl_touch bound (now %d)\n", g_ntch);
}
static void seat_release(struct wl_client *c, struct wl_resource *r){ (void)c; wl_resource_destroy(r); }
static const struct wl_seat_interface seat_impl = {
    .get_pointer = seat_get_pointer, .get_keyboard = seat_get_keyboard,
    .get_touch = seat_get_touch, .release = seat_release };
static void seat_bind(struct wl_client *client, void *data, uint32_t version, uint32_t id)
{
    (void)data;
    struct wl_resource *r = wl_resource_create(client, &wl_seat_interface, version, id);
    if (!r) { wl_client_post_no_memory(client); return; }
    wl_resource_set_implementation(r, &seat_impl, NULL, NULL);
    wl_seat_send_capabilities(r, WL_SEAT_CAPABILITY_POINTER |
                                 WL_SEAT_CAPABILITY_TOUCH |
                                 (g_have_keyboard ? WL_SEAT_CAPABILITY_KEYBOARD : 0));
    if (version >= 2) wl_seat_send_name(r, "seat0");
}

/* wl_subcompositor — child surfaces composed by the same GPU path. */
static void subsurface_resource_destroy(struct wl_resource *r)
{
    struct iosc_subsurface *ss = wl_resource_get_user_data(r);
    if (!ss) return;
    if (ss->surface) {
        surface_unmap(ss->surface);
        ss->surface->subsurface = NULL;
        ss->surface->parent = NULL;
        ss->surface->role = IOSC_ROLE_NONE;
        recomposite_all();
    }
    free(ss);
}

static void subsurface_destroy(struct wl_client *c, struct wl_resource *r)
{ (void)c; wl_resource_destroy(r); }
static void subsurface_set_position(struct wl_client *c, struct wl_resource *r, int32_t x, int32_t y)
{
    (void)c;
    struct iosc_subsurface *ss = wl_resource_get_user_data(r);
    if (!ss || !ss->surface) return;
    ss->x = x; ss->y = y;
    ss->surface->rel_x = x;
    ss->surface->rel_y = y;
    surface_place_child(ss->surface);
    if (ss->surface->mapped) recomposite_all();
}
static void subsurface_place_above(struct wl_client *c, struct wl_resource *r, struct wl_resource *s)
{ (void)c; (void)s; struct iosc_subsurface *ss = wl_resource_get_user_data(r);
  if (ss && ss->surface) { surface_raise(ss->surface); recomposite_all(); } }
static void subsurface_place_below(struct wl_client *c, struct wl_resource *r, struct wl_resource *s)
{ (void)c; (void)r; (void)s; }
static void subsurface_set_sync(struct wl_client *c, struct wl_resource *r){ (void)c;(void)r; }
static void subsurface_set_desync(struct wl_client *c, struct wl_resource *r){ (void)c;(void)r; }
static const struct wl_subsurface_interface subsurface_impl = {
    .destroy = subsurface_destroy, .set_position = subsurface_set_position,
    .place_above = subsurface_place_above, .place_below = subsurface_place_below,
    .set_sync = subsurface_set_sync, .set_desync = subsurface_set_desync };
static void subcompositor_destroy(struct wl_client *c, struct wl_resource *r){ (void)c; wl_resource_destroy(r); }
static void subcompositor_get_subsurface(struct wl_client *c, struct wl_resource *r, uint32_t id,
                                         struct wl_resource *surface, struct wl_resource *parent)
{
  struct iosc_surface *s = wl_resource_get_user_data(surface);
  struct iosc_surface *p = wl_resource_get_user_data(parent);
  struct iosc_subsurface *sub = calloc(1, sizeof(*sub));
  if (!sub) { wl_client_post_no_memory(c); return; }
  struct wl_resource *ss = wl_resource_create(c, &wl_subsurface_interface, wl_resource_get_version(r), id);
  if (!ss) { free(sub); wl_client_post_no_memory(c); return; }
  sub->resource = ss; sub->surface = s; sub->parent = p;
  s->role = IOSC_ROLE_SUBSURFACE;
  s->parent = p;
  s->subsurface = sub;
  wl_resource_set_implementation(ss, &subsurface_impl, sub, subsurface_resource_destroy);
}
static const struct wl_subcompositor_interface subcompositor_impl = {
    .destroy = subcompositor_destroy, .get_subsurface = subcompositor_get_subsurface };
static void subcompositor_bind(struct wl_client *client, void *data, uint32_t version, uint32_t id)
{ (void)data;
  struct wl_resource *r = wl_resource_create(client, &wl_subcompositor_interface, version, id);
  if (!r) { wl_client_post_no_memory(client); return; }
  wl_resource_set_implementation(r, &subcompositor_impl, NULL, NULL); }

/* ---- clipboard / wl_data_device ------------------------------------------ */

#define IOSC_CLIP_SET 1u
#define IOSC_CLIP_MAX (1024u * 1024u)
#define IOSC_MAX_DATA_DEVICES 32
#define IOSC_MAX_CLIP_CLIENTS 4
#define IOSC_MAX_CLIP_MIMES 16   /* DnD sources offer many type variants */

struct iosc_clip_msg {
    uint32_t type;
    uint32_t len;
};

struct iosc_clip_client {
    int fd;
    struct wl_event_source *src;
    uint8_t hdr[sizeof(struct iosc_clip_msg)];
    int hdr_have;
    struct iosc_clip_msg msg;
    char *payload;
    uint32_t payload_have;
};

struct iosc_data_source {
    struct wl_resource *resource;
    char *mimes[IOSC_MAX_CLIP_MIMES];
    int nmimes;
    uint32_t actions;    /* dnd actions from wl_data_source.set_actions (v3) */
};

struct iosc_data_device {
    struct wl_resource *resource;
    struct wl_client *client;
};

struct iosc_mime_data {
    char *mime;
    char *data;
    size_t len;
};

struct iosc_data_offer {
    struct iosc_mime_data items[IOSC_MAX_CLIP_MIMES];
    int nitems;
};

struct iosc_source_read {
    int fd;
    struct wl_event_source *src;
    char *buf;
    size_t len;
    size_t cap;
    char *mime;
};

static struct iosc_clip_client *g_clip_clients[IOSC_MAX_CLIP_CLIENTS];
static struct iosc_data_device *g_data_devices[IOSC_MAX_DATA_DEVICES];
static int g_ndata_devices;
static struct iosc_mime_data g_clip_items[IOSC_MAX_CLIP_MIMES];
static int g_nclip_items;
static const struct wl_data_offer_interface data_offer_impl;
static void data_offer_resource_destroy(struct wl_resource *r);

static int is_text_mime(const char *mime)
{
    return mime && (!strcmp(mime, "text/plain") ||
                    !strcmp(mime, "text/plain;charset=utf-8") ||
                    !strcmp(mime, "UTF8_STRING") ||
                    !strncmp(mime, "text/plain;", 11));
}

static int is_clip_mime(const char *mime)
{
    return is_text_mime(mime) ||
           (mime && (!strcmp(mime, "text/uri-list") ||
                     !strcmp(mime, "text/html")));
}

static void mime_data_clear(struct iosc_mime_data *m)
{
    free(m->mime);
    free(m->data);
    memset(m, 0, sizeof(*m));
}

static void clip_clear_items(void)
{
    for (int i = 0; i < g_nclip_items; i++)
        mime_data_clear(&g_clip_items[i]);
    g_nclip_items = 0;
}

static struct iosc_mime_data *clip_find_exact_item(const char *mime)
{
    for (int i = 0; i < g_nclip_items; i++)
        if (g_clip_items[i].mime && mime && !strcmp(g_clip_items[i].mime, mime))
            return &g_clip_items[i];
    return NULL;
}

static struct iosc_mime_data *clip_find_item(const char *mime)
{
    struct iosc_mime_data *m = clip_find_exact_item(mime);
    if (m) return m;
    if (mime && is_text_mime(mime))
        for (int i = 0; i < g_nclip_items; i++)
            if (is_text_mime(g_clip_items[i].mime))
                return &g_clip_items[i];
    return NULL;
}

static int clip_item_set(const char *mime, const char *data, size_t len)
{
    if (!is_clip_mime(mime)) return -1;
    if (len > IOSC_CLIP_MAX) len = IOSC_CLIP_MAX;
    struct iosc_mime_data *m = clip_find_exact_item(mime);
    int added = 0;
    if (!m) {
        if (g_nclip_items >= IOSC_MAX_CLIP_MIMES) return -1;
        m = &g_clip_items[g_nclip_items++];
        added = 1;
        m->mime = strdup(mime);
        if (!m->mime) { g_nclip_items--; return -1; }
    } else {
        free(m->data);
        m->data = NULL;
        m->len = 0;
    }
    m->data = malloc(len + 1);
    if (!m->data) {
        if (added) {
            mime_data_clear(m);
            g_nclip_items--;
        }
        return -1;
    }
    if (len) memcpy(m->data, data, len);
    m->data[len] = 0;
    m->len = len;
    return 0;
}

static int write_all_fd(int fd, const void *buf, size_t len)
{
    const char *p = buf;
    size_t put = 0;
    while (put < len) {
        ssize_t w = write(fd, p + put, len - put);
        if (w > 0) { put += (size_t)w; continue; }
        if (w < 0 && errno == EINTR) continue;
        return -1;
    }
    return 0;
}

static void clip_client_drop(struct iosc_clip_client *c)
{
    if (!c) return;
    for (int i = 0; i < IOSC_MAX_CLIP_CLIENTS; i++)
        if (g_clip_clients[i] == c) g_clip_clients[i] = NULL;
    if (c->src) wl_event_source_remove(c->src);
    if (c->fd >= 0) close(c->fd);
    free(c->payload);
    free(c);
    fprintf(stderr, "iosc: clipboard client disconnected\n");
}

static int clip_send_set_to_client(struct iosc_clip_client *c, const char *text, size_t len)
{
    if (!c || c->fd < 0 || len > IOSC_CLIP_MAX) return -1;
    struct iosc_clip_msg h = { .type = IOSC_CLIP_SET, .len = (uint32_t)len };
    if (write_all_fd(c->fd, &h, sizeof(h)) != 0) return -1;
    if (len && write_all_fd(c->fd, text, len) != 0) return -1;
    return 0;
}

static void clip_send_set_to_app(const char *text, size_t len)
{
    for (int i = 0; i < IOSC_MAX_CLIP_CLIENTS; i++) {
        struct iosc_clip_client *c = g_clip_clients[i];
        if (c && clip_send_set_to_client(c, text, len) != 0) clip_client_drop(c);
    }
}

static void clipboard_selection_send_to_device(struct iosc_data_device *d)
{
    if (!d || !d->resource) return;
    if (g_nclip_items == 0) {
        wl_data_device_send_selection(d->resource, NULL);
        return;
    }
    struct wl_resource *offer = wl_resource_create(d->client, &wl_data_offer_interface,
                                                   wl_resource_get_version(d->resource), 0);
    struct iosc_data_offer *o = calloc(1, sizeof(*o));
    if (!offer || !o) {
        if (offer) wl_resource_destroy(offer);
        free(o);
        wl_client_post_no_memory(d->client);
        return;
    }
    wl_resource_set_implementation(offer, &data_offer_impl, o, data_offer_resource_destroy);
    for (int i = 0; i < g_nclip_items; i++) {
        struct iosc_mime_data *src = &g_clip_items[i];
        struct iosc_mime_data *dst = &o->items[o->nitems];
        dst->mime = strdup(src->mime);
        dst->data = malloc(src->len + 1);
        if (!dst->mime || !dst->data) {
            wl_resource_destroy(offer);
            wl_client_post_no_memory(d->client);
            return;
        }
        memcpy(dst->data, src->data, src->len);
        dst->data[src->len] = 0;
        dst->len = src->len;
        o->nitems++;
    }
    wl_data_device_send_data_offer(d->resource, offer);
    for (int i = 0; i < o->nitems; i++)
        wl_data_offer_send_offer(offer, o->items[i].mime);
    if (clip_find_exact_item("text/plain;charset=utf-8") && !clip_find_exact_item("text/plain"))
        wl_data_offer_send_offer(offer, "text/plain");
    wl_data_device_send_selection(d->resource, offer);
}

static void clipboard_selection_send_to_client(struct wl_client *client)
{
    if (!client) return;
    for (int i = 0; i < g_ndata_devices; i++)
        if (g_data_devices[i] && g_data_devices[i]->client == client)
            clipboard_selection_send_to_device(g_data_devices[i]);
}

static void clipboard_selection_broadcast(void)
{
    if (!g_kbd_focus) return;
    clipboard_selection_send_to_client(wl_resource_get_client(g_kbd_focus->resource));
}

static void clip_set_text(const char *text, size_t len, int send_to_app)
{
    if (len > IOSC_CLIP_MAX) len = IOSC_CLIP_MAX;
    clip_clear_items();
    if (clip_item_set("text/plain;charset=utf-8", text ? text : "", len) != 0) return;
    if (send_to_app) clip_send_set_to_app(text ? text : "", len);
    clipboard_selection_broadcast();
}

static void data_offer_accept(struct wl_client *c, struct wl_resource *r,
                              uint32_t serial, const char *mime_type)
{ (void)c; (void)r; (void)serial; (void)mime_type; }

static void data_offer_receive(struct wl_client *c, struct wl_resource *r,
                               const char *mime_type, int fd)
{ (void)c;
    struct iosc_data_offer *o = wl_resource_get_user_data(r);
    if (o) {
        struct iosc_mime_data *m = NULL;
        for (int i = 0; i < o->nitems; i++)
            if (o->items[i].mime && mime_type && !strcmp(o->items[i].mime, mime_type)) {
                m = &o->items[i];
                break;
            }
        if (!m && is_text_mime(mime_type))
            for (int i = 0; i < o->nitems; i++)
                if (is_text_mime(o->items[i].mime)) { m = &o->items[i]; break; }
        if (m && m->data) write_all_fd(fd, m->data, m->len);
    }
    close(fd);
}

static void data_offer_destroy_req(struct wl_client *c, struct wl_resource *r)
{ (void)c; wl_resource_destroy(r); }
static void data_offer_finish(struct wl_client *c, struct wl_resource *r)
{ (void)c; (void)r; }
static void data_offer_set_actions(struct wl_client *c, struct wl_resource *r, uint32_t dnd, uint32_t pref)
{ (void)c; (void)r; (void)dnd; (void)pref; }

static const struct wl_data_offer_interface data_offer_impl = {
    .accept = data_offer_accept,
    .receive = data_offer_receive,
    .destroy = data_offer_destroy_req,
    .finish = data_offer_finish,
    .set_actions = data_offer_set_actions,
};

static void data_offer_resource_destroy(struct wl_resource *r)
{
    struct iosc_data_offer *o = wl_resource_get_user_data(r);
    if (!o) return;
    for (int i = 0; i < o->nitems; i++)
        mime_data_clear(&o->items[i]);
    free(o);
}

static void data_source_offer(struct wl_client *c, struct wl_resource *r, const char *m)
{ (void)c;
    struct iosc_data_source *s = wl_resource_get_user_data(r);
    /* Store any mime (DnD carries arbitrary drag types); the clipboard bridge stays
     * gated by clip_item_set, so relaxing this only affects what DnD can offer. */
    if (!s || !m || s->nmimes >= IOSC_MAX_CLIP_MIMES) return;
    for (int i = 0; i < s->nmimes; i++)
        if (!strcmp(s->mimes[i], m)) return;
    char *copy = strdup(m);
    if (!copy) { wl_client_post_no_memory(c); return; }
    s->mimes[s->nmimes++] = copy;
}

static void data_source_destroy(struct wl_client *c, struct wl_resource *r)
{ (void)c; wl_resource_destroy(r); }
static void data_source_set_actions(struct wl_client *c, struct wl_resource *r, uint32_t a)
{ (void)c;
    struct iosc_data_source *s = wl_resource_get_user_data(r);
    if (s) s->actions = a;
}

static const struct wl_data_source_interface data_source_impl = {
    .offer = data_source_offer,
    .destroy = data_source_destroy,
    .set_actions = data_source_set_actions,
};

static void data_source_resource_destroy(struct wl_resource *r)
{
    struct iosc_data_source *s = wl_resource_get_user_data(r);
    if (!s) return;
    for (int i = 0; i < s->nmimes; i++)
        free(s->mimes[i]);
    free(s);
}

static void source_read_done(struct iosc_source_read *rd, int publish)
{
    if (publish && rd->mime && clip_item_set(rd->mime, rd->buf ? rd->buf : "", rd->len) == 0) {
        if (is_text_mime(rd->mime))
            clip_send_set_to_app(rd->buf ? rd->buf : "", rd->len);
        clipboard_selection_broadcast();
    }
    if (rd->src) wl_event_source_remove(rd->src);
    if (rd->fd >= 0) close(rd->fd);
    free(rd->mime);
    free(rd->buf);
    free(rd);
}

static int source_readable(int fd, uint32_t mask, void *data)
{
    struct iosc_source_read *rd = data;
    if (mask & (WL_EVENT_HANGUP | WL_EVENT_ERROR)) { source_read_done(rd, rd->len > 0); return 0; }
    for (;;) {
        char tmp[4096];
        ssize_t r = read(fd, tmp, sizeof(tmp));
        if (r > 0) {
            if (rd->len + (size_t)r > IOSC_CLIP_MAX) { source_read_done(rd, 0); return 0; }
            if (rd->len + (size_t)r + 1 > rd->cap) {
                size_t ncap = rd->cap ? rd->cap * 2 : 4096;
                while (ncap < rd->len + (size_t)r + 1) ncap *= 2;
                char *nb = realloc(rd->buf, ncap);
                if (!nb) { source_read_done(rd, 0); return 0; }
                rd->buf = nb;
                rd->cap = ncap;
            }
            memcpy(rd->buf + rd->len, tmp, (size_t)r);
            rd->len += (size_t)r;
            rd->buf[rd->len] = 0;
            continue;
        }
        if (r == 0) { source_read_done(rd, 1); return 0; }
        if (errno == EAGAIN || errno == EWOULDBLOCK) break;
        if (errno == EINTR) continue;
        source_read_done(rd, 0);
        return 0;
    }
    return 0;
}

/* ---- drag-and-drop (wl_data_device.start_drag) ----------------------------
 * Unlike the clipboard offers above (which snapshot the data in the compositor),
 * a DnD offer FORWARDS every request to the live drag source: accept -> target,
 * receive -> send (the pipe fd passes straight through, bytes never touch the
 * compositor), finish -> dnd_finished. The offer keeps its own source pointer +
 * destroy listener so a post-drop receive/finish still works after the grab (and
 * g_dnd) is long gone. */

struct iosc_dnd_offer {
    struct wl_resource *resource;
    struct wl_resource *source;        /* wl_data_source; NULL once the source dies */
    struct wl_listener  source_destroy;
    int dropped;                       /* drop was delivered through this offer */
    int finished;                      /* destination called wl_data_offer.finish */
};

static void dnd_offer_source_destroyed(struct wl_listener *l, void *data)
{ (void)data;
    struct iosc_dnd_offer *o = wl_container_of(l, o, source_destroy);
    o->source = NULL;   /* the signal's list dies with the resource; just unlink us */
}

/* v<3 sources never call set_actions; treat them as plain copy so v3
 * destinations still negotiate a non-none action. */
static uint32_t dnd_source_actions_of(struct wl_resource *src)
{
    struct iosc_data_source *s = src ? wl_resource_get_user_data(src) : NULL;
    uint32_t a = s ? s->actions : 0;
    return a ? a : WL_DATA_DEVICE_MANAGER_DND_ACTION_COPY;
}

static void dnd_offer_accept(struct wl_client *c, struct wl_resource *r,
                             uint32_t serial, const char *mime)
{ (void)c; (void)serial;
    struct iosc_dnd_offer *o = wl_resource_get_user_data(r);
    if (!o) return;
    if (o->source) wl_data_source_send_target(o->source, mime);
    if (g_dnd.active && g_dnd.offer == r) g_dnd.target_accepted = mime != NULL;
}

static void dnd_offer_receive(struct wl_client *c, struct wl_resource *r,
                              const char *mime, int fd)
{ (void)c;
    struct iosc_dnd_offer *o = wl_resource_get_user_data(r);
    if (o && o->source) wl_data_source_send_send(o->source, mime, fd);
    close(fd);   /* our copy; the source client got a dup through the wire */
}

static void dnd_offer_destroy_req(struct wl_client *c, struct wl_resource *r)
{ (void)c; wl_resource_destroy(r); }

static void dnd_offer_finish(struct wl_client *c, struct wl_resource *r)
{ (void)c;
    struct iosc_dnd_offer *o = wl_resource_get_user_data(r);
    if (!o || !o->dropped || o->finished) return;
    o->finished = 1;
    if (o->source && wl_resource_get_version(o->source) >= WL_DATA_SOURCE_DND_FINISHED_SINCE_VERSION)
        wl_data_source_send_dnd_finished(o->source);
    fprintf(stderr, "iosc: dnd finished\n");
}

static void dnd_offer_set_actions(struct wl_client *c, struct wl_resource *r,
                                  uint32_t actions, uint32_t preferred)
{ (void)c;
    struct iosc_dnd_offer *o = wl_resource_get_user_data(r);
    if (!o) return;
    uint32_t both = dnd_source_actions_of(o->source) & actions;
    uint32_t chosen = 0;
    if (preferred & both)                                      chosen = preferred;
    else if (both & WL_DATA_DEVICE_MANAGER_DND_ACTION_COPY)    chosen = WL_DATA_DEVICE_MANAGER_DND_ACTION_COPY;
    else if (both & WL_DATA_DEVICE_MANAGER_DND_ACTION_MOVE)    chosen = WL_DATA_DEVICE_MANAGER_DND_ACTION_MOVE;
    else if (both & WL_DATA_DEVICE_MANAGER_DND_ACTION_ASK)     chosen = WL_DATA_DEVICE_MANAGER_DND_ACTION_ASK;
    if (g_dnd.active && g_dnd.offer == r) g_dnd.action = chosen;
    if (wl_resource_get_version(r) >= WL_DATA_OFFER_ACTION_SINCE_VERSION)
        wl_data_offer_send_action(r, chosen);
    if (o->source && wl_resource_get_version(o->source) >= WL_DATA_SOURCE_ACTION_SINCE_VERSION)
        wl_data_source_send_action(o->source, chosen);
}

static const struct wl_data_offer_interface dnd_offer_impl = {
    .accept = dnd_offer_accept,
    .receive = dnd_offer_receive,
    .destroy = dnd_offer_destroy_req,
    .finish = dnd_offer_finish,
    .set_actions = dnd_offer_set_actions,
};

static void dnd_offer_resource_destroy(struct wl_resource *r)
{
    struct iosc_dnd_offer *o = wl_resource_get_user_data(r);
    if (!o) return;
    if (g_dnd.active && g_dnd.offer == r) { g_dnd.offer = NULL; g_dnd.target_accepted = 0; }
    if (o->source) {
        /* Destroying a v3 offer post-drop without finish rejects the drop. */
        if (o->dropped && !o->finished &&
            wl_resource_get_version(o->source) >= WL_DATA_SOURCE_DND_FINISHED_SINCE_VERSION)
            wl_data_source_send_cancelled(o->source);
        wl_list_remove(&o->source_destroy.link);
    }
    free(o);
}

static struct iosc_data_device *data_device_for_client(struct wl_client *c)
{
    for (int i = 0; i < g_ndata_devices; i++)
        if (g_data_devices[i] && g_data_devices[i]->client == c)
            return g_data_devices[i];
    return NULL;
}

static void dnd_focus_leave(void)
{
    if (g_dnd.focus) {
        struct iosc_data_device *d =
            data_device_for_client(wl_resource_get_client(g_dnd.focus->resource));
        if (d) wl_data_device_send_leave(d->resource);
    }
    if (g_dnd.source && g_dnd.action &&
        wl_resource_get_version(g_dnd.source) >= WL_DATA_SOURCE_ACTION_SINCE_VERSION)
        wl_data_source_send_action(g_dnd.source, WL_DATA_DEVICE_MANAGER_DND_ACTION_NONE);
    g_dnd.focus = NULL;
    g_dnd.offer = NULL;   /* the destination client owns + destroys the object */
    g_dnd.target_accepted = 0;
    g_dnd.action = 0;
}

static void dnd_focus_enter(struct iosc_surface *hit, int x, int y)
{
    struct wl_client *dc = wl_resource_get_client(hit->resource);
    struct iosc_data_device *d = data_device_for_client(dc);
    g_dnd.focus = hit;
    g_dnd.offer = NULL;
    g_dnd.target_accepted = 0;
    g_dnd.action = 0;
    if (!d) return;                        /* no data device: surface can't accept */
    struct wl_resource *offer = NULL;
    if (g_dnd.source) {
        struct iosc_data_source *s = wl_resource_get_user_data(g_dnd.source);
        struct iosc_dnd_offer *o = calloc(1, sizeof(*o));
        offer = wl_resource_create(dc, &wl_data_offer_interface,
                                   wl_resource_get_version(d->resource), 0);
        if (!offer || !o) { free(o); if (offer) wl_resource_destroy(offer); return; }
        o->resource = offer;
        o->source = g_dnd.source;
        o->source_destroy.notify = dnd_offer_source_destroyed;
        wl_resource_add_destroy_listener(g_dnd.source, &o->source_destroy);
        wl_resource_set_implementation(offer, &dnd_offer_impl, o, dnd_offer_resource_destroy);
        wl_data_device_send_data_offer(d->resource, offer);
        if (s)
            for (int i = 0; i < s->nmimes; i++)
                wl_data_offer_send_offer(offer, s->mimes[i]);
    }
    g_dnd.offer = offer;
    uint32_t serial = wl_display_next_serial(g_display);
    wl_data_device_send_enter(d->resource, serial, hit->resource,
                              wl_fixed_from_int(x - hit->dx),
                              wl_fixed_from_int(y - hit->dy), offer);
    if (offer && wl_resource_get_version(offer) >= WL_DATA_OFFER_SOURCE_ACTIONS_SINCE_VERSION)
        wl_data_offer_send_source_actions(offer, dnd_source_actions_of(g_dnd.source));
    fprintf(stderr, "iosc: dnd enter surface=%p offer=%p\n", (void *)hit, (void *)offer);
}

static void dnd_update_motion(int x, int y, uint32_t t)
{
    struct iosc_surface *hit = surface_at(x, y);
    /* A NULL-source drag is client-internal by spec: only the origin client's
     * surfaces see enter/leave/motion. */
    if (hit && !g_dnd.source &&
        wl_resource_get_client(hit->resource) != g_dnd.origin_client)
        hit = NULL;
    if (hit != g_dnd.focus) {
        dnd_focus_leave();
        if (hit) dnd_focus_enter(hit, x, y);
        return;
    }
    if (hit) {
        struct iosc_data_device *d =
            data_device_for_client(wl_resource_get_client(hit->resource));
        if (d) wl_data_device_send_motion(d->resource, t,
                                          wl_fixed_from_int(x - hit->dx),
                                          wl_fixed_from_int(y - hit->dy));
    }
}

static void dnd_drop(void)
{
    struct iosc_data_device *d = g_dnd.focus ?
        data_device_for_client(wl_resource_get_client(g_dnd.focus->resource)) : NULL;
    struct iosc_dnd_offer *o = g_dnd.offer ? wl_resource_get_user_data(g_dnd.offer) : NULL;
    /* A real drop needs a destination that accepted a mime and (for v3 offers) a
     * non-none negotiated action; a NULL-source drag just needs a destination.
     * Anything else cancels the source. */
    int v3 = g_dnd.offer &&
             wl_resource_get_version(g_dnd.offer) >= WL_DATA_OFFER_ACTION_SINCE_VERSION;
    int ok = d && (!g_dnd.source ||
                   (g_dnd.offer && g_dnd.target_accepted && (!v3 || g_dnd.action)));
    if (ok) {
        wl_data_device_send_drop(d->resource);
        if (o) o->dropped = 1;
        if (g_dnd.source &&
            wl_resource_get_version(g_dnd.source) >= WL_DATA_SOURCE_DND_DROP_PERFORMED_SINCE_VERSION)
            wl_data_source_send_dnd_drop_performed(g_dnd.source);
        fprintf(stderr, "iosc: dnd drop on %p action=%u\n",
                (void *)g_dnd.focus, g_dnd.action);
    } else {
        if (g_dnd.source) wl_data_source_send_cancelled(g_dnd.source);
        if (d) wl_data_device_send_leave(d->resource);
        fprintf(stderr, "iosc: dnd cancelled (accepted=%d action=%u)\n",
                g_dnd.target_accepted, g_dnd.action);
    }
    dnd_end();
}

static void dnd_end(void)
{
    if (!g_dnd.active) return;
    if (g_dnd.source) wl_list_remove(&g_dnd.source_destroy.link);
    memset(&g_dnd, 0, sizeof(g_dnd));
    /* Pointer focus was suppressed by the grab; the next motion re-enters (every
     * input burst leads with a motion, so a follow-up tap self-heals too). */
    g_ptr_focus = NULL;
    recomposite_all();   /* erase the drag icon */
}

static void dnd_source_destroyed(struct wl_listener *l, void *data)
{ (void)l; (void)data;
    /* The live drag's source died mid-drag: cancel. Clear source FIRST so
     * dnd_focus_leave/dnd_end neither message the dead resource nor unlink the
     * listener from a list that is being torn down. */
    g_dnd.source = NULL;
    dnd_focus_leave();
    dnd_end();
    fprintf(stderr, "iosc: dnd source died; drag cancelled\n");
}

static void data_device_start_drag(struct wl_client *c, struct wl_resource *r, struct wl_resource *src,
                                   struct wl_resource *org, struct wl_resource *icon, uint32_t serial)
{
    struct iosc_surface *origin = org ? wl_resource_get_user_data(org) : NULL;
    if (!origin || g_dnd.active) return;
    if (!g_button_down || serial != g_button_serial) {
        fprintf(stderr, "iosc: start_drag ignored (stale serial %u)\n", serial);
        return;
    }
    struct iosc_surface *ic = NULL;
    if (icon) {
        ic = wl_resource_get_user_data(icon);
        if (ic && ic->role != IOSC_ROLE_NONE) {
            wl_resource_post_error(r, WL_DATA_DEVICE_ERROR_ROLE,
                                   "drag icon surface already has a role");
            return;
        }
    }
    memset(&g_dnd, 0, sizeof(g_dnd));
    g_dnd.active = 1;
    g_dnd.source = src;
    g_dnd.origin = origin;
    g_dnd.origin_client = c;
    g_dnd.icon = ic;
    if (src) {
        g_dnd.source_destroy.notify = dnd_source_destroyed;
        wl_resource_add_destroy_listener(src, &g_dnd.source_destroy);
    }
    /* The implicit grab takes the pointer away from its focus for the duration
     * of the drag; wl_data_device events replace wl_pointer ones. */
    if (g_ptr_focus) {
        struct wl_client *oc = wl_resource_get_client(g_ptr_focus->resource);
        uint32_t ls = wl_display_next_serial(g_display);
        for (int i = 0; i < g_nptr; i++)
            if (wl_resource_get_client(g_ptr[i]) == oc)
                wl_pointer_send_leave(g_ptr[i], ls, g_ptr_focus->resource);
        pointer_frame_client(oc);
        g_ptr_focus = NULL;
    }
    fprintf(stderr, "iosc: drag started (source=%p icon=%p origin=%p)\n",
            (void *)src, (void *)ic, (void *)origin);
    dnd_update_motion(g_cursor_x, g_cursor_y, now_ms());
    recomposite_all();   /* show the drag icon (if it has a buffer already) */
}

static void data_device_set_selection(struct wl_client *c, struct wl_resource *r,
                                      struct wl_resource *src, uint32_t serial)
{ (void)c; (void)r; (void)serial;
    if (!src) { clip_set_text("", 0, 1); return; }
    struct iosc_data_source *s = wl_resource_get_user_data(src);
    if (!s || s->nmimes == 0) return;
    clip_clear_items();
    for (int i = 0; i < s->nmimes; i++) {
        int fds[2];
        if (pipe(fds) != 0) continue;
        fcntl(fds[0], F_SETFL, fcntl(fds[0], F_GETFL, 0) | O_NONBLOCK);
        struct iosc_source_read *rd = calloc(1, sizeof(*rd));
        if (!rd) { close(fds[0]); close(fds[1]); continue; }
        rd->fd = fds[0];
        rd->mime = strdup(s->mimes[i]);
        if (!rd->mime) { close(fds[0]); close(fds[1]); free(rd); continue; }
        rd->src = wl_event_loop_add_fd(wl_display_get_event_loop(g_display), fds[0],
                                       WL_EVENT_READABLE, source_readable, rd);
        wl_data_source_send_send(src, s->mimes[i], fds[1]);
        close(fds[1]);
    }
}

static void data_device_release(struct wl_client *c, struct wl_resource *r)
{ (void)c; wl_resource_destroy(r); }

static const struct wl_data_device_interface data_device_impl = {
    .start_drag = data_device_start_drag,
    .set_selection = data_device_set_selection,
    .release = data_device_release,
};

static void data_device_resource_destroy(struct wl_resource *r)
{
    struct iosc_data_device *d = wl_resource_get_user_data(r);
    if (!d) return;
    for (int i = 0; i < g_ndata_devices; i++) {
        if (g_data_devices[i] == d) {
            g_data_devices[i] = g_data_devices[--g_ndata_devices];
            break;
        }
    }
    free(d);
}

static void ddm_create_data_source(struct wl_client *c, struct wl_resource *r, uint32_t id)
{
    struct iosc_data_source *s = calloc(1, sizeof(*s));
    if (!s) { wl_client_post_no_memory(c); return; }
    s->resource = wl_resource_create(c, &wl_data_source_interface, wl_resource_get_version(r), id);
    if (!s->resource) { free(s); wl_client_post_no_memory(c); return; }
    wl_resource_set_implementation(s->resource, &data_source_impl, s, data_source_resource_destroy);
}

static void ddm_get_data_device(struct wl_client *c, struct wl_resource *r, uint32_t id, struct wl_resource *seat)
{ (void)seat;
    if (g_ndata_devices >= IOSC_MAX_DATA_DEVICES) { wl_client_post_no_memory(c); return; }
    struct iosc_data_device *d = calloc(1, sizeof(*d));
    if (!d) { wl_client_post_no_memory(c); return; }
    d->client = c;
    d->resource = wl_resource_create(c, &wl_data_device_interface, wl_resource_get_version(r), id);
    if (!d->resource) { free(d); wl_client_post_no_memory(c); return; }
    wl_resource_set_implementation(d->resource, &data_device_impl, d, data_device_resource_destroy);
    g_data_devices[g_ndata_devices++] = d;
    if (g_kbd_focus && wl_resource_get_client(g_kbd_focus->resource) == c)
        clipboard_selection_send_to_device(d);
}

static const struct wl_data_device_manager_interface ddm_impl = {
    .create_data_source = ddm_create_data_source,
    .get_data_device = ddm_get_data_device,
};

static void ddm_bind(struct wl_client *client, void *data, uint32_t version, uint32_t id)
{ (void)data;
  struct wl_resource *r = wl_resource_create(client, &wl_data_device_manager_interface, version, id);
  if (!r) { wl_client_post_no_memory(client); return; }
  wl_resource_set_implementation(r, &ddm_impl, NULL, NULL); }

static void clip_rx_reset(struct iosc_clip_client *c)
{
    free(c->payload);
    c->payload = NULL;
    c->payload_have = 0;
    c->hdr_have = 0;
    memset(&c->msg, 0, sizeof(c->msg));
}

static int clip_client_readable(int fd, uint32_t mask, void *data)
{
    struct iosc_clip_client *c = data;
    if (mask & (WL_EVENT_HANGUP | WL_EVENT_ERROR)) goto drop;
    for (;;) {
        if (c->hdr_have < (int)sizeof(c->hdr)) {
            ssize_t r = read(fd, c->hdr + c->hdr_have, sizeof(c->hdr) - (size_t)c->hdr_have);
            if (r > 0) {
                c->hdr_have += (int)r;
                if (c->hdr_have < (int)sizeof(c->hdr)) continue;
                memcpy(&c->msg, c->hdr, sizeof(c->msg));
                if (c->msg.len > IOSC_CLIP_MAX) goto drop;
                c->payload = c->msg.len ? calloc(1, c->msg.len + 1u) : NULL;
                if (c->msg.len && !c->payload) goto drop;
            } else {
                if (r == 0) goto drop;
                if (errno == EAGAIN || errno == EWOULDBLOCK) break;
                if (errno == EINTR) continue;
                goto drop;
            }
        }
        while (c->payload_have < c->msg.len) {
            ssize_t r = read(fd, c->payload + c->payload_have, c->msg.len - c->payload_have);
            if (r > 0) { c->payload_have += (uint32_t)r; continue; }
            if (r == 0) goto drop;
            if (errno == EAGAIN || errno == EWOULDBLOCK) return 0;
            if (errno == EINTR) continue;
            goto drop;
        }
        if (c->msg.type == IOSC_CLIP_SET)
            clip_set_text(c->payload ? c->payload : "", c->msg.len, 0);
        clip_rx_reset(c);
    }
    return 0;
drop:
    clip_client_drop(c);
    return 0;
}

static int clip_listen_readable(int fd, uint32_t mask, void *data)
{
    (void)mask;
    struct wl_event_loop *loop = data;
    int cfd = accept(fd, NULL, NULL);
    if (cfd < 0) return 0;
    fcntl(cfd, F_SETFL, fcntl(cfd, F_GETFL, 0) | O_NONBLOCK);
    struct iosc_clip_client *c = calloc(1, sizeof(*c));
    if (!c) { close(cfd); return 0; }
    c->fd = cfd;
    c->src = wl_event_loop_add_fd(loop, cfd, WL_EVENT_READABLE, clip_client_readable, c);
    int slot = -1;
    for (int i = 0; i < IOSC_MAX_CLIP_CLIENTS; i++) if (!g_clip_clients[i]) { slot = i; break; }
    if (slot < 0) { clip_client_drop(c); return 0; }
    g_clip_clients[slot] = c;
    struct iosc_mime_data *text = clip_find_item("text/plain;charset=utf-8");
    if (text) clip_send_set_to_client(c, text->data ? text->data : "", text->len);
    fprintf(stderr, "iosc: clipboard client connected (fd=%d)\n", cfd);
    return 0;
}

/* Create a listening AF_UNIX stream socket at `path` and register its accept
 * handler on the event loop. Shared by the clipboard + input bridges; the Xios
 * app runs as mobile and must connect, so the socket is world-accessible. */
static int unix_listen_start(struct wl_event_loop *loop, const char *path,
                             int (*on_accept)(int, uint32_t, void *))
{
    unlink(path);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    struct sockaddr_un addr; memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, path, sizeof(addr.sun_path) - 1);
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) { close(fd); return -1; }
    if (listen(fd, 4) < 0) { close(fd); return -1; }
    chmod(path, 0777);
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK);
    wl_event_loop_add_fd(loop, fd, WL_EVENT_READABLE, on_accept, loop);
    return 0;
}

static int clipboard_socket_start(struct wl_event_loop *loop, const char *path)
{
    return unix_listen_start(loop, path, clip_listen_readable);
}

/* ---- input transport: a tiny AF_UNIX socket the Xios app writes events to ---
 * The app forwards UIKit touch + the iOS keyboard as fixed 24-byte messages. The
 * listen + client fds live on the wl_display event loop, so every wl_* dispatch
 * driven by input runs on the compositor's own thread (no locking needed). */

/* iosc consumes the SHARED reader (xios_input_socket.c, also linked by
 * MetaBackendIOS) so there is ONE framing state machine, not two that can drift.
 * The shared reader multiplexes the listen + client sockets onto a single kqueue
 * fd; iosc registers that fd on the wl_display event loop and drains complete
 * records through a callback into the same handle_* paths as before. The wire
 * types (XIOS_IN_*) + struct xios_in_msg live in xios_input_socket.h. */
static xios_input_socket *g_input_sock;
static struct wl_event_source *g_input_src;

/* Commit a UTF-8 TEXT record: prefer the focused text-input; else synthesize
 * ASCII keystrokes so a plain terminal still receives typed text. */
static void in_dispatch_text(const char *text, size_t len)
{
    int r = text_input_commit_text(text, len);
    if (r == 0) {
        for (size_t i = 0; i < len; i++) {
            unsigned char c = (unsigned char)text[i];
            if (c < 0x80)
                handle_key(c == '\n' ? 0xff0d : (uint32_t)c, 0);
        }
    }
    wl_display_flush_clients(g_display);
}

/* One complete input record from the shared reader -> the compositor's handlers.
 * Runs on the compositor thread (the reader's kqueue fd is on the wl event loop),
 * so no locking. Same routing the inline reader did; unknown types are ignored. */
static void iosc_input_record(const struct xios_in_msg *m, const char *text,
                              size_t text_len, void *user)
{
    (void)user;
    if (m->type == XIOS_IN_TEXT) { in_dispatch_text(text, text_len); return; }
    int x = physical_to_logical(m->x);
    int y = physical_to_logical(m->y);
    switch (m->type) {
        case XIOS_IN_MOTION: handle_motion(x, y); break;
        case XIOS_IN_BUTTON: handle_motion(x, y);
                             handle_button((int)m->code, (int)m->state); break;
        case XIOS_IN_KEY:    handle_key(m->code, m->mods); break;
        case XIOS_IN_TOUCH:  handle_touch((int)m->code, (int)m->state, x, y); break;
        case XIOS_IN_TABLET: handle_pencil((int)m->state, x, y, m->code,
                                           (int)(m->mods & 0xffu) - 90,
                                           (int)((m->mods >> 8) & 0xffu) - 90); break;
    }
    wl_display_flush_clients(g_display);   /* push the events out immediately */
}

/* Push the current on-screen-keyboard traits to every connected app client. The
 * shared reader owns the client fds, so this goes through its broadcast path. */
static void input_clients_send_traits(void)
{
    struct iosc_text_input *ti = text_input_for_focus();
    struct xios_in_msg msg = {
        .type = XIOS_IN_TRAITS,
        .code = ti ? ti->content_hint : 0,
        .state = ti ? ti->content_purpose : 0,
        .mods = ti ? (uint32_t)ti->enabled : 0,
    };
    xios_input_socket_broadcast(g_input_sock, &msg, sizeof(msg));
}

/* The shared reader's kqueue fd became readable (a new connection or client
 * data): drain every complete record. The reader accepts internally, so we can't
 * hook accept directly; instead re-send the initial traits whenever the connected
 * count grows (a new client), matching the inline reader's send-on-connect. */
static int g_input_nclients;
static int input_sock_readable(int fd, uint32_t mask, void *data)
{
    (void)fd; (void)mask; (void)data;
    xios_input_socket_dispatch(g_input_sock, iosc_input_record, NULL);
    int now = xios_input_socket_client_count(g_input_sock);
    if (now > g_input_nclients) input_clients_send_traits();
    g_input_nclients = now;
    return 0;
}

static int input_socket_start(struct wl_event_loop *loop, const char *path)
{
    g_input_sock = xios_input_socket_new(path);
    if (!g_input_sock) return -1;
    g_input_src = wl_event_loop_add_fd(loop, xios_input_socket_fd(g_input_sock),
                                       WL_EVENT_READABLE, input_sock_readable, NULL);
    if (!g_input_src) { xios_input_socket_free(g_input_sock); g_input_sock = NULL; return -1; }
    return 0;
}

/* Write the xkb keymap to an fd the wl_keyboard clients mmap (no memfd on iOS;
 * an unlinked tmp file in XDG_RUNTIME_DIR works the same). */
static int make_keymap_fd(void)
{
    const char *str = iosc_input_keymap_string();
    uint32_t size = iosc_input_keymap_size();
    if (!str || size == 0) return -1;
    const char *dir = getenv("XDG_RUNTIME_DIR"); if (!dir) dir = "/var/jb/tmp";
    char tmpl[256]; snprintf(tmpl, sizeof(tmpl), "%s/iosc-keymap-XXXXXX", dir);
    int fd = mkstemp(tmpl);
    if (fd < 0) return -1;
    unlink(tmpl);
    if (write(fd, str, size) != (ssize_t)size) { close(fd); return -1; }
    return fd;
}

/* ---- zwlr_foreign_toplevel_management_v1 --------------------------------- */
/* The window list as a protocol: a taskbar/overview binds the manager, receives
 * one handle per open toplevel (title/app_id/state), and can activate or close
 * them. State broadcasts hook the existing map/focus/maximize paths above. */

#define IOSC_MAX_FTL_MANAGERS 8
static struct wl_resource *g_ftl_managers[IOSC_MAX_FTL_MANAGERS];
static int g_nftl_managers;
static void ftl_handle_res_destroy(struct wl_resource *r);

/* Build the wl_array of zwlr_foreign_toplevel_handle_v1 state enums. */
static void ftl_state_array(struct iosc_surface *s, struct wl_array *a)
{
    wl_array_init(a);
    uint32_t *e;
    if (s->toplevel_maximized) {
        e = wl_array_add(a, sizeof(uint32_t));
        if (e) *e = ZWLR_FOREIGN_TOPLEVEL_HANDLE_V1_STATE_MAXIMIZED;
    }
    if (s->toplevel_minimized) {
        e = wl_array_add(a, sizeof(uint32_t));
        if (e) *e = ZWLR_FOREIGN_TOPLEVEL_HANDLE_V1_STATE_MINIMIZED;
    }
    if (s == g_kbd_focus) {
        e = wl_array_add(a, sizeof(uint32_t));
        if (e) *e = ZWLR_FOREIGN_TOPLEVEL_HANDLE_V1_STATE_ACTIVATED;
    }
    if (s->toplevel_fullscreen) {
        e = wl_array_add(a, sizeof(uint32_t));
        if (e) *e = ZWLR_FOREIGN_TOPLEVEL_HANDLE_V1_STATE_FULLSCREEN;
    }
}

static void ftl_handle_send_state(struct wl_resource *h, struct iosc_surface *s)
{
    struct wl_array a;
    ftl_state_array(s, &a);
    zwlr_foreign_toplevel_handle_v1_send_state(h, &a);
    wl_array_release(&a);
}

/* Initial dump for a freshly created handle: title, app_id, state, done. */
static void ftl_handle_send_initial(struct wl_resource *h, struct iosc_surface *s)
{
    zwlr_foreign_toplevel_handle_v1_send_title(h, s->title[0] ? s->title : "");
    zwlr_foreign_toplevel_handle_v1_send_app_id(h, s->app_id[0] ? s->app_id : "");
    ftl_handle_send_state(h, s);
    zwlr_foreign_toplevel_handle_v1_send_done(h);
}

static const struct zwlr_foreign_toplevel_handle_v1_interface ftl_handle_impl;

/* Create a handle for surface `s` on manager `m`, register it, dump initial state. */
static struct wl_resource *ftl_new_handle(struct wl_resource *m, struct iosc_surface *s)
{
    if (s->ftl_nhandles >= (int)(sizeof(s->ftl_handles) / sizeof(s->ftl_handles[0])))
        return NULL;
    struct wl_client *c = wl_resource_get_client(m);
    struct wl_resource *h = wl_resource_create(
        c, &zwlr_foreign_toplevel_handle_v1_interface, wl_resource_get_version(m), 0);
    if (!h) return NULL;
    wl_resource_set_implementation(h, &ftl_handle_impl, s, ftl_handle_res_destroy);
    s->ftl_handles[s->ftl_nhandles++] = h;
    zwlr_foreign_toplevel_manager_v1_send_toplevel(m, h);
    ftl_handle_send_initial(h, s);
    return h;
}

static void ftl_toplevel_mapped(struct iosc_surface *s)
{
    if (s->role != IOSC_ROLE_TOPLEVEL) return;
    for (int i = 0; i < g_nftl_managers; i++)
        ftl_new_handle(g_ftl_managers[i], s);
}

static void ftl_toplevel_closed(struct iosc_surface *s)
{
    for (int i = 0; i < s->ftl_nhandles; i++) {
        zwlr_foreign_toplevel_handle_v1_send_closed(s->ftl_handles[i]);
        wl_resource_set_user_data(s->ftl_handles[i], NULL);   /* handle goes inert */
    }
    s->ftl_nhandles = 0;
}

static void ftl_broadcast_state(struct iosc_surface *s)
{
    if (!s) return;
    for (int i = 0; i < s->ftl_nhandles; i++) {
        ftl_handle_send_state(s->ftl_handles[i], s);
        zwlr_foreign_toplevel_handle_v1_send_done(s->ftl_handles[i]);
    }
}

static void ftl_broadcast_title(struct iosc_surface *s)
{
    if (!s) return;
    for (int i = 0; i < s->ftl_nhandles; i++) {
        zwlr_foreign_toplevel_handle_v1_send_title(s->ftl_handles[i], s->title);
        zwlr_foreign_toplevel_handle_v1_send_done(s->ftl_handles[i]);
    }
}

static void ftl_broadcast_app_id(struct iosc_surface *s)
{
    if (!s) return;
    for (int i = 0; i < s->ftl_nhandles; i++) {
        zwlr_foreign_toplevel_handle_v1_send_app_id(s->ftl_handles[i], s->app_id);
        zwlr_foreign_toplevel_handle_v1_send_done(s->ftl_handles[i]);
    }
}

/* Handle requests. After `closed`, user_data is NULL and requests are ignored. */
static void ftl_handle_res_destroy(struct wl_resource *r)
{
    struct iosc_surface *s = wl_resource_get_user_data(r);
    if (s) reslist_remove(s->ftl_handles, &s->ftl_nhandles, r);
}

static void ftlh_set_maximized(struct wl_client *c, struct wl_resource *h)
{ (void)c; struct iosc_surface *s = wl_resource_get_user_data(h);
  if (s) { s->toplevel_maximized = 1; toplevel_reconfigure_state(s); ftl_broadcast_state(s); } }
static void ftlh_unset_maximized(struct wl_client *c, struct wl_resource *h)
{ (void)c; struct iosc_surface *s = wl_resource_get_user_data(h);
  if (s) { s->toplevel_maximized = 0; toplevel_reconfigure_state(s); ftl_broadcast_state(s); } }
static void ftlh_set_minimized(struct wl_client *c, struct wl_resource *h)
{ (void)c; struct iosc_surface *s = wl_resource_get_user_data(h);
  if (s) { s->toplevel_minimized = 1; ftl_broadcast_state(s); } }   /* flag only; no hide yet */
static void ftlh_unset_minimized(struct wl_client *c, struct wl_resource *h)
{ (void)c; struct iosc_surface *s = wl_resource_get_user_data(h);
  if (s) { s->toplevel_minimized = 0; ftl_broadcast_state(s); } }
static void ftlh_activate(struct wl_client *c, struct wl_resource *h, struct wl_resource *seat)
{ (void)c; (void)seat; struct iosc_surface *s = wl_resource_get_user_data(h);
  if (s) { surface_raise(s); keyboard_set_focus(s); recomposite_all(); } }
static void ftlh_close(struct wl_client *c, struct wl_resource *h)
{ (void)c; struct iosc_surface *s = wl_resource_get_user_data(h);
  if (s && s->xdg_toplevel) xdg_toplevel_send_close(s->xdg_toplevel); }
static void ftlh_set_rectangle(struct wl_client *c, struct wl_resource *h, struct wl_resource *surf,
                               int32_t x, int32_t y, int32_t w, int32_t ht)
{ (void)c; (void)h; (void)surf; (void)x; (void)y; (void)w; (void)ht; /* minimize hint; unused */ }
static void ftlh_destroy(struct wl_client *c, struct wl_resource *h)
{ (void)c; wl_resource_destroy(h); }
static void ftlh_set_fullscreen(struct wl_client *c, struct wl_resource *h, struct wl_resource *out)
{ (void)c; (void)out; struct iosc_surface *s = wl_resource_get_user_data(h);
  if (s) { s->toplevel_fullscreen = 1; toplevel_reconfigure_state(s); ftl_broadcast_state(s); } }
static void ftlh_unset_fullscreen(struct wl_client *c, struct wl_resource *h)
{ (void)c; struct iosc_surface *s = wl_resource_get_user_data(h);
  if (s) { s->toplevel_fullscreen = 0; toplevel_reconfigure_state(s); ftl_broadcast_state(s); } }

static const struct zwlr_foreign_toplevel_handle_v1_interface ftl_handle_impl = {
    .set_maximized   = ftlh_set_maximized,
    .unset_maximized = ftlh_unset_maximized,
    .set_minimized   = ftlh_set_minimized,
    .unset_minimized = ftlh_unset_minimized,
    .activate        = ftlh_activate,
    .close           = ftlh_close,
    .set_rectangle   = ftlh_set_rectangle,
    .destroy         = ftlh_destroy,
    .set_fullscreen  = ftlh_set_fullscreen,
    .unset_fullscreen = ftlh_unset_fullscreen,
};

static void ftl_manager_stop(struct wl_client *c, struct wl_resource *m)
{ (void)c; zwlr_foreign_toplevel_manager_v1_send_finished(m); wl_resource_destroy(m); }

static const struct zwlr_foreign_toplevel_manager_v1_interface ftl_manager_impl = {
    .stop = ftl_manager_stop,
};

static void ftl_manager_res_destroy(struct wl_resource *m)
{ reslist_remove(g_ftl_managers, &g_nftl_managers, m); }

static void ftl_manager_bind(struct wl_client *client, void *data,
                             uint32_t version, uint32_t id)
{
    (void)data;
    struct wl_resource *m = wl_resource_create(
        client, &zwlr_foreign_toplevel_manager_v1_interface, version, id);
    if (!m) { wl_client_post_no_memory(client); return; }
    wl_resource_set_implementation(m, &ftl_manager_impl, NULL, ftl_manager_res_destroy);
    if (g_nftl_managers < IOSC_MAX_FTL_MANAGERS)
        g_ftl_managers[g_nftl_managers++] = m;
    int n = 0;
    for (int i = 0; i < g_nmapped; i++)      /* replay current window list */
        if (g_mapped[i]->role == IOSC_ROLE_TOPLEVEL) { ftl_new_handle(m, g_mapped[i]); n++; }
    fprintf(stderr, "iosc: client bound zwlr_foreign_toplevel_manager_v1 v%u (%d open toplevel(s))\n",
            version, n);
}

/* ---- zwlr_layer_shell_v1 / zwlr_layer_surface_v1 ------------------------- */
/* Desktop-shell surfaces: anchored, z-banded panels/overviews. State is stored
 * on struct iosc_layer_state and applied via the commit-driven placement above
 * (surface_map / surface_commit / work_area_*). This block is only the protocol
 * plumbing; the stacking/placement/input logic lives with the core WM code. */

static void layer_surface_set_size(struct wl_client *c, struct wl_resource *r,
                                   uint32_t w, uint32_t h)
{ (void)c; struct iosc_surface *s = wl_resource_get_user_data(r);
  if (s && s->layer) { s->layer->req_w = (int)w; s->layer->req_h = (int)h; } }

static void layer_surface_set_anchor(struct wl_client *c, struct wl_resource *r, uint32_t anchor)
{ (void)c; struct iosc_surface *s = wl_resource_get_user_data(r);
  if (s && s->layer) s->layer->anchor = anchor; }

static void layer_surface_set_exclusive_zone(struct wl_client *c, struct wl_resource *r, int32_t zone)
{ (void)c; struct iosc_surface *s = wl_resource_get_user_data(r);
  if (s && s->layer) { s->layer->excl_zone = zone; if (s->mapped) work_area_recompute(); } }

static void layer_surface_set_margin(struct wl_client *c, struct wl_resource *r,
                                     int32_t t, int32_t rr, int32_t b, int32_t l)
{ (void)c; struct iosc_surface *s = wl_resource_get_user_data(r);
  if (s && s->layer) { s->layer->margin_t = t; s->layer->margin_r = rr;
                       s->layer->margin_b = b; s->layer->margin_l = l; } }

static void layer_surface_set_kbd(struct wl_client *c, struct wl_resource *r, uint32_t ki)
{ (void)c; struct iosc_surface *s = wl_resource_get_user_data(r);
  if (s && s->layer) s->layer->kbd_interactivity = ki; }

static void layer_surface_get_popup(struct wl_client *c, struct wl_resource *r,
                                    struct wl_resource *popup)
{ (void)c; (void)r; (void)popup; /* xdg_popup already maps standalone; no link needed for the panel */ }

static void layer_surface_ack_configure(struct wl_client *c, struct wl_resource *r, uint32_t serial)
{ (void)c; (void)serial; struct iosc_surface *s = wl_resource_get_user_data(r);
  if (s && s->layer) s->layer->acked = 1; }

static void layer_surface_destroy(struct wl_client *c, struct wl_resource *r)
{ (void)c; wl_resource_destroy(r); }

static void layer_surface_set_layer(struct wl_client *c, struct wl_resource *r, uint32_t layer)
{ (void)c; struct iosc_surface *s = wl_resource_get_user_data(r);
  if (s && s->layer) s->layer->layer = layer; }

static void layer_surface_set_exclusive_edge(struct wl_client *c, struct wl_resource *r, uint32_t edge)
{ (void)c; (void)r; (void)edge; /* v5 request; we advertise v4 so it is never dispatched */ }

static const struct zwlr_layer_surface_v1_interface layer_surface_impl = {
    .set_size                   = layer_surface_set_size,
    .set_anchor                 = layer_surface_set_anchor,
    .set_exclusive_zone         = layer_surface_set_exclusive_zone,
    .set_margin                 = layer_surface_set_margin,
    .set_keyboard_interactivity = layer_surface_set_kbd,
    .get_popup                  = layer_surface_get_popup,
    .ack_configure              = layer_surface_ack_configure,
    .destroy                    = layer_surface_destroy,
    .set_layer                  = layer_surface_set_layer,
    .set_exclusive_edge         = layer_surface_set_exclusive_edge,
};

/* zwlr_layer_surface_v1 resource gone (client destroyed it or disconnected):
 * detach the role. (If the wl_surface went first, its destructor already nulled
 * our user_data and freed the layer state, so this no-ops.) */
static void layer_surface_res_destroy(struct wl_resource *r)
{
    struct iosc_surface *s = wl_resource_get_user_data(r);
    if (!s || !s->layer) return;
    int was_mapped = s->mapped;
    surface_unmap(s);
    free(s->layer);
    s->layer = NULL;
    s->role = IOSC_ROLE_NONE;
    work_area_recompute();
    if (was_mapped) recomposite_all();
}

static void layer_shell_get_layer_surface(struct wl_client *c, struct wl_resource *r,
        uint32_t id, struct wl_resource *surface, struct wl_resource *output,
        uint32_t layer, const char *namespace)
{
    (void)output;   /* single output; the compositor always picks it */
    struct iosc_surface *s = wl_resource_get_user_data(surface);
    if (!s) { wl_client_post_no_memory(c); return; }
    if (s->role != IOSC_ROLE_NONE) {
        wl_resource_post_error(r, ZWLR_LAYER_SHELL_V1_ERROR_ROLE,
                               "wl_surface already has a role");
        return;
    }
    if (s->current_buffer || s->pending_buffer) {
        wl_resource_post_error(r, ZWLR_LAYER_SHELL_V1_ERROR_ALREADY_CONSTRUCTED,
                               "wl_surface already has a buffer attached");
        return;
    }
    if (layer > ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY) {
        wl_resource_post_error(r, ZWLR_LAYER_SHELL_V1_ERROR_INVALID_LAYER,
                               "invalid layer %u", layer);
        return;
    }
    struct iosc_layer_state *L = calloc(1, sizeof(*L));
    if (!L) { wl_client_post_no_memory(c); return; }
    L->layer = layer;
    L->kbd_interactivity = ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_NONE;
    if (namespace)
        snprintf(L->namespace, sizeof(L->namespace), "%s", namespace);

    struct wl_resource *ls = wl_resource_create(c, &zwlr_layer_surface_v1_interface,
                                                wl_resource_get_version(r), id);
    if (!ls) { free(L); wl_client_post_no_memory(c); return; }
    L->resource = ls;
    s->role  = IOSC_ROLE_LAYER;
    s->layer = L;
    wl_resource_set_implementation(ls, &layer_surface_impl, s, layer_surface_res_destroy);
    fprintf(stderr, "iosc: layer_surface created ns=\"%s\" layer=%u\n", L->namespace, layer);
}

static void layer_shell_destroy(struct wl_client *c, struct wl_resource *r)
{ (void)c; wl_resource_destroy(r); }

static const struct zwlr_layer_shell_v1_interface layer_shell_impl = {
    .get_layer_surface = layer_shell_get_layer_surface,
    .destroy           = layer_shell_destroy,
};

static void layer_shell_bind(struct wl_client *client, void *data,
                             uint32_t version, uint32_t id)
{
    (void)data;
    struct wl_resource *r = wl_resource_create(client, &zwlr_layer_shell_v1_interface,
                                               version, id);
    if (!r) { wl_client_post_no_memory(client); return; }
    wl_resource_set_implementation(r, &layer_shell_impl, NULL, NULL);
    fprintf(stderr, "iosc: client bound zwlr_layer_shell_v1 v%u\n", version);
}

/* ---- wm control socket (/var/jb/tmp/iosc-wm.sock) ------------------------ */
/* A tiny line protocol so a NON-Wayland client (ioscd, the panel) can raise an
 * existing window by app_id without becoming a wl client: `raise\t<app_id>\n` ->
 * surface_raise + keyboard_set_focus, reply "ok\n" / "notfound\n". This is the
 * "second-tap raises the live window" hook (docs/iosc-desktop-env.md §7); it just
 * drives the same raise+focus the xdg-activation path does, keyed by the app_id
 * we already store on the surface. Graceful-degrades: absent, the window is still
 * mapped, it just may not restack to the top. */

#define IOSC_MAX_WM_CLIENTS 8
#define IOSC_WM_BUF 256
struct iosc_wm_client { int fd; struct wl_event_source *src; char buf[IOSC_WM_BUF]; int have; };
static struct iosc_wm_client *g_wm_clients[IOSC_MAX_WM_CLIENTS];

static struct iosc_surface *wm_find_toplevel_by_app_id(const char *app_id)
{
    if (!app_id || !*app_id) return NULL;
    for (int i = g_nmapped - 1; i >= 0; i--) {   /* top-most match wins */
        struct iosc_surface *s = g_mapped[i];
        if (s->role == IOSC_ROLE_TOPLEVEL && s->app_id[0] &&
            strcmp(s->app_id, app_id) == 0)
            return s;
    }
    return NULL;
}

static int wm_raise_app(const char *app_id)
{
    struct iosc_surface *s = wm_find_toplevel_by_app_id(app_id);
    if (!s) return 0;
    surface_raise(s);
    keyboard_set_focus(s);
    recomposite_all();
    wl_display_flush_clients(g_display);
    fprintf(stderr, "iosc: wm raise app_id=\"%s\" -> raised\n", app_id);
    return 1;
}

/* Handle one line: "raise\t<app_id>". Best-effort reply on fd. */
static void wm_handle_line(int fd, char *line)
{
    char *tab = strchr(line, '\t');
    const char *reply = "err\n";
    if (tab && (size_t)(tab - line) == 5 && strncmp(line, "raise", 5) == 0)
        reply = wm_raise_app(tab + 1) ? "ok\n" : "notfound\n";
    ssize_t n = write(fd, reply, strlen(reply));   /* best-effort */
    (void)n;
}

static void wm_client_drop(struct iosc_wm_client *c)
{
    if (!c) return;
    for (int i = 0; i < IOSC_MAX_WM_CLIENTS; i++)
        if (g_wm_clients[i] == c) g_wm_clients[i] = NULL;
    if (c->src) wl_event_source_remove(c->src);
    if (c->fd >= 0) close(c->fd);
    free(c);
}

static int wm_client_readable(int fd, uint32_t mask, void *data)
{
    struct iosc_wm_client *c = data;
    if (mask & (WL_EVENT_HANGUP | WL_EVENT_ERROR)) { wm_client_drop(c); return 0; }
    for (;;) {
        if (c->have >= IOSC_WM_BUF - 1) c->have = 0;   /* overflow: drop partial */
        ssize_t r = read(fd, c->buf + c->have, IOSC_WM_BUF - 1 - c->have);
        if (r > 0) {
            c->have += (int)r;
            char *nl;
            while ((nl = memchr(c->buf, '\n', (size_t)c->have)) != NULL) {
                *nl = 0;
                char *cr = strchr(c->buf, '\r'); if (cr) *cr = 0;
                wm_handle_line(fd, c->buf);
                int consumed = (int)(nl + 1 - c->buf);
                c->have -= consumed;
                memmove(c->buf, nl + 1, (size_t)c->have);
            }
            continue;
        }
        if (r == 0) { wm_client_drop(c); return 0; }
        if (errno == EAGAIN || errno == EWOULDBLOCK) break;
        if (errno == EINTR) continue;
        wm_client_drop(c); return 0;
    }
    return 0;
}

static int wm_listen_readable(int fd, uint32_t mask, void *data)
{
    (void)mask;
    struct wl_event_loop *loop = data;
    int cfd = accept(fd, NULL, NULL);
    if (cfd < 0) return 0;
    fcntl(cfd, F_SETFL, fcntl(cfd, F_GETFL, 0) | O_NONBLOCK);
    int slot = -1;
    for (int i = 0; i < IOSC_MAX_WM_CLIENTS; i++) if (!g_wm_clients[i]) { slot = i; break; }
    if (slot < 0) { close(cfd); return 0; }
    struct iosc_wm_client *c = calloc(1, sizeof(*c));
    if (!c) { close(cfd); return 0; }
    c->fd = cfd;
    c->src = wl_event_loop_add_fd(loop, cfd, WL_EVENT_READABLE, wm_client_readable, c);
    g_wm_clients[slot] = c;
    return 0;
}

static int wm_socket_start(struct wl_event_loop *loop, const char *path)
{
    unlink(path);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    struct sockaddr_un addr; memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, path, sizeof(addr.sun_path) - 1);
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) { close(fd); return -1; }
    if (listen(fd, 4) < 0) { close(fd); return -1; }
    chmod(path, 0777);   /* ioscd / the panel connect from outside the app sandbox */
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK);
    wl_event_loop_add_fd(loop, fd, WL_EVENT_READABLE, wm_listen_readable, loop);
    return 0;
}

/* ===========================================================================
 * relative-pointer (zwp_relative_pointer_manager_v1)
 *
 * iosc only ever receives ABSOLUTE positions from the Xios app, so the relative
 * delta is synthesised in handle_motion() (Δ from the previous absolute point)
 * and reported here. Deltas go to the client that currently holds pointer focus.
 * Unaccelerated == accelerated (no pointer accel curve on a touch device).
 * =========================================================================== */

#define IOSC_MAX_RELPTR 32
static struct wl_resource *g_relptr[IOSC_MAX_RELPTR]; static int g_nrelptr;

static void relptr_res_destroy(struct wl_resource *r){ reslist_remove(g_relptr, &g_nrelptr, r); }
static void relptr_destroy(struct wl_client *c, struct wl_resource *r){ (void)c; wl_resource_destroy(r); }
static const struct zwp_relative_pointer_v1_interface relptr_impl = { .destroy = relptr_destroy };

static void relptr_send(uint32_t time, double dx, double dy)
{
    if (!g_ptr_focus) return;
    struct wl_client *fc = wl_resource_get_client(g_ptr_focus->resource);
    uint64_t us = (uint64_t)time * 1000u;
    uint32_t hi = (uint32_t)(us >> 32), lo = (uint32_t)(us & 0xffffffffu);
    wl_fixed_t fdx = wl_fixed_from_double(dx), fdy = wl_fixed_from_double(dy);
    for (int i = 0; i < g_nrelptr; i++)
        if (wl_resource_get_client(g_relptr[i]) == fc)
            zwp_relative_pointer_v1_send_relative_motion(g_relptr[i], hi, lo, fdx, fdy, fdx, fdy);
}

static void relptr_mgr_get(struct wl_client *c, struct wl_resource *r, uint32_t id,
                           struct wl_resource *pointer)
{ (void)pointer;
    struct wl_resource *rp = wl_resource_create(c, &zwp_relative_pointer_v1_interface,
                                                wl_resource_get_version(r), id);
    if (!rp) { wl_client_post_no_memory(c); return; }
    wl_resource_set_implementation(rp, &relptr_impl, NULL, relptr_res_destroy);
    if (g_nrelptr < IOSC_MAX_RELPTR) g_relptr[g_nrelptr++] = rp;
}
static void relptr_mgr_destroy(struct wl_client *c, struct wl_resource *r){ (void)c; wl_resource_destroy(r); }
static const struct zwp_relative_pointer_manager_v1_interface relptr_mgr_impl = {
    .destroy = relptr_mgr_destroy, .get_relative_pointer = relptr_mgr_get };
static void relptr_mgr_bind(struct wl_client *c, void *data, uint32_t version, uint32_t id)
{ (void)data;
    struct wl_resource *r = wl_resource_create(c, &zwp_relative_pointer_manager_v1_interface, version, id);
    if (!r) { wl_client_post_no_memory(c); return; }
    wl_resource_set_implementation(r, &relptr_mgr_impl, NULL, NULL);
}

/* ===========================================================================
 * pointer-constraints (zwp_pointer_constraints_v1)
 *
 * A constraint targets a surface. It becomes ACTIVE when that surface holds
 * pointer focus (constraints_update_focus, called on focus change + on create).
 *   - locked:  the cursor freezes; handle_motion() reports only relative deltas.
 *   - confined: the cursor is clamped to the surface rectangle.
 * region is ignored (whole-surface constraint). oneshot lifetime constraints are
 * marked dead after their first deactivation and never re-activate.
 * =========================================================================== */

#define IOSC_MAX_CONSTRAINTS 16
struct iosc_constraint {
    struct wl_resource *resource;
    struct iosc_surface *surface;
    int type;            /* 0 = locked, 1 = confined */
    uint32_t lifetime;   /* ZWP_POINTER_CONSTRAINTS_V1_LIFETIME_* */
    int active;
    int dead;            /* oneshot consumed */
};
static struct iosc_constraint *g_constraints[IOSC_MAX_CONSTRAINTS]; static int g_nconstraints;
static struct iosc_constraint *g_active_constraint;

static struct iosc_constraint *constraint_for_surface(struct iosc_surface *s)
{
    if (!s) return NULL;
    for (int i = 0; i < g_nconstraints; i++)
        if (!g_constraints[i]->dead && g_constraints[i]->surface == s)
            return g_constraints[i];
    return NULL;
}
static void constraint_deactivate(struct iosc_constraint *cc)
{
    if (!cc || !cc->active) return;
    cc->active = 0;
    if (cc->type == 0) zwp_locked_pointer_v1_send_unlocked(cc->resource);
    else               zwp_confined_pointer_v1_send_unconfined(cc->resource);
    if (cc->lifetime == ZWP_POINTER_CONSTRAINTS_V1_LIFETIME_ONESHOT) cc->dead = 1;
    if (g_active_constraint == cc) g_active_constraint = NULL;
}
static void constraint_activate(struct iosc_constraint *cc)
{
    if (!cc || cc->active) return;
    cc->active = 1;
    g_active_constraint = cc;
    if (cc->type == 0) zwp_locked_pointer_v1_send_locked(cc->resource);
    else               zwp_confined_pointer_v1_send_confined(cc->resource);
}
static void constraints_update_focus(struct iosc_surface *newfocus)
{
    if (g_active_constraint && g_active_constraint->surface != newfocus)
        constraint_deactivate(g_active_constraint);
    if (!g_active_constraint) {
        struct iosc_constraint *cc = constraint_for_surface(newfocus);
        if (cc) constraint_activate(cc);
    }
}
static int pointer_locked_for(struct iosc_surface *s)
{
    return g_active_constraint && g_active_constraint->active &&
           g_active_constraint->type == 0 && g_active_constraint->surface == s;
}
static int confine_point(struct iosc_surface *s, int *x, int *y)
{
    if (!(g_active_constraint && g_active_constraint->active &&
          g_active_constraint->type == 1 && g_active_constraint->surface == s))
        return 0;
    int w = 0, h = 0; surface_display_size(s, &w, &h);
    if (w > 0) *x = clampi(*x, s->dx, s->dx + w - 1);
    if (h > 0) *y = clampi(*y, s->dy, s->dy + h - 1);
    return 1;
}
static void constraints_surface_gone(struct iosc_surface *s)
{
    for (int i = 0; i < g_nconstraints; i++)
        if (g_constraints[i]->surface == s) {
            if (g_constraints[i]->active) constraint_deactivate(g_constraints[i]);
            g_constraints[i]->surface = NULL;
        }
}

static void constraint_res_destroy(struct wl_resource *r)
{
    struct iosc_constraint *cc = wl_resource_get_user_data(r);
    if (!cc) return;
    if (g_active_constraint == cc) g_active_constraint = NULL;
    for (int i = 0; i < g_nconstraints; i++)
        if (g_constraints[i] == cc) { g_constraints[i] = g_constraints[--g_nconstraints]; break; }
    free(cc);
}
static void constraint_destroy_req(struct wl_client *c, struct wl_resource *r){ (void)c; wl_resource_destroy(r); }
static void locked_ptr_set_hint(struct wl_client *c, struct wl_resource *r, wl_fixed_t x, wl_fixed_t y)
{ (void)c; (void)r; (void)x; (void)y; }
static void constraint_set_region(struct wl_client *c, struct wl_resource *r, struct wl_resource *region)
{ (void)c; (void)r; (void)region; }   /* whole-surface constraint; region ignored */

static const struct zwp_locked_pointer_v1_interface locked_ptr_impl = {
    .destroy = constraint_destroy_req,
    .set_cursor_position_hint = locked_ptr_set_hint,
    .set_region = constraint_set_region,
};
static const struct zwp_confined_pointer_v1_interface confined_ptr_impl = {
    .destroy = constraint_destroy_req,
    .set_region = constraint_set_region,
};

static void constraint_new(struct wl_client *c, struct wl_resource *r, uint32_t id,
        struct wl_resource *surface, uint32_t lifetime, int type,
        const struct wl_interface *iface, const void *impl)
{
    if (g_nconstraints >= IOSC_MAX_CONSTRAINTS) { wl_client_post_no_memory(c); return; }
    struct iosc_constraint *cc = calloc(1, sizeof(*cc));
    if (!cc) { wl_client_post_no_memory(c); return; }
    cc->resource = wl_resource_create(c, iface, wl_resource_get_version(r), id);
    if (!cc->resource) { free(cc); wl_client_post_no_memory(c); return; }
    cc->surface  = surface ? wl_resource_get_user_data(surface) : NULL;
    cc->type     = type;
    cc->lifetime = lifetime;
    wl_resource_set_implementation(cc->resource, impl, cc, constraint_res_destroy);
    g_constraints[g_nconstraints++] = cc;
    /* Activate right away if the target already owns the pointer. */
    if (cc->surface && cc->surface == g_ptr_focus && !g_active_constraint)
        constraint_activate(cc);
}
static void constraints_lock_pointer(struct wl_client *c, struct wl_resource *r, uint32_t id,
        struct wl_resource *surface, struct wl_resource *pointer,
        struct wl_resource *region, uint32_t lifetime)
{ (void)pointer; (void)region;
    constraint_new(c, r, id, surface, lifetime, 0, &zwp_locked_pointer_v1_interface, &locked_ptr_impl);
}
static void constraints_confine_pointer(struct wl_client *c, struct wl_resource *r, uint32_t id,
        struct wl_resource *surface, struct wl_resource *pointer,
        struct wl_resource *region, uint32_t lifetime)
{ (void)pointer; (void)region;
    constraint_new(c, r, id, surface, lifetime, 1, &zwp_confined_pointer_v1_interface, &confined_ptr_impl);
}
static void constraints_destroy(struct wl_client *c, struct wl_resource *r){ (void)c; wl_resource_destroy(r); }
static const struct zwp_pointer_constraints_v1_interface constraints_impl = {
    .destroy = constraints_destroy,
    .lock_pointer = constraints_lock_pointer,
    .confine_pointer = constraints_confine_pointer,
};
static void constraints_bind(struct wl_client *c, void *data, uint32_t version, uint32_t id)
{ (void)data;
    struct wl_resource *r = wl_resource_create(c, &zwp_pointer_constraints_v1_interface, version, id);
    if (!r) { wl_client_post_no_memory(c); return; }
    wl_resource_set_implementation(r, &constraints_impl, NULL, NULL);
}

/* ===========================================================================
 * primary selection (zwp_primary_selection_device_manager_v1)
 *
 * The X11-style middle-click selection, kept SEPARATE from wl_data_device's
 * CLIPBOARD and from the UIPasteboard bridge. Direct brokering: the current
 * source lives in its owning client; a reader's offer.receive is forwarded to
 * that source's `send` event (no in-memory copy). The current selection is
 * pushed to whichever client holds keyboard focus.
 * =========================================================================== */

#define IOSC_MAX_PRIMARY_MIMES   16
#define IOSC_MAX_PRIMARY_DEVICES 32
struct iosc_primary_source {
    struct wl_resource *resource;
    char *mimes[IOSC_MAX_PRIMARY_MIMES];
    int nmimes;
};
static struct iosc_primary_source *g_primary_source;      /* current owner, or NULL */
static struct wl_resource *g_primary_devices[IOSC_MAX_PRIMARY_DEVICES];
static int g_nprimary_devices;

static void primary_offer_receive(struct wl_client *c, struct wl_resource *r,
                                  const char *mime, int fd)
{ (void)c; (void)r;
    if (g_primary_source && g_primary_source->resource)
        zwp_primary_selection_source_v1_send_send(g_primary_source->resource, mime, fd);
    close(fd);
}
static void primary_offer_destroy_req(struct wl_client *c, struct wl_resource *r){ (void)c; wl_resource_destroy(r); }
static const struct zwp_primary_selection_offer_v1_interface primary_offer_impl = {
    .receive = primary_offer_receive, .destroy = primary_offer_destroy_req };

static void primary_selection_send_to_device(struct wl_resource *dev)
{
    struct wl_client *c = wl_resource_get_client(dev);
    if (!g_primary_source) { zwp_primary_selection_device_v1_send_selection(dev, NULL); return; }
    struct wl_resource *offer = wl_resource_create(c, &zwp_primary_selection_offer_v1_interface,
                                                   wl_resource_get_version(dev), 0);
    if (!offer) return;
    wl_resource_set_implementation(offer, &primary_offer_impl, NULL, NULL);
    zwp_primary_selection_device_v1_send_data_offer(dev, offer);
    for (int i = 0; i < g_primary_source->nmimes; i++)
        zwp_primary_selection_offer_v1_send_offer(offer, g_primary_source->mimes[i]);
    zwp_primary_selection_device_v1_send_selection(dev, offer);
}
static void primary_selection_send_to_client(struct wl_client *client)
{
    if (!client) return;
    for (int i = 0; i < g_nprimary_devices; i++)
        if (wl_resource_get_client(g_primary_devices[i]) == client)
            primary_selection_send_to_device(g_primary_devices[i]);
}
static void primary_selection_broadcast(void)
{
    if (g_kbd_focus) primary_selection_send_to_client(wl_resource_get_client(g_kbd_focus->resource));
}

static void primary_source_offer(struct wl_client *c, struct wl_resource *r, const char *mime)
{
    struct iosc_primary_source *s = wl_resource_get_user_data(r);
    if (!s || !mime || s->nmimes >= IOSC_MAX_PRIMARY_MIMES) return;
    char *copy = strdup(mime);
    if (!copy) { wl_client_post_no_memory(c); return; }
    s->mimes[s->nmimes++] = copy;
}
static void primary_source_destroy_req(struct wl_client *c, struct wl_resource *r){ (void)c; wl_resource_destroy(r); }
static const struct zwp_primary_selection_source_v1_interface primary_source_impl = {
    .offer = primary_source_offer, .destroy = primary_source_destroy_req };
static void primary_source_res_destroy(struct wl_resource *r)
{
    struct iosc_primary_source *s = wl_resource_get_user_data(r);
    if (!s) return;
    for (int i = 0; i < s->nmimes; i++) free(s->mimes[i]);
    if (g_primary_source == s) { g_primary_source = NULL; primary_selection_broadcast(); }
    free(s);
}

static void primary_device_set_selection(struct wl_client *c, struct wl_resource *r,
                                         struct wl_resource *source, uint32_t serial)
{ (void)c; (void)r; (void)serial;
    g_primary_source = source ? wl_resource_get_user_data(source) : NULL;
    primary_selection_broadcast();
}
static void primary_device_destroy_req(struct wl_client *c, struct wl_resource *r){ (void)c; wl_resource_destroy(r); }
static const struct zwp_primary_selection_device_v1_interface primary_device_impl = {
    .set_selection = primary_device_set_selection, .destroy = primary_device_destroy_req };
static void primary_device_res_destroy(struct wl_resource *r)
{ reslist_remove(g_primary_devices, &g_nprimary_devices, r); }

static void primary_mgr_create_source(struct wl_client *c, struct wl_resource *r, uint32_t id)
{
    struct iosc_primary_source *s = calloc(1, sizeof(*s));
    if (!s) { wl_client_post_no_memory(c); return; }
    s->resource = wl_resource_create(c, &zwp_primary_selection_source_v1_interface,
                                     wl_resource_get_version(r), id);
    if (!s->resource) { free(s); wl_client_post_no_memory(c); return; }
    wl_resource_set_implementation(s->resource, &primary_source_impl, s, primary_source_res_destroy);
}
static void primary_mgr_get_device(struct wl_client *c, struct wl_resource *r, uint32_t id,
                                   struct wl_resource *seat)
{ (void)seat;
    if (g_nprimary_devices >= IOSC_MAX_PRIMARY_DEVICES) { wl_client_post_no_memory(c); return; }
    struct wl_resource *dev = wl_resource_create(c, &zwp_primary_selection_device_v1_interface,
                                                 wl_resource_get_version(r), id);
    if (!dev) { wl_client_post_no_memory(c); return; }
    wl_resource_set_implementation(dev, &primary_device_impl, NULL, primary_device_res_destroy);
    g_primary_devices[g_nprimary_devices++] = dev;
    if (g_kbd_focus && wl_resource_get_client(g_kbd_focus->resource) == c)
        primary_selection_send_to_device(dev);
}
static void primary_mgr_destroy(struct wl_client *c, struct wl_resource *r){ (void)c; wl_resource_destroy(r); }
static const struct zwp_primary_selection_device_manager_v1_interface primary_mgr_impl = {
    .create_source = primary_mgr_create_source,
    .get_device = primary_mgr_get_device,
    .destroy = primary_mgr_destroy };
static void primary_mgr_bind(struct wl_client *c, void *data, uint32_t version, uint32_t id)
{ (void)data;
    struct wl_resource *r = wl_resource_create(c, &zwp_primary_selection_device_manager_v1_interface, version, id);
    if (!r) { wl_client_post_no_memory(c); return; }
    wl_resource_set_implementation(r, &primary_mgr_impl, NULL, NULL);
}

/* ===========================================================================
 * idle: ext_idle_notifier_v1 (notifications) + zwp_idle_inhibit_manager_v1.
 *
 * Each notification arms a timer for its timeout; input activity (pointer/key)
 * resets every timer and sends `resumed` to any that had `idled`. While any idle
 * inhibitor exists (video players, presentations) the timers never fire idle.
 * =========================================================================== */

#define IOSC_MAX_IDLE_NOTIF 32
struct iosc_idle_notif {
    struct wl_resource *resource;
    uint32_t timeout_ms;
    struct wl_event_source *timer;
    int idled;
};
static struct iosc_idle_notif *g_idle_notifs[IOSC_MAX_IDLE_NOTIF]; static int g_nidle_notifs;
static int g_idle_inhibitors;

static int idle_timer_cb(void *data)
{
    struct iosc_idle_notif *n = data;
    if (g_idle_inhibitors > 0) {          /* inhibited: stay awake, re-arm */
        if (n->timer && n->timeout_ms) wl_event_source_timer_update(n->timer, n->timeout_ms);
        return 0;
    }
    if (!n->idled) { n->idled = 1; ext_idle_notification_v1_send_idled(n->resource); }
    return 0;
}
static void idle_note_activity(void)
{
    for (int i = 0; i < g_nidle_notifs; i++) {
        struct iosc_idle_notif *n = g_idle_notifs[i];
        if (n->idled) { n->idled = 0; ext_idle_notification_v1_send_resumed(n->resource); }
        if (n->timer && n->timeout_ms) wl_event_source_timer_update(n->timer, n->timeout_ms);
    }
}

static void idle_notif_destroy_req(struct wl_client *c, struct wl_resource *r){ (void)c; wl_resource_destroy(r); }
static const struct ext_idle_notification_v1_interface idle_notif_impl = { .destroy = idle_notif_destroy_req };
static void idle_notif_res_destroy(struct wl_resource *r)
{
    struct iosc_idle_notif *n = wl_resource_get_user_data(r);
    if (!n) return;
    if (n->timer) wl_event_source_remove(n->timer);
    for (int i = 0; i < g_nidle_notifs; i++)
        if (g_idle_notifs[i] == n) { g_idle_notifs[i] = g_idle_notifs[--g_nidle_notifs]; break; }
    free(n);
}
static void idle_notifier_get(struct wl_client *c, struct wl_resource *r, uint32_t id,
                              uint32_t timeout, struct wl_resource *seat)
{ (void)seat;
    if (g_nidle_notifs >= IOSC_MAX_IDLE_NOTIF) { wl_client_post_no_memory(c); return; }
    struct iosc_idle_notif *n = calloc(1, sizeof(*n));
    if (!n) { wl_client_post_no_memory(c); return; }
    n->resource = wl_resource_create(c, &ext_idle_notification_v1_interface, wl_resource_get_version(r), id);
    if (!n->resource) { free(n); wl_client_post_no_memory(c); return; }
    n->timeout_ms = timeout ? timeout : 1;
    wl_resource_set_implementation(n->resource, &idle_notif_impl, n, idle_notif_res_destroy);
    n->timer = wl_event_loop_add_timer(wl_display_get_event_loop(g_display), idle_timer_cb, n);
    if (n->timer) wl_event_source_timer_update(n->timer, n->timeout_ms);
    g_idle_notifs[g_nidle_notifs++] = n;
}
static void idle_notifier_destroy(struct wl_client *c, struct wl_resource *r){ (void)c; wl_resource_destroy(r); }
static const struct ext_idle_notifier_v1_interface idle_notifier_impl = {
    .destroy = idle_notifier_destroy, .get_idle_notification = idle_notifier_get };
static void idle_notifier_bind(struct wl_client *c, void *data, uint32_t version, uint32_t id)
{ (void)data;
    struct wl_resource *r = wl_resource_create(c, &ext_idle_notifier_v1_interface, version, id);
    if (!r) { wl_client_post_no_memory(c); return; }
    wl_resource_set_implementation(r, &idle_notifier_impl, NULL, NULL);
}

static void idle_inhibitor_destroy_req(struct wl_client *c, struct wl_resource *r){ (void)c; wl_resource_destroy(r); }
static const struct zwp_idle_inhibitor_v1_interface idle_inhibitor_impl = { .destroy = idle_inhibitor_destroy_req };
static void idle_inhibitor_res_destroy(struct wl_resource *r){ (void)r; if (g_idle_inhibitors > 0) g_idle_inhibitors--; }
static void idle_inhibit_create(struct wl_client *c, struct wl_resource *r, uint32_t id,
                                struct wl_resource *surface)
{ (void)surface;
    struct wl_resource *inh = wl_resource_create(c, &zwp_idle_inhibitor_v1_interface, wl_resource_get_version(r), id);
    if (!inh) { wl_client_post_no_memory(c); return; }
    wl_resource_set_implementation(inh, &idle_inhibitor_impl, NULL, idle_inhibitor_res_destroy);
    g_idle_inhibitors++;
}
static void idle_inhibit_mgr_destroy(struct wl_client *c, struct wl_resource *r){ (void)c; wl_resource_destroy(r); }
static const struct zwp_idle_inhibit_manager_v1_interface idle_inhibit_mgr_impl = {
    .create_inhibitor = idle_inhibit_create, .destroy = idle_inhibit_mgr_destroy };
static void idle_inhibit_mgr_bind(struct wl_client *c, void *data, uint32_t version, uint32_t id)
{ (void)data;
    struct wl_resource *r = wl_resource_create(c, &zwp_idle_inhibit_manager_v1_interface, version, id);
    if (!r) { wl_client_post_no_memory(c); return; }
    wl_resource_set_implementation(r, &idle_inhibit_mgr_impl, NULL, NULL);
}

/* ===========================================================================
 * ext-session-lock-v1 (screen locking)
 *
 * State + the render/input/focus confinement hooks live at the top of the file
 * (g_slock; recomposite_all, surface_at, keyboard_set_focus, surface_unmap).
 * This section is just the protocol plumbing: grant/deny the lock, hand out
 * the (single-output) lock surface with an output-sized configure, and unlock.
 * =========================================================================== */

static void slock_surface_destroy_req(struct wl_client *c, struct wl_resource *r)
{ (void)c; wl_resource_destroy(r); }
static void slock_surface_ack_configure(struct wl_client *c, struct wl_resource *r, uint32_t serial)
{ (void)c; (void)r; (void)serial; }   /* single fixed-size configure; nothing to track */
static const struct ext_session_lock_surface_v1_interface slock_surface_impl = {
    .destroy = slock_surface_destroy_req,
    .ack_configure = slock_surface_ack_configure,
};

static void slock_surface_resource_destroy(struct wl_resource *r)
{
    struct iosc_surface *s = wl_resource_get_user_data(r);
    if (!s) return;                     /* disarmed by surface_unmap */
    s->role = IOSC_ROLE_NONE;           /* the wl_surface may be reused */
    if (g_slock.surface == s) {
        g_slock.surface = NULL;
        g_slock.lock_surface = NULL;
        if (g_kbd_focus == s) keyboard_set_focus(NULL);
        recomposite_all();              /* blank again while still locked */
    }
}

static void slock_get_lock_surface(struct wl_client *c, struct wl_resource *r, uint32_t id,
                                   struct wl_resource *surf, struct wl_resource *output)
{ (void)output;   /* single output */
    struct iosc_surface *s = surf ? wl_resource_get_user_data(surf) : NULL;
    if (!s) return;
    if (g_slock.lock != r || !g_slock.locked) return;   /* denied lock: inert */
    if (s->role != IOSC_ROLE_NONE) {
        wl_resource_post_error(r, EXT_SESSION_LOCK_V1_ERROR_ROLE,
                               "surface already has a role");
        return;
    }
    if (g_slock.surface) {
        wl_resource_post_error(r, EXT_SESSION_LOCK_V1_ERROR_DUPLICATE_OUTPUT,
                               "output already has a lock surface");
        return;
    }
    struct wl_resource *ls = wl_resource_create(c, &ext_session_lock_surface_v1_interface,
                                                wl_resource_get_version(r), id);
    if (!ls) { wl_client_post_no_memory(c); return; }
    s->role = IOSC_ROLE_LOCK;
    s->dx = 0;
    s->dy = 0;
    g_slock.surface = s;
    g_slock.lock_surface = ls;
    wl_resource_set_implementation(ls, &slock_surface_impl, s, slock_surface_resource_destroy);
    ext_session_lock_surface_v1_send_configure(ls, wl_display_next_serial(g_display),
                                               (uint32_t)output_logical_width(),
                                               (uint32_t)output_logical_height());
    keyboard_set_focus(s);
    fprintf(stderr, "iosc: session-lock surface created (%dx%d configure)\n",
            output_logical_width(), output_logical_height());
}

static void slock_destroy_req(struct wl_client *c, struct wl_resource *r)
{ (void)c;
    /* Plain destroy is only legal while NOT locked through this object (i.e.
     * after a finished event); a locked client must use unlock_and_destroy. */
    if (g_slock.lock == r && g_slock.locked) {
        wl_resource_post_error(r, EXT_SESSION_LOCK_V1_ERROR_INVALID_DESTROY,
                               "destroy while locked (use unlock_and_destroy)");
        return;
    }
    wl_resource_destroy(r);
}

static void slock_unlock_and_destroy(struct wl_client *c, struct wl_resource *r)
{ (void)c;
    if (g_slock.lock != r || !g_slock.locked) {
        wl_resource_post_error(r, EXT_SESSION_LOCK_V1_ERROR_INVALID_UNLOCK,
                               "unlock on a lock that was never granted");
        return;
    }
    g_slock.locked = 0;
    g_slock.lock = NULL;
    fprintf(stderr, "iosc: session UNLOCKED\n");
    keyboard_set_focus(topmost_focusable());
    g_ptr_focus = NULL;                /* next motion re-enters normally */
    recomposite_all();                 /* windows come back */
    wl_resource_destroy(r);
}

static const struct ext_session_lock_v1_interface slock_impl = {
    .destroy = slock_destroy_req,
    .get_lock_surface = slock_get_lock_surface,
    .unlock_and_destroy = slock_unlock_and_destroy,
};

static void slock_resource_destroy(struct wl_resource *r)
{
    /* Reached with the session still locked only when the locker died or its
     * client misbehaved: keep the session locked (spec: never unlock on crash);
     * a new ext_session_lock_manager_v1.lock may take over and unlock. */
    if (g_slock.lock == r) {
        g_slock.lock = NULL;
        if (g_slock.locked)
            fprintf(stderr, "iosc: session lock ABANDONED; staying locked "
                            "(run a locker again to take over)\n");
    }
}

static void slock_mgr_lock(struct wl_client *c, struct wl_resource *r, uint32_t id)
{
    struct wl_resource *lk = wl_resource_create(c, &ext_session_lock_v1_interface,
                                                wl_resource_get_version(r), id);
    if (!lk) { wl_client_post_no_memory(c); return; }
    wl_resource_set_implementation(lk, &slock_impl, NULL, slock_resource_destroy);
    if (g_slock.lock) {
        /* Another locker is active: deny (client should destroy the object). */
        ext_session_lock_v1_send_finished(lk);
        fprintf(stderr, "iosc: session-lock denied (already locked)\n");
        return;
    }
    g_slock.lock = lk;
    g_slock.locked = 1;                /* also adopts an abandoned locked session */
    ext_session_lock_v1_send_locked(lk);
    fprintf(stderr, "iosc: session LOCKED\n");
    keyboard_set_focus(NULL);          /* redirected to the lock surface once it exists */
    g_ptr_focus = NULL;
    if (g_dnd.active) {                /* a drag can't survive the screen locking */
        if (g_dnd.source) wl_data_source_send_cancelled(g_dnd.source);
        dnd_end();
    }
    touch_cancel_all();                /* nor can in-flight touch sequences */
    pen_leave(now_ms());               /* nor a pen stroke */
    recomposite_all();                 /* blank the output right away */
}

static void slock_mgr_destroy(struct wl_client *c, struct wl_resource *r)
{ (void)c; wl_resource_destroy(r); }
static const struct ext_session_lock_manager_v1_interface slock_mgr_impl = {
    .destroy = slock_mgr_destroy,
    .lock = slock_mgr_lock,
};
static void slock_mgr_bind(struct wl_client *c, void *data, uint32_t version, uint32_t id)
{ (void)data;
    struct wl_resource *r = wl_resource_create(c, &ext_session_lock_manager_v1_interface, version, id);
    if (!r) { wl_client_post_no_memory(c); return; }
    wl_resource_set_implementation(r, &slock_mgr_impl, NULL, NULL);
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
        } else if (!strcmp(argv[i], "-dpi") && i + 1 < argc) {
            int dpi = atoi(argv[++i]);
            if (dpi > 0) g_output_dpi = dpi;
        } else if (!strcmp(argv[i], "-scale") && i + 1 < argc) {
            int scale = atoi(argv[++i]);
            if (scale > 0) g_output_scale = scale;
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
    xios_set_compositor_id("iosc");   /* typed clients learn the flavor via the in-band HELLO */
    if (xios_server_start(ddx_sock, json_path, g_width, g_height, g_stride) != 0) {
        fprintf(stderr, "iosc: xios_server_start failed\n");
        return 1;
    }
    fprintf(stderr, "iosc: output IOSurface %dx%d stride=%d; logical=%dx%d scale=%d dpi=%d; app socket=%s\n",
            g_width, g_height, g_stride,
            output_logical_width(), output_logical_height(), output_scale(), g_output_dpi,
            ddx_sock);

    /* 1b) GPU compositor: an ANGLE context whose render target is the output
     *     IOSurface, so commits are composited on the GPU (client IOSurfaces
     *     sampled zero-copy). Falls back to the CPU blit if GL init fails. */
    if (iosc_gl_init(xios_get_output_iosurface(), g_width, g_height) != 0)
        fprintf(stderr, "iosc: GPU compositor unavailable -> CPU fallback path\n");

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
    wl_global_create(g_display, &xdg_wm_base_interface, 4, NULL, xdg_wm_base_bind);
    wl_global_create(g_display, &iosc_iosurface_interface, 1, NULL, iosc_iosurface_bind);
    /* GTK4 (GDK-wayland) enablement globals. */
    wl_global_create(g_display, &wl_output_interface, 4, NULL, output_bind);
    wl_global_create(g_display, &zxdg_output_manager_v1_interface, 3, NULL,
                     xdg_output_manager_bind);
    wl_global_create(g_display, &wl_seat_interface, 5, NULL, seat_bind);
    wl_global_create(g_display, &wl_subcompositor_interface, 1, NULL, subcompositor_bind);
    wl_global_create(g_display, &wl_data_device_manager_interface, 3, NULL, ddm_bind);
    wl_global_create(g_display, &wp_viewporter_interface, 1, NULL, viewporter_bind);
    wl_global_create(g_display, &wp_fractional_scale_manager_v1_interface, 1, NULL,
                     fractional_scale_bind);
    wl_global_create(g_display, &wp_presentation_interface, 1, NULL, presentation_bind);
    wl_global_create(g_display, &zxdg_decoration_manager_v1_interface, 1, NULL,
                     decoration_manager_bind);
    wl_global_create(g_display, &xdg_activation_v1_interface, 1, NULL, activation_bind);
    wl_global_create(g_display, &zwp_text_input_manager_v3_interface, 1, NULL,
                     text_input_manager_bind);
    wl_global_create(g_display, &zwp_input_method_manager_v2_interface, 1, NULL,
                     input_method_manager_bind);
    wl_global_create(g_display, &zwp_virtual_keyboard_manager_v1_interface, 1, NULL,
                     virtual_keyboard_manager_bind);
    /* Desktop-shell chrome: panel/overview/gtk4-layer-shell clients. v4 = the
     * on_demand keyboard interactivity the overview needs. */
    wl_global_create(g_display, &zwlr_layer_shell_v1_interface, 4, NULL, layer_shell_bind);
    /* Window list as a protocol: the taskbar/overview enumerates + drives toplevels. */
    wl_global_create(g_display, &zwlr_foreign_toplevel_manager_v1_interface, 3, NULL,
                     ftl_manager_bind);
    /* Pointer lock + relative motion: games, 3D viewports, gnome-shell mouse-look. */
    wl_global_create(g_display, &zwp_pointer_constraints_v1_interface, 1, NULL, constraints_bind);
    wl_global_create(g_display, &zwp_relative_pointer_manager_v1_interface, 1, NULL, relptr_mgr_bind);
    /* X11-style middle-click primary selection (separate from the clipboard). */
    wl_global_create(g_display, &zwp_primary_selection_device_manager_v1_interface, 1, NULL,
                     primary_mgr_bind);
    /* Idle detection + inhibition (screensavers/power; video players stay awake). */
    wl_global_create(g_display, &ext_idle_notifier_v1_interface, 1, NULL, idle_notifier_bind);
    wl_global_create(g_display, &zwp_idle_inhibit_manager_v1_interface, 1, NULL, idle_inhibit_mgr_bind);
    /* 1x1 solid-colour buffers (CSD shadows, solid backdrops), scaled via viewporter. */
    wl_global_create(g_display, &wp_single_pixel_buffer_manager_v1_interface, 1, NULL, spb_mgr_bind);
    /* Named cursor shapes (GTK4/Adwaita prefer this over uploading a cursor surface). */
    wl_global_create(g_display, &wp_cursor_shape_manager_v1_interface, 1, NULL, cshape_mgr_bind);
    /* Screenshots: software readback of the output IOSurface (grim, portals, spectacle). */
    wl_global_create(g_display, &zwlr_screencopy_manager_v1_interface, 3, NULL, screencopy_mgr_bind);

    wl_global_create(g_display, &ext_session_lock_manager_v1_interface, 1, NULL, slock_mgr_bind);

    wl_global_create(g_display, &zwp_tablet_manager_v2_interface, 1, NULL, tablet_mgr_bind);

    /* 2b) Input: xkb keymap + the app input socket on this display's event loop.
     *     Keyboard cap is only advertised if the keymap compiled. */
    if (iosc_input_init() == 0) {
        g_keymap_fd = make_keymap_fd();
        g_have_keyboard = (g_keymap_fd >= 0);
    }
    if (!g_have_keyboard)
        fprintf(stderr, "iosc: keyboard unavailable (xkb keymap) -> pointer only\n");
    g_refocus_timer = wl_event_loop_add_timer(wl_display_get_event_loop(g_display),
                                              refocus_cb, NULL);
    if (input_socket_start(wl_display_get_event_loop(g_display),
                           "/var/jb/tmp/iosc-input.sock") != 0)
        fprintf(stderr, "iosc: input socket failed -> no app input\n");
    else
        fprintf(stderr, "iosc: input socket up at /var/jb/tmp/iosc-input.sock\n");
    if (clipboard_socket_start(wl_display_get_event_loop(g_display),
                               "/var/jb/tmp/iosc-clipboard.sock") != 0)
        fprintf(stderr, "iosc: clipboard socket failed -> no UIPasteboard bridge\n");
    else
        fprintf(stderr, "iosc: clipboard socket up at /var/jb/tmp/iosc-clipboard.sock\n");
    if (wm_socket_start(wl_display_get_event_loop(g_display),
                        "/var/jb/tmp/iosc-wm.sock") != 0)
        fprintf(stderr, "iosc: wm control socket failed -> no raise-by-app_id\n");
    else
        fprintf(stderr, "iosc: wm control socket up at /var/jb/tmp/iosc-wm.sock\n");

    fprintf(stderr, "iosc: listening on WAYLAND_DISPLAY=%s (XDG_RUNTIME_DIR=%s)\n",
            sock_name, getenv("XDG_RUNTIME_DIR") ? getenv("XDG_RUNTIME_DIR") : "(unset)");
    fprintf(stderr, "iosc: globals: wl_compositor v4, wl_shm, xdg_wm_base v4, "
                    "iosc_iosurface v1, wl_output v4, zxdg_output_manager_v1 v3, "
                    "wl_seat v5, wl_subcompositor v1, "
                    "wl_data_device_manager v3, wp_viewporter v1, "
                    "wp_fractional_scale_manager_v1 v1, wp_presentation v1, "
                    "zxdg_decoration_manager_v1 v1, xdg_activation_v1 v1, "
                    "zwp_text_input_manager_v3 v1, zwp_input_method_manager_v2 v1, "
                    "zwp_virtual_keyboard_manager_v1 v1, zwlr_layer_shell_v1 v4, "
                    "zwlr_foreign_toplevel_manager_v1 v3, "
                    "zwp_pointer_constraints_v1 v1, zwp_relative_pointer_manager_v1 v1, "
                    "zwp_primary_selection_device_manager_v1 v1, "
                    "ext_idle_notifier_v1 v1, zwp_idle_inhibit_manager_v1 v1, "
                    "wp_single_pixel_buffer_manager_v1 v1, wp_cursor_shape_manager_v1 v1, "
                    "zwlr_screencopy_manager_v1 v3\n");

    /* 3) Run the event loop forever. */
    wl_display_run(g_display);

    wl_display_destroy(g_display);
    xios_server_stop();
    return 0;
}

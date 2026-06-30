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
#include "iosc-iosurface-server-protocol.h"

#include "xios_surface.h"
#include "iosc_gl.h"
#include "iosc_input.h"

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

struct iosc_surface {
    struct wl_resource *resource;        /* wl_surface */
    struct wl_resource *pending_buffer;  /* last wl_surface.attach (may be NULL) */
    int                 buffer_attached; /* attach was called this cycle */
    struct wl_resource *current_buffer;  /* committed buffer, retained for recompositing */
    struct wl_listener  buffer_destroy;  /* fires if the client destroys current_buffer */
    int                 buffer_listener_active;
    int                 sw, sh;          /* current buffer source dimensions */
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
    int                 toplevel_resizing;
    struct iosc_subsurface *subsurface;
    struct iosc_viewport *viewport;
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
enum iosc_interactive_op { IOSC_INTERACTIVE_NONE, IOSC_INTERACTIVE_MOVE, IOSC_INTERACTIVE_RESIZE };
static enum iosc_interactive_op g_interactive_op;
static struct iosc_surface *g_interactive_surface;
static int g_interactive_px, g_interactive_py;
static int g_interactive_dx, g_interactive_dy;
static int g_interactive_w, g_interactive_h;
static uint32_t g_interactive_edges;
static uint64_t g_presentation_seq;
static void keyboard_set_focus(struct iosc_surface *s);
static void surface_raise(struct iosc_surface *s);

static int clampi(int v, int lo, int hi)
{
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
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
        wl_shm_buffer_begin_access(shm);
        iosc_gl_draw_shm(wl_shm_buffer_get_data(shm),
                         wl_shm_buffer_get_width(shm), wl_shm_buffer_get_height(shm),
                         wl_shm_buffer_get_stride(shm), sx, sy, src_w, src_h,
                         dxp, dyp, dwp, dhp);
        wl_shm_buffer_end_access(shm);
    } else if (wl_resource_instance_of(buf, &wl_buffer_interface, &iosurface_buffer_impl)) {
        struct iosc_iosurface_buffer *ib = wl_resource_get_user_data(buf);
        if (ib && ib->surface)
            iosc_gl_draw_iosurface(ib->surface, ib->w, ib->h, sx, sy, src_w, src_h,
                                   dxp, dyp, dwp, dhp);
    }
}

static void composite_one(struct iosc_surface *s)
{
    composite_surface_at(s, s->dx, s->dy);
}

static void composite_cursor(void)
{
    if (!g_cursor_visible || !g_cursor_surface || !g_cursor_surface->current_buffer) return;
    composite_surface_at(g_cursor_surface,
                         g_cursor_x - g_cursor_hot_x,
                         g_cursor_y - g_cursor_hot_y);
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

/* Recomposite ALL mapped surfaces back-to-front onto the output, on the GPU. */
static void recomposite_all(void)
{
    if (iosc_gl_ok()) {
        iosc_gl_begin();   /* clears the output to black (desktop background) */
        for (int i = 0; i < g_nmapped; i++)
            composite_one(g_mapped[i]);
        composite_cursor();
        uint32_t center = iosc_gl_end();
        xios_notify_dirty();
        /* Validation: read each window's EXPOSED top-left corner (a lower window's
         * center is occluded by the one cascaded over it), proving every window is
         * present at its placement; `center` shows the top window wins the overlap. */
        fprintf(stderr, "iosc: recomposited %d surface(s) on GPU:", g_nmapped);
        for (int i = 0; i < g_nmapped; i++) {
            struct iosc_surface *s = g_mapped[i];
            int os = output_scale();
            uint32_t px = iosc_gl_read_at((s->dx + 30) * os, (s->dy + 30) * os);
            fprintf(stderr, " [w%d @%d,%d corner=0x%08x]", i, s->dx, s->dy, px);
        }
        fprintf(stderr, " overlap-center=0x%08x\n", center);
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
    if (buf && !s->buffer_listener_active) {
        s->buffer_destroy.notify = on_buffer_destroyed;
        wl_resource_add_destroy_listener(buf, &s->buffer_destroy);
        s->buffer_listener_active = 1;
    }
}

/* Add/remove a surface from the z-order list (cascade placement on map). */
static void surface_map(struct iosc_surface *s)
{
    if (s->mapped || g_nmapped >= IOSC_MAX_SURFACES) return;
    if (s->parent) {
        surface_place_child(s);
    } else {
        s->dx = 40 + g_nmapped * 70;   /* cascade so windows visibly overlap */
        s->dy = 40 + g_nmapped * 70;
    }
    g_mapped[g_nmapped++] = s;
    s->mapped = 1;
    fprintf(stderr, "iosc: surface mapped role=%d at (%d,%d); %d window(s)\n",
            s->role, s->dx, s->dy, g_nmapped);
    if (s->role == IOSC_ROLE_TOPLEVEL || s->role == IOSC_ROLE_POPUP)
        keyboard_set_focus(s);         /* newest shell surface takes keyboard focus */
}
static void surface_unmap(struct iosc_surface *s)
{
    if (!s->mapped) return;
    for (int i = 0; i < g_nmapped; i++)
        if (g_mapped[i] == s) {
            for (int j = i; j < g_nmapped - 1; j++) g_mapped[j] = g_mapped[j + 1];
            g_nmapped--;
            break;
        }
    s->mapped = 0;
    /* Drop focus that pointed at us; hand it to the new top window (if any). */
    if (g_ptr_focus == s) g_ptr_focus = NULL;
    if (g_kbd_focus == s) {
        g_kbd_focus = NULL;            /* leave already implied by destroy */
        keyboard_set_focus(g_nmapped > 0 ? g_mapped[g_nmapped - 1] : NULL);
    }
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
{ (void)c; (void)r; (void)x; (void)y; (void)w; (void)h; }

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
            surface_set_buffer(s, buf, sw, sh, 1);
            if (!s->mapped &&
                (s->role == IOSC_ROLE_TOPLEVEL ||
                 s->role == IOSC_ROLE_POPUP ||
                 s->role == IOSC_ROLE_SUBSURFACE))
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
{ (void)c; (void)r; (void)x; (void)y; (void)w; (void)h; }

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
    int fill = s->toplevel_maximized || s->toplevel_fullscreen;
    if (fill) {
        s->dx = 0;
        s->dy = 0;
        toplevel_send_configure(s, output_logical_width(), output_logical_height());
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
    if (g_interactive_op == IOSC_INTERACTIVE_MOVE) {
        int w = 0, h = 0;
        surface_display_size(s, &w, &h);
        int max_x = output_logical_width() - (w > 0 ? w : 1);
        int max_y = output_logical_height() - (h > 0 ? h : 1);
        if (max_x < 0) max_x = 0;
        if (max_y < 0) max_y = 0;
        s->dx = clampi(g_interactive_dx + dx, 0, max_x);
        s->dy = clampi(g_interactive_dy + dy, 0, max_y);
        recomposite_all();
        return;
    }
    int nx = g_interactive_dx, ny = g_interactive_dy;
    int nw = g_interactive_w, nh = g_interactive_h;
    if (resize_has_left(g_interactive_edges)) { nx = g_interactive_dx + dx; nw = g_interactive_w - dx; }
    if (resize_has_right(g_interactive_edges)) nw = g_interactive_w + dx;
    if (resize_has_top(g_interactive_edges)) { ny = g_interactive_dy + dy; nh = g_interactive_h - dy; }
    if (resize_has_bottom(g_interactive_edges)) nh = g_interactive_h + dy;
    nw = clampi(nw, 80, output_logical_width());
    nh = clampi(nh, 60, output_logical_height());
    nx = clampi(nx, 0, output_logical_width() - nw);
    ny = clampi(ny, 0, output_logical_height() - nh);
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
static void xt_set_title(struct wl_client *c, struct wl_resource *r, const char *t){ (void)c;(void)r; fprintf(stderr, "iosc: toplevel title=\"%s\"\n", t ? t : ""); }
static void xt_set_app_id(struct wl_client *c, struct wl_resource *r, const char *a){ (void)c;(void)r; fprintf(stderr, "iosc: toplevel app_id=\"%s\"\n", a ? a : ""); }
static void xt_show_window_menu(struct wl_client *c, struct wl_resource *r, struct wl_resource *seat, uint32_t serial, int32_t x, int32_t y){ (void)c;(void)r;(void)seat;(void)serial;(void)x;(void)y; }
static void xt_move(struct wl_client *c, struct wl_resource *r, struct wl_resource *seat, uint32_t serial)
{ (void)c; (void)seat; (void)serial; interactive_begin(wl_resource_get_user_data(r), IOSC_INTERACTIVE_MOVE, 0); }
static void xt_resize(struct wl_client *c, struct wl_resource *r, struct wl_resource *seat, uint32_t serial, uint32_t edges)
{ (void)c; (void)seat; (void)serial; interactive_begin(wl_resource_get_user_data(r), IOSC_INTERACTIVE_RESIZE, edges); }
static void xt_set_max_size(struct wl_client *c, struct wl_resource *r, int32_t w, int32_t h){ (void)c;(void)r;(void)w;(void)h; }
static void xt_set_min_size(struct wl_client *c, struct wl_resource *r, int32_t w, int32_t h){ (void)c;(void)r;(void)w;(void)h; }
static void xt_set_maximized(struct wl_client *c, struct wl_resource *r)
{ (void)c; struct iosc_surface *s = wl_resource_get_user_data(r);
  if (s) { s->toplevel_maximized = 1; toplevel_reconfigure_state(s); } }
static void xt_unset_maximized(struct wl_client *c, struct wl_resource *r)
{ (void)c; struct iosc_surface *s = wl_resource_get_user_data(r);
  if (s) { s->toplevel_maximized = 0; toplevel_reconfigure_state(s); } }
static void xt_set_fullscreen(struct wl_client *c, struct wl_resource *r, struct wl_resource *out)
{ (void)c; (void)out; struct iosc_surface *s = wl_resource_get_user_data(r);
  if (s) { s->toplevel_fullscreen = 1; toplevel_reconfigure_state(s); } }
static void xt_unset_fullscreen(struct wl_client *c, struct wl_resource *r)
{ (void)c; struct iosc_surface *s = wl_resource_get_user_data(r);
  if (s) { s->toplevel_fullscreen = 0; toplevel_reconfigure_state(s); } }
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
    for (int i = g_nmapped - 1; i >= 0; i--) {
        struct iosc_surface *s = g_mapped[i];
        int w = 0, h = 0;
        surface_display_size(s, &w, &h);
        if (x >= s->dx && x < s->dx + w && y >= s->dy && y < s->dy + h)
            return s;
    }
    return NULL;
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
    if (g_kbd_focus == s) return;
    kbd_send_leave(g_kbd_focus);
    g_kbd_focus = s;
    g_kbd_mods = 0;
    if (s) {
        kbd_send_enter(s);
        int nk = 0;
        struct wl_client *nc = wl_resource_get_client(s->resource);
        for (int i = 0; i < g_nkbd; i++) if (wl_resource_get_client(g_kbd[i]) == nc) nk++;
        fprintf(stderr, "iosc: keyboard focus -> surface %p (%d kbd resource(s))\n",
                (void *)s, nk);
        clipboard_selection_send_to_client(nc);
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

/* A key "tap": one X keysym + the app's armed ctrl/alt/shift. Resolve to an evdev
 * keycode (+ whether Shift is needed for the symbol) and bracket the key with the
 * right modifier mask, then press + release. */
static void handle_key(uint32_t keysym, uint32_t appmods)
{
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
    keyboard_send_mods(mask);
    uint32_t s1 = wl_display_next_serial(g_display);
    for (int i = 0; i < g_nkbd; i++)
        if (wl_resource_get_client(g_kbd[i]) == fc)
            wl_keyboard_send_key(g_kbd[i], s1, t, evdev, WL_KEYBOARD_KEY_STATE_PRESSED);
    uint32_t s2 = wl_display_next_serial(g_display);
    for (int i = 0; i < g_nkbd; i++)
        if (wl_resource_get_client(g_kbd[i]) == fc)
            wl_keyboard_send_key(g_kbd[i], s2, t, evdev, WL_KEYBOARD_KEY_STATE_RELEASED);
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
    int moved = (x != g_cursor_x || y != g_cursor_y);
    g_cursor_x = x;
    g_cursor_y = y;
    if (g_interactive_op != IOSC_INTERACTIVE_NONE) {
        interactive_update(x, y);
        return;
    }
    struct iosc_surface *hit = surface_at(x, y);
    uint32_t t = now_ms();
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
    if (g_cursor_visible && moved) recomposite_all();
}

/* Raise a surface to the top of the z-order (clicked window comes forward). */
static void surface_raise(struct iosc_surface *s)
{
    int idx = -1;
    for (int i = 0; i < g_nmapped; i++) if (g_mapped[i] == s) { idx = i; break; }
    if (idx < 0 || idx == g_nmapped - 1) return;
    for (int i = idx; i < g_nmapped - 1; i++) g_mapped[i] = g_mapped[i + 1];
    g_mapped[g_nmapped - 1] = s;
}

static void handle_button(int btn, int down)
{
    (void)btn;
    if (!down && g_interactive_op != IOSC_INTERACTIVE_NONE) {
        interactive_end();
        return;
    }
    if (down && g_ptr_focus) {
        int was_top = (g_nmapped > 0 && g_mapped[g_nmapped - 1] == g_ptr_focus);
        surface_raise(g_ptr_focus);
        keyboard_set_focus(g_ptr_focus);
        if (!was_top) recomposite_all();   /* show the raised window on top */
    }
    if (!g_ptr_focus) return;
    struct wl_client *fc = wl_resource_get_client(g_ptr_focus->resource);
    uint32_t serial = wl_display_next_serial(g_display);
    uint32_t t = now_ms();
    for (int i = 0; i < g_nptr; i++)
        if (wl_resource_get_client(g_ptr[i]) == fc)
            wl_pointer_send_button(g_ptr[i], serial, t, BTN_LEFT,
                                   down ? WL_POINTER_BUTTON_STATE_PRESSED
                                        : WL_POINTER_BUTTON_STATE_RELEASED);
    pointer_frame_client(fc);
}

/* ---- wl_pointer / wl_keyboard / wl_touch resources ------------------------ */

static void pointer_set_cursor(struct wl_client *c, struct wl_resource *r, uint32_t serial,
                               struct wl_resource *surf, int32_t hx, int32_t hy)
{ (void)r; (void)serial;
    if (g_ptr_focus && wl_resource_get_client(g_ptr_focus->resource) != c)
        return;
    g_cursor_surface = surf ? wl_resource_get_user_data(surf) : NULL;
    g_cursor_hot_x = hx;
    g_cursor_hot_y = hy;
    g_cursor_visible = g_cursor_surface != NULL;
    recomposite_all();
}
static const struct wl_pointer_interface pointer_impl = { .set_cursor = pointer_set_cursor, .release = input_release };
static const struct wl_keyboard_interface keyboard_impl = { .release = input_release };
static const struct wl_touch_interface touch_impl = { .release = input_release };

static void pointer_res_destroy(struct wl_resource *r){ reslist_remove(g_ptr, &g_nptr, r); }
static void keyboard_res_destroy(struct wl_resource *r){ reslist_remove(g_kbd, &g_nkbd, r); }

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
{ struct wl_resource *t = wl_resource_create(c, &wl_touch_interface, wl_resource_get_version(r), id);
  if (t) wl_resource_set_implementation(t, &touch_impl, NULL, NULL); }
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
#define IOSC_MAX_CLIP_MIMES 8

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
    if (!s || !is_clip_mime(m) || s->nmimes >= IOSC_MAX_CLIP_MIMES) return;
    for (int i = 0; i < s->nmimes; i++)
        if (!strcmp(s->mimes[i], m)) return;
    char *copy = strdup(m);
    if (!copy) { wl_client_post_no_memory(c); return; }
    s->mimes[s->nmimes++] = copy;
}

static void data_source_destroy(struct wl_client *c, struct wl_resource *r)
{ (void)c; wl_resource_destroy(r); }
static void data_source_set_actions(struct wl_client *c, struct wl_resource *r, uint32_t a)
{ (void)c; (void)r; (void)a; }

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

static void data_device_start_drag(struct wl_client *c, struct wl_resource *r, struct wl_resource *src,
                                   struct wl_resource *org, struct wl_resource *icon, uint32_t serial)
{ (void)c; (void)r; (void)src; (void)org; (void)icon; (void)serial; }

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

static int clipboard_socket_start(struct wl_event_loop *loop, const char *path)
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
    wl_event_loop_add_fd(loop, fd, WL_EVENT_READABLE, clip_listen_readable, loop);
    return 0;
}

/* ---- input transport: a tiny AF_UNIX socket the Xios app writes events to ---
 * The app forwards UIKit touch + the iOS keyboard as fixed 24-byte messages. The
 * listen + client fds live on the wl_display event loop, so every wl_* dispatch
 * driven by input runs on the compositor's own thread (no locking needed). */

#define IOSC_IN_MOTION 1
#define IOSC_IN_BUTTON 2
#define IOSC_IN_KEY    3
struct iosc_in_msg {            /* native-endian; app + iosc are both arm64 */
    uint32_t type;
    int32_t  x, y;             /* output px (motion / button) */
    uint32_t code;             /* button: 1/2/3 ; key: X keysym */
    uint32_t state;            /* button: 1=down 0=up */
    uint32_t mods;             /* key: bit0 shift, bit1 ctrl, bit2 alt */
};
struct iosc_in_client {
    int fd; struct wl_event_source *src;
    uint8_t buf[sizeof(struct iosc_in_msg)]; int have;
};

static void in_dispatch(const struct iosc_in_msg *m)
{
    int x = physical_to_logical(m->x);
    int y = physical_to_logical(m->y);
    switch (m->type) {
        case IOSC_IN_MOTION: handle_motion(x, y); break;
        case IOSC_IN_BUTTON: handle_motion(x, y);
                             handle_button((int)m->code, (int)m->state); break;
        case IOSC_IN_KEY:    handle_key(m->code, m->mods); break;
    }
    wl_display_flush_clients(g_display);   /* push the events out immediately */
}

static int in_client_readable(int fd, uint32_t mask, void *data)
{
    struct iosc_in_client *c = data;
    if (mask & (WL_EVENT_HANGUP | WL_EVENT_ERROR)) goto drop;
    for (;;) {
        ssize_t r = read(fd, c->buf + c->have, sizeof(c->buf) - (size_t)c->have);
        if (r > 0) {
            c->have += (int)r;
            if (c->have == (int)sizeof(c->buf)) {
                struct iosc_in_msg m; memcpy(&m, c->buf, sizeof(m)); c->have = 0;
                in_dispatch(&m);
            }
            continue;
        }
        if (r == 0) goto drop;                            /* peer closed */
        if (errno == EAGAIN || errno == EWOULDBLOCK) break;
        if (errno == EINTR) continue;
        goto drop;
    }
    return 0;
drop:
    wl_event_source_remove(c->src);
    close(c->fd);
    free(c);
    fprintf(stderr, "iosc: input client disconnected\n");
    return 0;
}

static int in_listen_readable(int fd, uint32_t mask, void *data)
{
    (void)mask;
    struct wl_event_loop *loop = data;
    int cfd = accept(fd, NULL, NULL);
    if (cfd < 0) return 0;
    fcntl(cfd, F_SETFL, fcntl(cfd, F_GETFL, 0) | O_NONBLOCK);
    struct iosc_in_client *c = calloc(1, sizeof(*c));
    if (!c) { close(cfd); return 0; }
    c->fd = cfd;
    c->src = wl_event_loop_add_fd(loop, cfd, WL_EVENT_READABLE, in_client_readable, c);
    fprintf(stderr, "iosc: input client connected (fd=%d)\n", cfd);
    return 0;
}

static int input_socket_start(struct wl_event_loop *loop, const char *path)
{
    unlink(path);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    struct sockaddr_un addr; memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, path, sizeof(addr.sun_path) - 1);
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) { close(fd); return -1; }
    if (listen(fd, 4) < 0) { close(fd); return -1; }
    chmod(path, 0777);   /* the Xios app runs as mobile and must connect */
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK);
    wl_event_loop_add_fd(loop, fd, WL_EVENT_READABLE, in_listen_readable, loop);
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

    fprintf(stderr, "iosc: listening on WAYLAND_DISPLAY=%s (XDG_RUNTIME_DIR=%s)\n",
            sock_name, getenv("XDG_RUNTIME_DIR") ? getenv("XDG_RUNTIME_DIR") : "(unset)");
    fprintf(stderr, "iosc: globals: wl_compositor v4, wl_shm, xdg_wm_base v4, "
                    "iosc_iosurface v1, wl_output v4, zxdg_output_manager_v1 v3, "
                    "wl_seat v5, wl_subcompositor v1, "
                    "wl_data_device_manager v3, wp_viewporter v1, "
                    "wp_fractional_scale_manager_v1 v1, wp_presentation v1, "
                    "zxdg_decoration_manager_v1 v1, xdg_activation_v1 v1\n");

    /* 3) Run the event loop forever. */
    wl_display_run(g_display);

    wl_display_destroy(g_display);
    xios_server_stop();
    return 0;
}

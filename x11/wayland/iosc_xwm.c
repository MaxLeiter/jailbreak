/* iosc_xwm.c — rootless Xwayland X window manager for the iosc compositor.
 *
 * Clean-room MIT (see iosc_xwm.h for the spec provenance). Self-contained: this
 * file talks X11 via libxcb and Wayland via libwayland-server + the generated
 * xwayland-shell-v1 server protocol, and reaches the compositor only through the
 * glue contract declared in iosc_xwm.h. It does NOT include iosc.c internals.
 *
 * Responsibilities implemented here (MVP):
 *   - Spawn Xwayland `-rootless -wm <fd> -displayfd <fd> -terminate
 *     -extension MIT-SHM` via socketpair + pipe + posix_spawn (absolute /var/jb
 *     paths); learn the X display number from the event loop (never by blocking:
 *     Xwayland needs the compositor's loop to finish its own init first), export
 *     DISPLAY for child X clients and publish it through the glue.
 *   - xcb_connect_to_fd on the wm socket; register the xcb fd on the compositor
 *     wl_event_loop; strict xcb_flush discipline after every dispatch.
 *   - Intern atoms; own WM_S0 (manager selection) on a dedicated window; select
 *     SubstructureRedirect|SubstructureNotify|PropertyChange on the root; publish
 *     _NET_SUPPORTED and _NET_SUPPORTING_WM_CHECK.
 *   - Advertise xwayland_shell_v1 + xwayland_surface_v1 as a wl_global, bindable
 *     ONLY by the Xwayland client (pid match recorded at spawn).
 *   - set_serial (double-buffered) + commit-time adoption, matched against the
 *     X11 WL_SURFACE_SERIAL client message. Both arrival orders handled.
 *   - Core WM event loop: MapRequest / ConfigureRequest / MapNotify /
 *     UnmapNotify / DestroyNotify / PropertyNotify / ClientMessage; override-
 *     redirect -> popup; title from _NET_WM_NAME/WM_NAME; WM_DELETE_WINDOW close;
 *     X focus bridge (SetInputFocus + WM_TAKE_FOCUS + _NET_ACTIVE_WINDOW).
 *
 * Deferred (see TODO(polish) markers): WM_NORMAL_HINTS min/max sizing,
 * _NET_WM_STATE (maximize/fullscreen), X11 clipboard/primary bridge, X cursor
 * theme, _NET_WM_MOVERESIZE, and per-window damage/scale plumbing.
 */

#include <errno.h>
#include <fcntl.h>
#include <spawn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/un.h>
#include <sys/wait.h>

#include <wayland-server-core.h>

#include <sys/uio.h>

#include <xcb/xcb.h>
#include <xcb/xcbext.h>
#include <xcb/xproto.h>

#include "iosc_xwm.h"
#include "xwayland-shell-v1-server-protocol.h"

extern char **environ;

/* ------------------------------------------------------------------------- *
 * Config (absolute rootless paths; overridable via env for dev).
 * ------------------------------------------------------------------------- */
#define XWM_DEFAULT_XWAYLAND "/var/jb/usr/bin/Xwayland"
#define XWM_DEFAULT_WAYLAND_DISPLAY "wayland-0"

static const char *xwm_xwayland_bin(void)
{
    const char *e = getenv("IOSC_XWAYLAND_BIN");
    return (e && *e) ? e : XWM_DEFAULT_XWAYLAND;
}
static const char *xwm_wayland_display(void)
{
    const char *e = getenv("WAYLAND_DISPLAY");
    return (e && *e) ? e : XWM_DEFAULT_WAYLAND_DISPLAY;
}
static int xwm_debug(void)
{
    static int v = -1;
    if (v < 0) { const char *e = getenv("IOSC_XWM_DEBUG"); v = (e && *e && *e != '0'); }
    return v;
}
#define XWM_LOG(...)  do { fprintf(stderr, "iosc-xwm: " __VA_ARGS__); } while (0)
#define XWM_DBG(...)  do { if (xwm_debug()) fprintf(stderr, "iosc-xwm: " __VA_ARGS__); } while (0)

/* ------------------------------------------------------------------------- *
 * Atoms.
 * ------------------------------------------------------------------------- */
enum {
    ATOM_WM_PROTOCOLS,
    ATOM_WM_DELETE_WINDOW,
    ATOM_WM_TAKE_FOCUS,
    ATOM_WM_STATE,
    ATOM_WM_NAME,
    ATOM_WM_NORMAL_HINTS,      /* interned for TODO(polish) sizing */
    ATOM_WM_CLASS,
    ATOM_WM_CHANGE_STATE,
    ATOM_UTF8_STRING,
    ATOM_NET_SUPPORTED,
    ATOM_NET_SUPPORTING_WM_CHECK,
    ATOM_NET_WM_NAME,
    ATOM_NET_ACTIVE_WINDOW,
    ATOM_NET_WM_STATE,
    ATOM_NET_WM_WINDOW_TYPE,
    ATOM_NET_WM_WINDOW_TYPE_NORMAL,
    ATOM_NET_WM_WINDOW_TYPE_DIALOG,
    ATOM_NET_WM_WINDOW_TYPE_UTILITY,
    ATOM_NET_WM_WINDOW_TYPE_TOOLTIP,
    ATOM_NET_WM_WINDOW_TYPE_MENU,
    ATOM_NET_WM_WINDOW_TYPE_DROPDOWN_MENU,
    ATOM_NET_WM_WINDOW_TYPE_POPUP_MENU,
    ATOM_NET_WM_WINDOW_TYPE_COMBO,
    ATOM_NET_WM_WINDOW_TYPE_DND,
    ATOM_NET_CLIENT_LIST,
    ATOM_WL_SURFACE_SERIAL,
    ATOM_WM_S0,
    ATOM__COUNT
};

static const char *const k_atom_names[ATOM__COUNT] = {
    [ATOM_WM_PROTOCOLS]                 = "WM_PROTOCOLS",
    [ATOM_WM_DELETE_WINDOW]             = "WM_DELETE_WINDOW",
    [ATOM_WM_TAKE_FOCUS]                = "WM_TAKE_FOCUS",
    [ATOM_WM_STATE]                     = "WM_STATE",
    [ATOM_WM_NAME]                      = "WM_NAME",
    [ATOM_WM_NORMAL_HINTS]              = "WM_NORMAL_HINTS",
    [ATOM_WM_CLASS]                     = "WM_CLASS",
    [ATOM_WM_CHANGE_STATE]              = "WM_CHANGE_STATE",
    [ATOM_UTF8_STRING]                  = "UTF8_STRING",
    [ATOM_NET_SUPPORTED]                = "_NET_SUPPORTED",
    [ATOM_NET_SUPPORTING_WM_CHECK]      = "_NET_SUPPORTING_WM_CHECK",
    [ATOM_NET_WM_NAME]                  = "_NET_WM_NAME",
    [ATOM_NET_ACTIVE_WINDOW]            = "_NET_ACTIVE_WINDOW",
    [ATOM_NET_WM_STATE]                 = "_NET_WM_STATE",
    [ATOM_NET_WM_WINDOW_TYPE]           = "_NET_WM_WINDOW_TYPE",
    [ATOM_NET_WM_WINDOW_TYPE_NORMAL]    = "_NET_WM_WINDOW_TYPE_NORMAL",
    [ATOM_NET_WM_WINDOW_TYPE_DIALOG]    = "_NET_WM_WINDOW_TYPE_DIALOG",
    [ATOM_NET_WM_WINDOW_TYPE_UTILITY]   = "_NET_WM_WINDOW_TYPE_UTILITY",
    [ATOM_NET_WM_WINDOW_TYPE_TOOLTIP]   = "_NET_WM_WINDOW_TYPE_TOOLTIP",
    [ATOM_NET_WM_WINDOW_TYPE_MENU]      = "_NET_WM_WINDOW_TYPE_MENU",
    [ATOM_NET_WM_WINDOW_TYPE_DROPDOWN_MENU] = "_NET_WM_WINDOW_TYPE_DROPDOWN_MENU",
    [ATOM_NET_WM_WINDOW_TYPE_POPUP_MENU]    = "_NET_WM_WINDOW_TYPE_POPUP_MENU",
    [ATOM_NET_WM_WINDOW_TYPE_COMBO]     = "_NET_WM_WINDOW_TYPE_COMBO",
    [ATOM_NET_WM_WINDOW_TYPE_DND]       = "_NET_WM_WINDOW_TYPE_DND",
    [ATOM_NET_CLIENT_LIST]              = "_NET_CLIENT_LIST",
    [ATOM_WL_SURFACE_SERIAL]            = "WL_SURFACE_SERIAL",
    [ATOM_WM_S0]                        = "WM_S0",
};

/* ------------------------------------------------------------------------- *
 * Per-X-window bookkeeping.
 * ------------------------------------------------------------------------- */
struct xwm_window {
    struct wl_list      link;              /* xwm.windows */
    xcb_window_t        xwindow;           /* the X11 window id */
    uint64_t            serial;            /* WL_SURFACE_SERIAL (0 = not seen) */
    struct wl_resource *surface_res;       /* associated wl_surface, or NULL */
    struct wl_resource *xwl_surface;       /* xwayland_surface_v1, or NULL */
    int                 override_redirect;
    int                 map_requested;     /* saw MapRequest (client wants it up) */
    int                 adopted;           /* handed to iosc via adopt hook */
    int                 supports_delete;   /* WM_DELETE_WINDOW in WM_PROTOCOLS */
    int                 supports_take_focus;
    int32_t             x, y, w, h;
    uint8_t             depth;             /* visual depth from GetGeometry (0 = unknown) */
    char                title[256];
    char                wm_class[128];
};

/* xwayland_surface_v1 role object (double-buffered set_serial). */
struct xwm_xwl_surface {
    struct wl_list      link;              /* xwm.xwl_surfaces */
    struct wl_resource *resource;          /* xwayland_surface_v1 */
    struct wl_resource *surface_res;       /* the wl_surface it wraps */
    uint64_t            pending_serial;    /* set_serial, not yet committed */
    int                 have_pending;      /* set_serial called since last commit */
    uint64_t            serial;            /* committed serial (0 = none) */
    int                 committed;         /* commit applied the serial once */
};

/* ------------------------------------------------------------------------- *
 * Module state (single instance).
 * ------------------------------------------------------------------------- */
static struct {
    int                    running;
    struct wl_display     *display;
    struct wl_event_loop  *loop;

    pid_t                  xwayland_pid;
    struct wl_client      *xwayland_client;   /* recorded on first pid-matched bind */
    int                    display_number;    /* :N, -1 until known */
    int                    display_published; /* iosc_xwm_display_changed(N) sent */

    /* Startup handshake, driven from the event loop (see iosc_xwm_start). */
    int                    wm_fd;             /* XWM end of the -wm socketpair, -1 once xcb owns it */
    int                    display_fd;        /* read end of -displayfd, -1 once read */
    struct wl_event_source *display_source;
    char                   display_buf[32];
    size_t                 display_len;

    xcb_connection_t      *conn;
    xcb_screen_t          *screen;
    xcb_window_t           root;
    xcb_window_t           wm_window;         /* selection-owner / _NET check window */
    struct wl_event_source *xcb_source;

    struct wl_global      *shell_global;

    xcb_atom_t             atoms[ATOM__COUNT];

    struct wl_list         windows;           /* struct xwm_window */
    struct wl_list         xwl_surfaces;       /* struct xwm_xwl_surface */
} xwm;

/* ------------------------------------------------------------------------- *
 * Small lookups.
 * ------------------------------------------------------------------------- */
static struct xwm_window *window_by_xid(xcb_window_t w)
{
    struct xwm_window *it;
    wl_list_for_each(it, &xwm.windows, link)
        if (it->xwindow == w) return it;
    return NULL;
}
static struct xwm_window *window_by_serial(uint64_t serial)
{
    if (!serial) return NULL;
    struct xwm_window *it;
    wl_list_for_each(it, &xwm.windows, link)
        if (it->serial == serial) return it;
    return NULL;
}
static struct xwm_window *window_by_surface(struct wl_resource *res)
{
    if (!res) return NULL;
    struct xwm_window *it;
    wl_list_for_each(it, &xwm.windows, link)
        if (it->surface_res == res) return it;
    return NULL;
}
static struct xwm_xwl_surface *xwl_by_surface(struct wl_resource *res)
{
    if (!res) return NULL;
    struct xwm_xwl_surface *it;
    wl_list_for_each(it, &xwm.xwl_surfaces, link)
        if (it->surface_res == res) return it;
    return NULL;
}

/* ------------------------------------------------------------------------- *
 * Adoption: bring an X window and its wl_surface together once both the serial
 * (from WL_SURFACE_SERIAL) and the map request are known. Idempotent.
 * ------------------------------------------------------------------------- */
static void xwm_read_title(struct xwm_window *win);

static void try_adopt(struct xwm_window *win)
{
    if (!win || win->adopted) return;
    if (!win->surface_res) return;             /* serial not matched yet */
    if (!win->override_redirect && !win->map_requested) return; /* not up yet */

    /* Pull latest title just before handing off (cheap, one round-trip). */
    xwm_read_title(win);
    /* Override-redirect windows never send a MapRequest, so their depth is
     * still unknown here. */
    if (!win->depth) {
        xcb_get_geometry_reply_t *g =
            xcb_get_geometry_reply(xwm.conn, xcb_get_geometry(xwm.conn, win->xwindow), NULL);
        if (g) { win->depth = g->depth; free(g); }
    }

    struct iosc_xwm_window_info info = {
        .xwm_window        = (uint32_t)win->xwindow,
        .override_redirect = win->override_redirect,
        .x = win->x, .y = win->y,
        .width  = win->w > 0 ? win->w : 1,
        .height = win->h > 0 ? win->h : 1,
        .title    = win->title,
        .wm_class = win->wm_class,
        .has_alpha = win->depth == 32,
        .xwm      = win,
    };
    if (iosc_xwm_adopt_surface(win->surface_res, &info) == 0) {
        win->adopted = 1;
        XWM_DBG("adopted xwindow=0x%x %s \"%s\" %dx%d depth=%u\n",
                win->xwindow, win->override_redirect ? "(override-redirect)" : "",
                win->title, info.width, info.height, win->depth);
    } else {
        XWM_LOG("adopt refused for xwindow=0x%x\n", win->xwindow);
    }
}

/* Bind the serial coming from either timeline to the window and try to adopt.
 * Called from the X side (WL_SURFACE_SERIAL client message) and the Wayland
 * side (commit applying set_serial). */
static void bind_serial_to_window(struct xwm_window *win, uint64_t serial)
{
    if (!win || !serial) return;
    win->serial = serial;
    /* Is there already a committed wl_surface waiting on this serial? */
    struct xwm_xwl_surface *xs;
    wl_list_for_each(xs, &xwm.xwl_surfaces, link) {
        if (xs->committed && xs->serial == serial && xs->surface_res) {
            win->surface_res = xs->surface_res;
            break;
        }
    }
    try_adopt(win);
}

/* ------------------------------------------------------------------------- *
 * xwayland_surface_v1 implementation.
 * ------------------------------------------------------------------------- */
static void xwl_surface_apply_commit(struct xwm_xwl_surface *xs)
{
    if (!xs->have_pending) return;
    if (xs->committed) return;                 /* already_associated is caught in set_serial path */
    xs->serial = xs->pending_serial;
    xs->have_pending = 0;
    xs->committed = 1;
    /* Match a window that already announced this serial from the X side. */
    struct xwm_window *win = window_by_serial(xs->serial);
    if (win) {
        win->surface_res = xs->surface_res;
        try_adopt(win);
    } else {
        XWM_DBG("commit: surface %p serial=%llu pending X window\n",
                (void *)xs->surface_res, (unsigned long long)xs->serial);
    }
}

static void xwl_surface_set_serial(struct wl_client *client, struct wl_resource *resource,
                                   uint32_t serial_lo, uint32_t serial_hi)
{
    (void)client;
    struct xwm_xwl_surface *xs = wl_resource_get_user_data(resource);
    if (!xs) return;
    uint64_t serial = ((uint64_t)serial_hi << 32) | (uint64_t)serial_lo;
    if (serial == 0) {
        wl_resource_post_error(resource, XWAYLAND_SURFACE_V1_ERROR_INVALID_SERIAL,
                               "serial must be non-zero");
        return;
    }
    if (xs->committed) {
        wl_resource_post_error(resource, XWAYLAND_SURFACE_V1_ERROR_ALREADY_ASSOCIATED,
                               "wl_surface already associated");
        return;
    }
    xs->pending_serial = serial;
    xs->have_pending = 1;
    XWM_DBG("set_serial %llu on surface %p (pending commit)\n",
            (unsigned long long)serial, (void *)xs->surface_res);
}

static void xwl_surface_destroy_req(struct wl_client *client, struct wl_resource *resource)
{
    (void)client;
    wl_resource_destroy(resource);
}

static const struct xwayland_surface_v1_interface xwl_surface_impl = {
    .set_serial = xwl_surface_set_serial,
    .destroy    = xwl_surface_destroy_req,
};

static void xwl_surface_resource_destroy(struct wl_resource *resource)
{
    struct xwm_xwl_surface *xs = wl_resource_get_user_data(resource);
    if (!xs) return;
    /* Per spec, destroying the xwayland_surface_v1 does NOT break an existing
     * association; the wl_surface stays adopted until it is unmapped/destroyed. */
    wl_list_remove(&xs->link);
    free(xs);
}

/* ------------------------------------------------------------------------- *
 * xwayland_shell_v1 implementation.
 * ------------------------------------------------------------------------- */
static void shell_get_xwayland_surface(struct wl_client *client, struct wl_resource *resource,
                                       uint32_t id, struct wl_resource *surface)
{
    /* One xwayland_surface_v1 per wl_surface. iosc.c owns the wl_surface role in
     * its own model; here we only track the association. If the surface already
     * has an xwayland_surface, that is a client bug -> role error. */
    if (xwl_by_surface(surface)) {
        wl_resource_post_error(resource, XWAYLAND_SHELL_V1_ERROR_ROLE,
                               "wl_surface already has an xwayland_surface role");
        return;
    }
    struct xwm_xwl_surface *xs = calloc(1, sizeof(*xs));
    if (!xs) { wl_client_post_no_memory(client); return; }
    xs->resource = wl_resource_create(client, &xwayland_surface_v1_interface,
                                      wl_resource_get_version(resource), id);
    if (!xs->resource) { free(xs); wl_client_post_no_memory(client); return; }
    xs->surface_res = surface;
    wl_resource_set_implementation(xs->resource, &xwl_surface_impl, xs,
                                   xwl_surface_resource_destroy);
    wl_list_insert(&xwm.xwl_surfaces, &xs->link);
    XWM_DBG("get_xwayland_surface -> %p for wl_surface %p\n",
            (void *)xs->resource, (void *)surface);
}

static void shell_destroy_req(struct wl_client *client, struct wl_resource *resource)
{
    (void)client;
    wl_resource_destroy(resource);
}

static const struct xwayland_shell_v1_interface shell_impl = {
    .destroy              = shell_destroy_req,
    .get_xwayland_surface = shell_get_xwayland_surface,
};

/* Only the Xwayland server we spawned may bind. We recognise it by pid: the
 * first client whose pid == xwayland_pid is recorded as the Xwayland client. */
static void shell_bind(struct wl_client *client, void *data, uint32_t version, uint32_t id)
{
    (void)data;
    pid_t pid = 0; uid_t uid = 0; gid_t gid = 0;
    wl_client_get_credentials(client, &pid, &uid, &gid);

    if (xwm.xwayland_pid > 0 && pid != xwm.xwayland_pid) {
        XWM_LOG("refusing xwayland_shell bind from non-Xwayland client (pid %d != %d)\n",
                (int)pid, (int)xwm.xwayland_pid);
        wl_client_post_implementation_error(client,
            "xwayland_shell_v1 may only be bound by the Xwayland server");
        return;
    }
    if (!xwm.xwayland_client) xwm.xwayland_client = client;

    struct wl_resource *res = wl_resource_create(client, &xwayland_shell_v1_interface,
                                                 (int)version, id);
    if (!res) { wl_client_post_no_memory(client); return; }
    wl_resource_set_implementation(res, &shell_impl, NULL, NULL);
    XWM_DBG("xwayland_shell_v1 bound by pid %d v%u\n", (int)pid, version);
}

/* ------------------------------------------------------------------------- *
 * X property helpers.
 * ------------------------------------------------------------------------- */
static void xwm_read_title(struct xwm_window *win)
{
    /* Prefer _NET_WM_NAME (UTF8_STRING), fall back to WM_NAME (STRING). */
    xcb_get_property_cookie_t c = xcb_get_property(
        xwm.conn, 0, win->xwindow, xwm.atoms[ATOM_NET_WM_NAME],
        XCB_ATOM_ANY, 0, 256 / 4);
    xcb_get_property_reply_t *r = xcb_get_property_reply(xwm.conn, c, NULL);
    if (!r || xcb_get_property_value_length(r) == 0) {
        free(r);
        c = xcb_get_property(xwm.conn, 0, win->xwindow, xwm.atoms[ATOM_WM_NAME],
                             XCB_ATOM_ANY, 0, 256 / 4);
        r = xcb_get_property_reply(xwm.conn, c, NULL);
    }
    if (r && xcb_get_property_value_length(r) > 0) {
        int len = xcb_get_property_value_length(r);
        if (len > (int)sizeof(win->title) - 1) len = (int)sizeof(win->title) - 1;
        memcpy(win->title, xcb_get_property_value(r), (size_t)len);
        win->title[len] = 0;
    }
    free(r);
}

static void xwm_read_wm_class(struct xwm_window *win)
{
    /* WM_CLASS is "instance\0class\0"; use the instance as the app id. */
    xcb_get_property_cookie_t c = xcb_get_property(
        xwm.conn, 0, win->xwindow, xwm.atoms[ATOM_WM_CLASS], XCB_ATOM_STRING, 0, 128 / 4);
    xcb_get_property_reply_t *r = xcb_get_property_reply(xwm.conn, c, NULL);
    if (r && xcb_get_property_value_length(r) > 0) {
        int len = xcb_get_property_value_length(r);
        const char *p = xcb_get_property_value(r);
        if (len > (int)sizeof(win->wm_class) - 1) len = (int)sizeof(win->wm_class) - 1;
        memcpy(win->wm_class, p, (size_t)len);
        win->wm_class[len] = 0;   /* naturally stops at the instance NUL */
    }
    free(r);
}

static void xwm_read_protocols(struct xwm_window *win)
{
    win->supports_delete = 0;
    win->supports_take_focus = 0;
    xcb_get_property_cookie_t c = xcb_get_property(
        xwm.conn, 0, win->xwindow, xwm.atoms[ATOM_WM_PROTOCOLS], XCB_ATOM_ATOM, 0, 64);
    xcb_get_property_reply_t *r = xcb_get_property_reply(xwm.conn, c, NULL);
    if (r && r->type == XCB_ATOM_ATOM) {
        xcb_atom_t *a = xcb_get_property_value(r);
        int n = xcb_get_property_value_length(r) / (int)sizeof(xcb_atom_t);
        for (int i = 0; i < n; i++) {
            if (a[i] == xwm.atoms[ATOM_WM_DELETE_WINDOW]) win->supports_delete = 1;
            else if (a[i] == xwm.atoms[ATOM_WM_TAKE_FOCUS]) win->supports_take_focus = 1;
        }
    }
    free(r);
}

/* Is this window an override-redirect / menu-type popup? */
static int xwm_is_popup_type(struct xwm_window *win)
{
    if (win->override_redirect) return 1;
    xcb_get_property_cookie_t c = xcb_get_property(
        xwm.conn, 0, win->xwindow, xwm.atoms[ATOM_NET_WM_WINDOW_TYPE], XCB_ATOM_ATOM, 0, 16);
    xcb_get_property_reply_t *r = xcb_get_property_reply(xwm.conn, c, NULL);
    int popup = 0;
    if (r && r->type == XCB_ATOM_ATOM) {
        xcb_atom_t *a = xcb_get_property_value(r);
        int n = xcb_get_property_value_length(r) / (int)sizeof(xcb_atom_t);
        for (int i = 0; i < n; i++) {
            if (a[i] == xwm.atoms[ATOM_NET_WM_WINDOW_TYPE_TOOLTIP] ||
                a[i] == xwm.atoms[ATOM_NET_WM_WINDOW_TYPE_MENU] ||
                a[i] == xwm.atoms[ATOM_NET_WM_WINDOW_TYPE_DROPDOWN_MENU] ||
                a[i] == xwm.atoms[ATOM_NET_WM_WINDOW_TYPE_POPUP_MENU] ||
                a[i] == xwm.atoms[ATOM_NET_WM_WINDOW_TYPE_COMBO] ||
                a[i] == xwm.atoms[ATOM_NET_WM_WINDOW_TYPE_DND]) { popup = 1; break; }
        }
    }
    free(r);
    return popup;
}

/* Write the ICCCM WM_STATE property (Normal=1 / Withdrawn=0). */
static void xwm_set_wm_state(struct xwm_window *win, uint32_t state)
{
    uint32_t vals[2] = { state, XCB_NONE };   /* state, icon window */
    xcb_change_property(xwm.conn, XCB_PROP_MODE_REPLACE, win->xwindow,
                        xwm.atoms[ATOM_WM_STATE], xwm.atoms[ATOM_WM_STATE], 32, 2, vals);
}

/* ------------------------------------------------------------------------- *
 * X event handlers.
 * ------------------------------------------------------------------------- */
static struct xwm_window *ensure_window(xcb_window_t xid, int override_redirect,
                                        int x, int y, int w, int h)
{
    struct xwm_window *win = window_by_xid(xid);
    if (win) return win;
    win = calloc(1, sizeof(*win));
    if (!win) return NULL;
    win->xwindow = xid;
    win->override_redirect = override_redirect;
    win->x = x; win->y = y; win->w = w; win->h = h;
    win->title[0] = 0;
    win->wm_class[0] = 0;
    wl_list_insert(&xwm.windows, &win->link);
    return win;
}

static void window_free(struct xwm_window *win)
{
    if (!win) return;
    if (win->adopted && win->surface_res)
        iosc_xwm_unadopt_surface(win->surface_res);
    wl_list_remove(&win->link);
    free(win);
}

static void handle_create_notify(xcb_create_notify_event_t *e)
{
    /* Track the window early so ConfigureRequest/PropertyNotify before MapRequest
     * have somewhere to land. We do NOT select input on it (rootless: Xwayland is
     * authoritative over the frame); SubstructureNotify on root already feeds us. */
    ensure_window(e->window, e->override_redirect, e->x, e->y,
                  e->width ? e->width : 1, e->height ? e->height : 1);
}

static void handle_map_request(xcb_map_request_event_t *e)
{
    struct xwm_window *win = ensure_window(e->window, 0, 0, 0, 1, 1);
    if (!win) return;
    XWM_DBG("map request xwindow=0x%x\n", e->window);
    /* We are the WM: honor the map. Read managed metadata, then map the frame. */
    xwm_read_protocols(win);
    xwm_read_wm_class(win);
    win->override_redirect = xwm_is_popup_type(win);
    win->map_requested = 1;

    /* Fetch geometry (client may have configured before mapping). */
    xcb_get_geometry_reply_t *g =
        xcb_get_geometry_reply(xwm.conn, xcb_get_geometry(xwm.conn, e->window), NULL);
    if (g) {
        win->x = g->x; win->y = g->y;
        win->w = g->width ? g->width : win->w;
        win->h = g->height ? g->height : win->h;
        win->depth = g->depth;
        free(g);
    }
    xcb_map_window(xwm.conn, e->window);
    xwm_set_wm_state(win, 1 /* NormalState */);
    try_adopt(win);   /* if the serial already arrived, adopt now */
}

static void handle_configure_request(xcb_configure_request_event_t *e)
{
    struct xwm_window *win = ensure_window(e->window, 0, 0, 0, 1, 1);

    /* Honor the client's requested geometry (rootless: no frame to subtract). */
    uint16_t mask = 0;
    uint32_t vals[7];
    int n = 0;
    if (e->value_mask & XCB_CONFIG_WINDOW_X)      { mask |= XCB_CONFIG_WINDOW_X;      vals[n++] = (uint32_t)e->x; if (win) win->x = e->x; }
    if (e->value_mask & XCB_CONFIG_WINDOW_Y)      { mask |= XCB_CONFIG_WINDOW_Y;      vals[n++] = (uint32_t)e->y; if (win) win->y = e->y; }
    if (e->value_mask & XCB_CONFIG_WINDOW_WIDTH)  { mask |= XCB_CONFIG_WINDOW_WIDTH;  vals[n++] = e->width;  if (win) win->w = e->width; }
    if (e->value_mask & XCB_CONFIG_WINDOW_HEIGHT) { mask |= XCB_CONFIG_WINDOW_HEIGHT; vals[n++] = e->height; if (win) win->h = e->height; }
    if (e->value_mask & XCB_CONFIG_WINDOW_BORDER_WIDTH) { mask |= XCB_CONFIG_WINDOW_BORDER_WIDTH; vals[n++] = e->border_width; }
    if (e->value_mask & XCB_CONFIG_WINDOW_SIBLING)      { mask |= XCB_CONFIG_WINDOW_SIBLING;      vals[n++] = e->sibling; }
    if (e->value_mask & XCB_CONFIG_WINDOW_STACK_MODE)   { mask |= XCB_CONFIG_WINDOW_STACK_MODE;   vals[n++] = e->stack_mode; }
    if (mask) xcb_configure_window(xwm.conn, e->window, mask, vals);

    if (win && win->adopted && win->surface_res)
        iosc_xwm_configure_surface(win->surface_res, win->x, win->y, win->w, win->h);
}

static void handle_unmap_notify(xcb_unmap_notify_event_t *e)
{
    struct xwm_window *win = window_by_xid(e->window);
    if (!win) return;
    if (win->adopted && win->surface_res)
        iosc_xwm_unadopt_surface(win->surface_res);
    win->adopted = 0;
    win->map_requested = 0;
    win->surface_res = NULL;   /* a re-map produces a fresh wl_surface + serial */
    win->serial = 0;
    xwm_set_wm_state(win, 0 /* WithdrawnState */);
}

static void handle_destroy_notify(xcb_destroy_notify_event_t *e)
{
    struct xwm_window *win = window_by_xid(e->window);
    if (win) window_free(win);
}

static void handle_property_notify(xcb_property_notify_event_t *e)
{
    struct xwm_window *win = window_by_xid(e->window);
    if (!win) return;
    if (e->atom == xwm.atoms[ATOM_NET_WM_NAME] || e->atom == xwm.atoms[ATOM_WM_NAME]) {
        xwm_read_title(win);
        if (win->adopted && win->surface_res)
            iosc_xwm_set_title(win->surface_res, win->title);
    } else if (e->atom == xwm.atoms[ATOM_WM_PROTOCOLS]) {
        xwm_read_protocols(win);
    }
    /* TODO(polish): WM_NORMAL_HINTS -> min/max size; _NET_WM_STATE changes. */
}

static void handle_client_message(xcb_client_message_event_t *e)
{
    if (e->type == xwm.atoms[ATOM_WL_SURFACE_SERIAL]) {
        /* lo in data.l[0], hi in data.l[1] (see protocol description). */
        uint32_t lo = (uint32_t)e->data.data32[0];
        uint32_t hi = (uint32_t)e->data.data32[1];
        uint64_t serial = ((uint64_t)hi << 32) | (uint64_t)lo;
        struct xwm_window *win = window_by_xid(e->window);
        if (!win) win = ensure_window(e->window, 0, 0, 0, 1, 1);
        XWM_DBG("WL_SURFACE_SERIAL %llu on xwindow=0x%x\n",
                (unsigned long long)serial, e->window);
        bind_serial_to_window(win, serial);
    }
    /* TODO(polish): _NET_WM_STATE, _NET_ACTIVE_WINDOW (client-requested activation),
     * WM_CHANGE_STATE (iconify), _NET_WM_MOVERESIZE. */
}

static void dispatch_event(xcb_generic_event_t *ev)
{
    if (ev->response_type == 0) {
        xcb_generic_error_t *err = (xcb_generic_error_t *)ev;
        XWM_DBG("X error %u (request %u.%u, resource 0x%x)\n", err->error_code,
                err->major_code, err->minor_code, err->resource_id);
        return;
    }
    XWM_DBG("X event %u\n", ev->response_type & 0x7f);
    switch (ev->response_type & 0x7f) {
    case XCB_CREATE_NOTIFY:     handle_create_notify((xcb_create_notify_event_t *)ev); break;
    case XCB_MAP_REQUEST:       handle_map_request((xcb_map_request_event_t *)ev); break;
    case XCB_CONFIGURE_REQUEST: handle_configure_request((xcb_configure_request_event_t *)ev); break;
    case XCB_UNMAP_NOTIFY:      handle_unmap_notify((xcb_unmap_notify_event_t *)ev); break;
    case XCB_DESTROY_NOTIFY:    handle_destroy_notify((xcb_destroy_notify_event_t *)ev); break;
    case XCB_PROPERTY_NOTIFY:   handle_property_notify((xcb_property_notify_event_t *)ev); break;
    case XCB_CLIENT_MESSAGE:    handle_client_message((xcb_client_message_event_t *)ev); break;
    case XCB_MAP_NOTIFY:
    case XCB_CONFIGURE_NOTIFY:
    case XCB_MAPPING_NOTIFY:
    case XCB_FOCUS_IN:
    case XCB_FOCUS_OUT:
    default:
        /* Not needed for the MVP; SubstructureNotify echoes are harmless. */
        break;
    }
}

static int xcb_fd_readable(int fd, uint32_t mask, void *data)
{
    (void)fd; (void)data;
    if (mask & (WL_EVENT_HANGUP | WL_EVENT_ERROR)) {
        XWM_LOG("xcb connection lost; shutting down XWM\n");
        iosc_xwm_shutdown();
        return 0;
    }
    int count = 0;
    xcb_generic_event_t *ev;
    while ((ev = xcb_poll_for_event(xwm.conn))) {
        dispatch_event(ev);
        free(ev);
        count++;
    }
    if (xcb_connection_has_error(xwm.conn)) {
        XWM_LOG("xcb connection error; shutting down XWM\n");
        iosc_xwm_shutdown();
        return 0;
    }
    if (count) xcb_flush(xwm.conn);
    return count;
}

/* ------------------------------------------------------------------------- *
 * X manager selection + root setup + EWMH hints.
 * ------------------------------------------------------------------------- */
static int intern_atoms(void)
{
    xcb_intern_atom_cookie_t cookies[ATOM__COUNT];
    for (int i = 0; i < ATOM__COUNT; i++) {
        const char *n = k_atom_names[i];
        cookies[i] = xcb_intern_atom(xwm.conn, 0, (uint16_t)strlen(n), n);
    }
    for (int i = 0; i < ATOM__COUNT; i++) {
        xcb_intern_atom_reply_t *r = xcb_intern_atom_reply(xwm.conn, cookies[i], NULL);
        if (!r) { XWM_LOG("intern_atom failed for %s\n", k_atom_names[i]); return -1; }
        xwm.atoms[i] = r->atom;
        free(r);
    }
    return 0;
}

/* Composite RedirectSubwindows(root, Manual), sent through libxcb's extension
 * interface because this module links only core libxcb (no libxcb-composite).
 * A rootless Xwayland gives a top-level window a wl_surface only once it is
 * manually redirected (xwayland-window.c: redirectDraw == RedirectDrawManual),
 * and it is the WM's job to ask, as wlroots' and weston's XWMs do. Without it
 * every X window maps on the X side and never shows up in the compositor. */
static xcb_extension_t xwm_composite_ext = { "Composite", 0 };

static int xwm_redirect_subwindows(void)
{
    const xcb_query_extension_reply_t *ext =
        xcb_get_extension_data(xwm.conn, &xwm_composite_ext);
    if (!ext || !ext->present) {
        XWM_LOG("X server has no Composite extension; X windows cannot be shown\n");
        return -1;
    }
    static const xcb_protocol_request_t req = {
        .count = 2, .ext = &xwm_composite_ext,
        .opcode = 2 /* RedirectSubwindows */, .isvoid = 1,
    };
    struct {
        uint8_t major_opcode, minor_opcode;
        uint16_t length;
        xcb_window_t window;
        uint8_t update;            /* 1 = CompositeRedirectManual */
        uint8_t pad[3];
    } out = { 0, 0, 0, xwm.root, 1, { 0, 0, 0 } };
    struct iovec parts[4];
    parts[2].iov_base = &out;
    parts[2].iov_len = sizeof(out);
    parts[3].iov_base = NULL;
    parts[3].iov_len = -parts[2].iov_len & 3;
    xcb_void_cookie_t c = { xcb_send_request(xwm.conn, XCB_REQUEST_CHECKED, parts + 2, &req) };
    xcb_generic_error_t *err = xcb_request_check(xwm.conn, c);
    if (err) {
        XWM_LOG("Composite RedirectSubwindows failed: X error %d\n", err->error_code);
        free(err);
        return -1;
    }
    return 0;
}

static int setup_wm(void)
{
    const xcb_setup_t *setup = xcb_get_setup(xwm.conn);
    xcb_screen_iterator_t it = xcb_setup_roots_iterator(setup);
    xwm.screen = it.data;
    if (!xwm.screen) { XWM_LOG("no X screen\n"); return -1; }
    xwm.root = xwm.screen->root;

    if (intern_atoms() != 0) return -1;

    /* Take SubstructureRedirect on the root: this is the WM redirection grab.
     * If another WM holds it the server returns BadAccess on the next round-trip. */
    {
        uint32_t values[] = {
            XCB_EVENT_MASK_SUBSTRUCTURE_REDIRECT |
            XCB_EVENT_MASK_SUBSTRUCTURE_NOTIFY   |
            XCB_EVENT_MASK_PROPERTY_CHANGE
        };
        xcb_void_cookie_t c = xcb_change_window_attributes_checked(
            xwm.conn, xwm.root, XCB_CW_EVENT_MASK, values);
        xcb_generic_error_t *err = xcb_request_check(xwm.conn, c);
        if (err) {
            XWM_LOG("cannot become WM (SubstructureRedirect held?): X error %d\n",
                    err->error_code);
            free(err);
            return -1;
        }
    }

    if (xwm_redirect_subwindows() != 0) return -1;

    /* Dedicated window: WM_S0 selection owner + _NET_SUPPORTING_WM_CHECK target. */
    xwm.wm_window = xcb_generate_id(xwm.conn);
    xcb_create_window(xwm.conn, XCB_COPY_FROM_PARENT, xwm.wm_window, xwm.root,
                      0, 0, 1, 1, 0, XCB_WINDOW_CLASS_INPUT_OUTPUT,
                      xwm.screen->root_visual, 0, NULL);

    /* Own WM_S0 (ICCCM manager selection). CurrentTime is acceptable for a fresh
     * session; a full replace-existing-WM handshake is not needed here. */
    xcb_set_selection_owner(xwm.conn, xwm.wm_window, xwm.atoms[ATOM_WM_S0], XCB_CURRENT_TIME);

    /* _NET_SUPPORTING_WM_CHECK on both root and the check window; _NET_WM_NAME. */
    xcb_change_property(xwm.conn, XCB_PROP_MODE_REPLACE, xwm.root,
                        xwm.atoms[ATOM_NET_SUPPORTING_WM_CHECK], XCB_ATOM_WINDOW, 32, 1,
                        &xwm.wm_window);
    xcb_change_property(xwm.conn, XCB_PROP_MODE_REPLACE, xwm.wm_window,
                        xwm.atoms[ATOM_NET_SUPPORTING_WM_CHECK], XCB_ATOM_WINDOW, 32, 1,
                        &xwm.wm_window);
    static const char wm_name[] = "iosc-xwm";
    xcb_change_property(xwm.conn, XCB_PROP_MODE_REPLACE, xwm.wm_window,
                        xwm.atoms[ATOM_NET_WM_NAME], xwm.atoms[ATOM_UTF8_STRING], 8,
                        (uint32_t)(sizeof(wm_name) - 1), wm_name);

    /* Advertise the EWMH bits we honor. */
    xcb_atom_t supported[] = {
        xwm.atoms[ATOM_NET_SUPPORTED],
        xwm.atoms[ATOM_NET_SUPPORTING_WM_CHECK],
        xwm.atoms[ATOM_NET_WM_NAME],
        xwm.atoms[ATOM_NET_ACTIVE_WINDOW],
        xwm.atoms[ATOM_NET_WM_STATE],
        xwm.atoms[ATOM_NET_WM_WINDOW_TYPE],
        xwm.atoms[ATOM_NET_CLIENT_LIST],
    };
    xcb_change_property(xwm.conn, XCB_PROP_MODE_REPLACE, xwm.root,
                        xwm.atoms[ATOM_NET_SUPPORTED], XCB_ATOM_ATOM, 32,
                        (uint32_t)(sizeof(supported) / sizeof(supported[0])), supported);

    xcb_flush(xwm.conn);
    return 0;
}

/* ------------------------------------------------------------------------- *
 * Spawn Xwayland.
 * ------------------------------------------------------------------------- */
/* Is X display :n taken? Something answers on its socket, or a lock file names a
 * live pid (an Xvfb or Xwayland that has not bound its socket yet). */
static int x_display_taken(int n)
{
    char path[64];
    snprintf(path, sizeof(path), "/tmp/.X11-unix/X%d", n);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd >= 0) {
        struct sockaddr_un a;
        memset(&a, 0, sizeof(a));
        a.sun_family = AF_UNIX;
        snprintf(a.sun_path, sizeof(a.sun_path), "%s", path);
        int live = connect(fd, (struct sockaddr *)&a, sizeof(a)) == 0;
        close(fd);
        if (live) return 1;
    }
    snprintf(path, sizeof(path), "/tmp/.X%d-lock", n);
    FILE *f = fopen(path, "r");
    if (!f) return 0;
    long pid = 0;
    int got = fscanf(f, "%ld", &pid) == 1;
    fclose(f);
    return got && pid > 0 && (kill((pid_t)pid, 0) == 0 || errno == EPERM);
}

/* Xwayland's own pick (-displayfd with no display) does not work here: its lock
 * files never appear on iOS, so a second Xwayland (another slot's iosc) sees :0
 * as free and its listener unlinks the first one's socket. Pick the display
 * ourselves and pass it explicitly; -displayfd still reports it once ready. */
static int pick_x_display(void)
{
    for (int n = 0; n < 64; n++)
        if (!x_display_taken(n)) return n;
    return -1;
}

/* Spawn Xwayland with:
 *   wm_fd        : one end of a SOCK_STREAM socketpair -> Xwayland's -wm fd; the
 *                  XWM connects to the other end with xcb_connect_to_fd.
 *   display_wfd  : write end of a pipe -> Xwayland's -displayfd; Xwayland writes
 *                  the chosen display number here when ready.
 * Returns the Xwayland pid (>0) and hands back the XWM-side wm socket fd and the
 * read end of the display pipe, or -1. It does NOT read the display number:
 * Xwayland writes it only after InitOutput, which round-trips with this
 * compositor, so the read has to wait for the event loop (display_fd_readable). */
static pid_t spawn_xwayland(int *out_wm_fd, int *out_display_fd)
{
    int wm_sv[2] = { -1, -1 };       /* [0] XWM side, [1] Xwayland side */
    int disp_pipe[2] = { -1, -1 };   /* [0] read (XWM), [1] write (Xwayland) */

    if (socketpair(AF_UNIX, SOCK_STREAM, 0, wm_sv) != 0) {
        XWM_LOG("socketpair(wm) failed: %s\n", strerror(errno));
        return -1;
    }
    if (pipe(disp_pipe) != 0) {
        XWM_LOG("pipe(displayfd) failed: %s\n", strerror(errno));
        close(wm_sv[0]); close(wm_sv[1]);
        return -1;
    }

    /* The XWM-side wm fd must survive exec of the compositor's children but be
     * CLOEXEC so it is not leaked into Xwayland; the child-side fds must be
     * INHERITED (no CLOEXEC) so Xwayland can use them by number. */
    fcntl(wm_sv[0], F_SETFD, FD_CLOEXEC);
    fcntl(disp_pipe[0], F_SETFD, FD_CLOEXEC);
    fcntl(disp_pipe[0], F_SETFL, O_NONBLOCK);   /* read from the event loop */
    /* Clear CLOEXEC on the two child fds explicitly. */
    fcntl(wm_sv[1], F_SETFD, 0);
    fcntl(disp_pipe[1], F_SETFD, 0);

    char wm_fd_str[16], disp_fd_str[16], disp_str[16];
    snprintf(wm_fd_str, sizeof(wm_fd_str), "%d", wm_sv[1]);
    snprintf(disp_fd_str, sizeof(disp_fd_str), "%d", disp_pipe[1]);
    int dpy = pick_x_display();
    if (dpy < 0) {
        XWM_LOG("no free X display in :0-:63\n");
        close(wm_sv[0]); close(wm_sv[1]); close(disp_pipe[0]); close(disp_pipe[1]);
        return -1;
    }
    snprintf(disp_str, sizeof(disp_str), ":%d", dpy);

    /* -extension MIT-SHM: iOS has no SysV shared memory (shmget raises SIGSYS),
     * so any client that sees MIT-SHM (cairo-xlib, mesa's Xlib driver) dies on
     * first use. Hiding it server-side makes them fall back to XPutImage, the
     * same fix run-xwayland.sh applies to the rootful smoke harness. */
    const char *bin = xwm_xwayland_bin();
    char *const argv[] = {
        (char *)bin,
        disp_str,
        (char *)"-rootless",
        (char *)"-wm",        wm_fd_str,
        (char *)"-displayfd", disp_fd_str,
        (char *)"-terminate",
        (char *)"-extension", (char *)"MIT-SHM",
        NULL
    };

    /* Ensure Xwayland finds the compositor: WAYLAND_DISPLAY must be set. We set it
     * in the compositor environment (harmless; matches the running socket). */
    setenv("WAYLAND_DISPLAY", xwm_wayland_display(), 1);

    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    /* posix_spawn inherits fds by default; we only need CLOEXEC cleared, done. */

    pid_t pid = 0;
    int rc = posix_spawn(&pid, bin, &fa, NULL, argv, environ);
    posix_spawn_file_actions_destroy(&fa);

    /* Close the child-side fds in our process regardless of outcome. */
    close(wm_sv[1]);
    close(disp_pipe[1]);

    if (rc != 0) {
        XWM_LOG("posix_spawn(%s) failed: %s\n", bin, strerror(rc));
        close(wm_sv[0]); close(disp_pipe[0]);
        return -1;
    }
    XWM_LOG("spawned Xwayland pid=%d on %s (bin=%s, wayland=%s)\n",
            (int)pid, disp_str, bin, xwm_wayland_display());

    *out_wm_fd = wm_sv[0];
    *out_display_fd = disp_pipe[0];
    return pid;
}

/* Second half of start-up, run from the event loop once Xwayland has reported
 * its display (it is then past InitOutput and about to enter Dispatch, so the
 * synchronous xcb setup below gets its replies without the compositor's help). */
static int xwm_connect_wm(void)
{
    /* Connect the WM xcb socket. xcb_connect_to_fd takes ownership of wm_fd. */
    xwm.conn = xcb_connect_to_fd(xwm.wm_fd, NULL);
    xwm.wm_fd = -1;
    if (xcb_connection_has_error(xwm.conn)) {
        XWM_LOG("xcb_connect_to_fd failed\n");
        return -1;
    }
    if (setup_wm() != 0) return -1;

    xwm.xcb_source = wl_event_loop_add_fd(xwm.loop, xcb_get_file_descriptor(xwm.conn),
                                          WL_EVENT_READABLE, xcb_fd_readable, NULL);
    if (!xwm.xcb_source) {
        XWM_LOG("wl_event_loop_add_fd(xcb) failed\n");
        return -1;
    }
    xwm.running = 1;
    /* Drain anything already queued during setup. */
    xcb_flush(xwm.conn);
    xcb_fd_readable(xcb_get_file_descriptor(xwm.conn), WL_EVENT_READABLE, NULL);
    return xwm.running ? 0 : -1;
}

static int display_fd_readable(int fd, uint32_t mask, void *data)
{
    (void)data;
    int eof = 0;
    for (;;) {
        if (xwm.display_len >= sizeof(xwm.display_buf) - 1) break;
        ssize_t r = read(fd, xwm.display_buf + xwm.display_len,
                         sizeof(xwm.display_buf) - 1 - xwm.display_len);
        if (r > 0) { xwm.display_len += (size_t)r; continue; }
        if (r == 0) { eof = 1; break; }
        if (errno == EINTR) continue;
        if (errno == EAGAIN || errno == EWOULDBLOCK) break;
        eof = 1;
        break;
    }
    xwm.display_buf[xwm.display_len] = 0;
    int complete = memchr(xwm.display_buf, '\n', xwm.display_len) != NULL ||
                   xwm.display_len >= sizeof(xwm.display_buf) - 1;
    if (!complete && !eof && !(mask & (WL_EVENT_HANGUP | WL_EVENT_ERROR)))
        return 0;                                  /* partial line; wait for more */

    wl_event_source_remove(xwm.display_source);
    xwm.display_source = NULL;
    close(xwm.display_fd);
    xwm.display_fd = -1;

    char *end = NULL;
    long n = strtol(xwm.display_buf, &end, 10);
    if (xwm.display_len == 0 || end == xwm.display_buf || n < 0 || n > 65535) {
        XWM_LOG("Xwayland exited or reported no display (\"%s\"); XWM not started\n",
                xwm.display_buf);
        iosc_xwm_shutdown();
        return 0;
    }
    xwm.display_number = (int)n;
    if (xwm_connect_wm() != 0) {
        XWM_LOG("WM setup on :%d failed; stopping Xwayland\n", xwm.display_number);
        iosc_xwm_shutdown();
        return 0;
    }

    char disp[16];
    snprintf(disp, sizeof(disp), ":%d", xwm.display_number);
    setenv("DISPLAY", disp, 1);   /* so later X clients of this process find it */
    xwm.display_published = 1;
    iosc_xwm_display_changed(xwm.display_number);
    XWM_LOG("XWM started (rootless) on X display %s; xwayland_shell_v1 advertised\n", disp);
    return 0;
}

/* ------------------------------------------------------------------------- *
 * Public API.
 * ------------------------------------------------------------------------- */
int iosc_xwm_start(struct wl_event_loop *loop)
{
    if (xwm.running || xwm.display_source) return 0;
    if (!loop) { XWM_LOG("start: NULL event loop\n"); return -1; }

    memset(&xwm, 0, sizeof(xwm));
    xwm.display_number = -1;
    xwm.wm_fd = -1;
    xwm.display_fd = -1;
    wl_list_init(&xwm.windows);
    wl_list_init(&xwm.xwl_surfaces);
    xwm.loop = loop;
    xwm.display = iosc_xwm_wl_display();
    if (!xwm.display) { XWM_LOG("start: glue returned NULL wl_display\n"); return -1; }

    /* Advertise the shell global BEFORE spawning Xwayland so it is present the
     * moment Xwayland connects and scans the registry. */
    xwm.shell_global = wl_global_create(xwm.display, &xwayland_shell_v1_interface, 1,
                                        NULL, shell_bind);
    if (!xwm.shell_global) { XWM_LOG("wl_global_create(xwayland_shell_v1) failed\n"); return -1; }

    xwm.xwayland_pid = spawn_xwayland(&xwm.wm_fd, &xwm.display_fd);
    if (xwm.xwayland_pid <= 0) {
        xwm.xwayland_pid = 0;
        iosc_xwm_shutdown();
        return -1;
    }

    xwm.display_source = wl_event_loop_add_fd(loop, xwm.display_fd, WL_EVENT_READABLE,
                                              display_fd_readable, NULL);
    if (!xwm.display_source) {
        XWM_LOG("wl_event_loop_add_fd(displayfd) failed\n");
        iosc_xwm_shutdown();
        return -1;
    }
    XWM_LOG("waiting for Xwayland to report its display\n");
    return 0;
}

void iosc_xwm_shutdown(void)
{
    if (!xwm.loop) return;            /* never started: lists are not initialised */
    if (xwm.display_source) { wl_event_source_remove(xwm.display_source); xwm.display_source = NULL; }
    if (xwm.display_fd >= 0) { close(xwm.display_fd); xwm.display_fd = -1; }
    if (xwm.wm_fd >= 0) { close(xwm.wm_fd); xwm.wm_fd = -1; }
    if (xwm.xcb_source) { wl_event_source_remove(xwm.xcb_source); xwm.xcb_source = NULL; }

    struct xwm_window *win, *wtmp;
    wl_list_for_each_safe(win, wtmp, &xwm.windows, link) {
        wl_list_remove(&win->link);
        free(win);
    }
    struct xwm_xwl_surface *xs, *xtmp;
    wl_list_for_each_safe(xs, xtmp, &xwm.xwl_surfaces, link) {
        if (xs->resource) wl_resource_set_user_data(xs->resource, NULL);
        wl_list_remove(&xs->link);
        free(xs);
    }

    if (xwm.conn) { xcb_disconnect(xwm.conn); xwm.conn = NULL; }
    if (xwm.shell_global) { wl_global_destroy(xwm.shell_global); xwm.shell_global = NULL; }
    if (xwm.xwayland_pid > 0) {
        kill(xwm.xwayland_pid, SIGTERM);
        /* -terminate makes Xwayland exit on last-client; reap non-blocking. */
        waitpid(xwm.xwayland_pid, NULL, WNOHANG);
        xwm.xwayland_pid = 0;
    }
    if (xwm.display_published) {
        xwm.display_published = 0;
        unsetenv("DISPLAY");
        iosc_xwm_display_changed(-1);
    }
    xwm.running = 0;
}

void iosc_xwm_surface_commit(struct wl_resource *surface_res)
{
    if (!xwm.running) return;
    struct xwm_xwl_surface *xs = xwl_by_surface(surface_res);
    if (xs) xwl_surface_apply_commit(xs);
}

void iosc_xwm_notify_focus(struct wl_resource *surface_res)
{
    if (!xwm.running || !xwm.conn) return;
    struct xwm_window *win = window_by_surface(surface_res);
    if (win) {
        /* Prefer the ICCCM WM_TAKE_FOCUS message for clients that advertise it
         * (globally active input model); otherwise set the input focus directly. */
        if (win->supports_take_focus) {
            xcb_client_message_event_t ev = {0};
            ev.response_type = XCB_CLIENT_MESSAGE;
            ev.format = 32;
            ev.window = win->xwindow;
            ev.type = xwm.atoms[ATOM_WM_PROTOCOLS];
            ev.data.data32[0] = xwm.atoms[ATOM_WM_TAKE_FOCUS];
            ev.data.data32[1] = XCB_CURRENT_TIME;
            xcb_send_event(xwm.conn, 0, win->xwindow, XCB_EVENT_MASK_NO_EVENT, (const char *)&ev);
        }
        xcb_set_input_focus(xwm.conn, XCB_INPUT_FOCUS_POINTER_ROOT,
                            win->xwindow, XCB_CURRENT_TIME);
        xcb_change_property(xwm.conn, XCB_PROP_MODE_REPLACE, xwm.root,
                            xwm.atoms[ATOM_NET_ACTIVE_WINDOW], XCB_ATOM_WINDOW, 32, 1,
                            &win->xwindow);
    } else {
        /* Focus left all X windows. */
        xcb_set_input_focus(xwm.conn, XCB_INPUT_FOCUS_POINTER_ROOT,
                            XCB_NONE, XCB_CURRENT_TIME);
        xcb_window_t none = XCB_WINDOW_NONE;
        xcb_change_property(xwm.conn, XCB_PROP_MODE_REPLACE, xwm.root,
                            xwm.atoms[ATOM_NET_ACTIVE_WINDOW], XCB_ATOM_WINDOW, 32, 1,
                            &none);
    }
    xcb_flush(xwm.conn);
}

void iosc_xwm_request_close(struct wl_resource *surface_res)
{
    if (!xwm.running || !xwm.conn) return;
    struct xwm_window *win = window_by_surface(surface_res);
    if (!win) return;
    if (win->supports_delete) {
        xcb_client_message_event_t ev = {0};
        ev.response_type = XCB_CLIENT_MESSAGE;
        ev.format = 32;
        ev.window = win->xwindow;
        ev.type = xwm.atoms[ATOM_WM_PROTOCOLS];
        ev.data.data32[0] = xwm.atoms[ATOM_WM_DELETE_WINDOW];
        ev.data.data32[1] = XCB_CURRENT_TIME;
        xcb_send_event(xwm.conn, 0, win->xwindow, XCB_EVENT_MASK_NO_EVENT, (const char *)&ev);
    } else {
        xcb_kill_client(xwm.conn, win->xwindow);
    }
    xcb_flush(xwm.conn);
}

int iosc_xwm_is_xwayland_client(struct wl_client *client)
{
    if (!xwm.running || !client) return 0;
    if (xwm.xwayland_client) return client == xwm.xwayland_client;
    if (xwm.xwayland_pid > 0) {
        pid_t pid = 0; uid_t uid = 0; gid_t gid = 0;
        wl_client_get_credentials(client, &pid, &uid, &gid);
        return pid == xwm.xwayland_pid;
    }
    return 0;
}

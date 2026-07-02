/* iosc_xwm.h — rootless Xwayland X window manager (XWM) for the iosc compositor.
 *
 * Clean-room MIT. Designed only from public specs: the xwayland-shell-v1 staging
 * protocol XML, ICCCM (WM_Sn selection, WM_STATE, WM_PROTOCOLS, WM_TAKE_FOCUS,
 * WM_DELETE_WINDOW, WM_NAME, WM_NORMAL_HINTS), EWMH (_NET_SUPPORTED,
 * _NET_WM_NAME, _NET_ACTIVE_WINDOW, _NET_SUPPORTING_WM_CHECK, _NET_WM_WINDOW_TYPE)
 * and the X11 core protocol via libxcb's public request/reply API.
 *
 * This module is SELF-CONTAINED: iosc.c never includes xcb, and iosc_xwm.c never
 * includes iosc.c internals. The two sides speak only through:
 *
 *   (A) The PUBLIC API below (module implements, iosc.c calls).
 *   (B) The GLUE CONTRACT below (iosc.c implements, module calls; declared
 *       `extern` here). Everything the XWM needs from the compositor is one of
 *       these functions, and every one takes/returns an opaque `struct
 *       wl_resource *` for a wl_surface — the module never sees `struct
 *       iosc_surface`.
 *
 * Rootless model: Xwayland is spawned with `-rootless -wm <fd> -displayfd <fd>
 * -terminate`. Each X11 top-level (and each override-redirect popup) becomes an
 * INDIVIDUAL iosc surface. Surface<->window association is race-free via
 * xwayland_shell_v1 (get_xwayland_surface + set_serial, matched against the X11
 * WL_SURFACE_SERIAL client message on wl_surface.commit).
 */
#ifndef IOSC_XWM_H
#define IOSC_XWM_H

#include <stdint.h>

struct wl_event_loop;
struct wl_display;
struct wl_client;
struct wl_resource;

#ifdef __cplusplus
extern "C" {
#endif

/* =========================================================================
 * (A) PUBLIC API — implemented by iosc_xwm.c, called by iosc.c.
 * ========================================================================= */

/* Start the XWM: spawn Xwayland, connect the WM xcb socket, own WM_S0, advertise
 * xwayland_shell_v1 as a wl_global, and register the xcb fd on `loop`. `loop`
 * must be the compositor's wl_event_loop (wl_display_get_event_loop(g_display)).
 * Returns 0 on success, -1 on failure (already logged). Safe to call once.
 *
 * Gate this behind IOSC_XWAYLAND=1 in iosc's main() (see the integration doc);
 * the XWM is opt-in so a plain Wayland session pays nothing. */
int  iosc_xwm_start(struct wl_event_loop *loop);

/* Tear down: kill Xwayland, close the xcb connection, remove the wl_global and
 * the event source. Idempotent. */
void iosc_xwm_shutdown(void);

/* Commit hook. iosc.c MUST call this once from its wl_surface.commit handler for
 * EVERY surface commit, passing the committing wl_surface's wl_resource. The XWM
 * uses it to apply the double-buffered xwayland_surface_v1.set_serial state and,
 * when the serial matches a pending X11 window, to drive adoption (both arrival
 * orders — association-before-map and map-before-association — are handled).
 * Fast no-op for any surface that is not a pending Xwayland surface. */
void iosc_xwm_surface_commit(struct wl_resource *surface_res);

/* Focus mirror (Wayland -> X). iosc.c SHOULD call this from keyboard_set_focus()
 * whenever the focused surface changes, passing the newly-focused wl_surface
 * resource, or NULL when focus leaves all windows. If the surface is an adopted
 * X11 window the XWM sets the X input focus (SetInputFocus / WM_TAKE_FOCUS) and
 * _NET_ACTIVE_WINDOW; otherwise it points the X focus at None. No-op if the XWM
 * is not running. */
void iosc_xwm_notify_focus(struct wl_resource *surface_res);

/* Close request (Wayland chrome/taskbar -> X). iosc.c calls this when the user
 * closes an adopted X11 window via compositor UI (decoration close button,
 * foreign-toplevel close). The XWM sends WM_DELETE_WINDOW if the client supports
 * it, else falls back to XKillClient. No-op if the surface is not an adopted X11
 * window. */
void iosc_xwm_request_close(struct wl_resource *surface_res);

/* True if `client` is the Xwayland server the XWM spawned (pid match). iosc.c may
 * use this to special-case Xwayland (e.g. to keep the shell OSK away from X apps,
 * or to skip xdg-only assumptions). Optional. */
int  iosc_xwm_is_xwayland_client(struct wl_client *client);


/* =========================================================================
 * (B) GLUE CONTRACT — implemented by iosc.c, called by iosc_xwm.c.
 * These are declared extern here; iosc.c must define all of them. Each deals
 * only in opaque wl_surface wl_resource pointers, so iosc_xwm.c stays free of
 * iosc.c internals. Inside these, iosc.c resolves the wl_resource to its
 * `struct iosc_surface *` with wl_resource_get_user_data(surface_res).
 * ========================================================================= */

/* Window metadata handed to iosc.c at adoption time. Geometry is in X pixels,
 * which for a -rootless Xwayland equal the compositor's LOGICAL pixels (Xwayland
 * runs at the logical desktop size; the 2x supersample is compositor-internal).
 * `override_redirect` marks menus/tooltips/DND that must NOT be reparented,
 * focused, or given server decorations — iosc.c should map them as POPUP-band,
 * unmanaged, at (x,y). `xwm` is an opaque back-pointer the XWM owns; iosc.c must
 * store it verbatim on the surface and hand it back is NOT required (the XWM
 * keeps its own surface_res -> window index), but it is provided for debugging
 * and future direct callbacks. */
struct iosc_xwm_window_info {
    uint32_t    xwm_window;        /* X11 window id (for logging/debug) */
    int         override_redirect; /* 1 => unmanaged popup (menu/tooltip/DND) */
    int         x, y;              /* requested top-left, X/logical px */
    int         width, height;     /* requested size, X/logical px (>=1) */
    const char *title;             /* UTF-8, may be "" (never NULL) */
    const char *wm_class;          /* WM_CLASS instance/app id, may be "" */
    void       *xwm;               /* opaque XWM handle (do not dereference) */
};

/* Return the compositor's wl_display. Used once at start for wl_global_create.
 * Trivial in iosc.c: `return g_display;`. */
extern struct wl_display *iosc_xwm_wl_display(void);

/* Adopt an already-committed wl_surface as an X11 window. iosc.c must:
 *   - resolve surface_res -> iosc_surface;
 *   - refuse (return -1) if it already has a non-Xwayland role (xdg etc.);
 *   - give it a role: TOPLEVEL for a managed window, POPUP for override_redirect;
 *   - copy info->title into the surface title (foreign-toplevel/taskbar) and
 *     info->wm_class into app_id;
 *   - mark the surface as "Xwayland-managed" (so iosc.c does not expect an
 *     xdg_toplevel and routes close/focus back through the (A) hooks);
 *   - place it: override_redirect at (info->x, info->y); managed toplevels may
 *     use iosc's normal cascade (position is a hint only);
 *   - map it (surface_map) if it has buffer content.
 * Returns 0 on success, -1 if the surface cannot be adopted. Called at most once
 * per (surface_res) association; a re-map creates a fresh wl_surface + serial. */
extern int  iosc_xwm_adopt_surface(struct wl_resource *surface_res,
                                    const struct iosc_xwm_window_info *info);

/* The X window was unmapped or destroyed (or its wl_surface association ended).
 * iosc.c must unmap the surface (surface_unmap) and drop its Xwayland-managed
 * role so a subsequent re-association starts clean. No-op if not adopted. */
extern void iosc_xwm_unadopt_surface(struct wl_resource *surface_res);

/* ConfigureRequest / geometry change from the X client. iosc.c should update the
 * adopted surface's size/position (logical px). For MVP iosc.c may honor only
 * position for override_redirect popups and ignore size (Xwayland is authoritative
 * over the buffer size); a fuller resize path is TODO(polish). No-op if not
 * adopted. */
extern void iosc_xwm_configure_surface(struct wl_resource *surface_res,
                                       int x, int y, int width, int height);

/* Title changed (PropertyNotify on _NET_WM_NAME / WM_NAME). iosc.c updates the
 * surface title and re-broadcasts foreign-toplevel/taskbar state. No-op if not
 * adopted. */
extern void iosc_xwm_set_title(struct wl_resource *surface_res, const char *title);

#ifdef __cplusplus
}
#endif

#endif /* IOSC_XWM_H */

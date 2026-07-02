/*
 * xios_canvas.h — per-window presentation for the native-iPadOS flavor.
 *
 * The desktop flavors composite every window into ONE output IOSurface that the
 * single Xios app presents (xios_surface.c). Native mode instead gives each
 * xdg_toplevel its OWN "canvas" IOSurface, handed to a per-app UIKit host that
 * presents it as a standalone iPad window. This file is the compositor side of
 * that: an N-canvas registry, the iosc-native.sock BIND server, and the
 * generalized mach-port hand-off (deliver_canvas_port = deliver_surface_port
 * parameterized on the surface + destination port).
 *
 * Like xios_surface.c it includes NO Wayland/GL headers — only Apple frameworks
 * + POSIX — so it can be a standalone TU that iosc.c calls into. The frozen
 * iosc.c half (per-window recomposite + surface_map wiring) lands post the
 * monolith->modules refactor and drives this API; see docs/native-ipados-plan.md
 * §7b. The wire contract mirrors apps/iosc-host/Sources/iosc_native_proto.h and
 * apps/iosc-host/Sources/NativeClient.c (the reference host client).
 */
#ifndef XIOS_CANVAS_H
#define XIOS_CANVAS_H

#include <stdint.h>
#include "xios_surface.h"   /* xios_msg, XIOS_MSG_MAGIC, core codes 0x01-0x0f */

/* Default native rendezvous socket (matches iosc_native_proto.h). */
#define XIOS_CANVAS_SOCK "/var/jb/tmp/iosc-native.sock"

/* ---- native lifecycle codes 0x40-0x5f -------------------------------------
 * Mirror of iosc_native_proto.h; kept here so this TU needs only xios_surface.h.
 * MUST stay in sync with the host client. (0x01-0x0f core codes live in
 * xios_surface.h; native REUSES core DIRTY/CURSOR, window_id-targeted.) */
#define XIOS_MSG_BIND         0x40u   /* host->iosc: a=scene_w b=scene_h c=scale d=reply-port; payload=app_id */
#define XIOS_MSG_RESIZE       0x41u   /* host->iosc: a=w b=h; window_id */
#define XIOS_MSG_ACTIVATE     0x42u   /* host->iosc: a=1 key / a=0 resign; window_id */
#define XIOS_MSG_CLOSED       0x43u   /* host->iosc: user dismissed the scene; window_id */
#define XIOS_MSG_WINDOW_NEW   0x50u   /* iosc->host: a=w b=h c=stride d=flags; payload=title; canvas port follows */
#define XIOS_MSG_WINDOW_GEOM  0x51u   /* iosc->host: a=w b=h c=stride; fresh canvas port follows */
#define XIOS_MSG_WINDOW_TITLE 0x52u   /* iosc->host: payload=utf8 */
#define XIOS_MSG_WINDOW_GONE  0x53u   /* iosc->host: toplevel unmapped; tear the scene down */

/* WINDOW_NEW/GEOM flag bits (msg.d). */
#define XIOS_NWIN_MAXIMIZED   0x1
#define XIOS_NWIN_FULLSCREEN  0x2

/* Host->iosc control messages, delivered on the reader thread. iosc.c must
 * marshal these onto its wl event loop (they arrive off-thread). `window` is the
 * compositor-assigned id iosc handed out via WINDOW_NEW. All are optional; a NULL
 * callback is ignored. `user` is the pointer passed to xios_canvas_set_handlers. */
struct xios_canvas_handlers {
    void (*resize)(uint32_t window, int w, int h, void *user);
    void (*activate)(uint32_t window, int active, void *user);
    void (*closed)(uint32_t window, void *user);
    void *user;
};

/* Register the host->iosc control handlers. Call before xios_canvas_server_start.
 * Copied by value; safe to pass a stack struct. */
void xios_canvas_set_handlers(const struct xios_canvas_handlers *h);

/* Start the iosc-native.sock BIND listener (one background thread: accept +
 * per-connection BIND handshake + reads host control records). Idempotent. NULL
 * path uses XIOS_CANVAS_SOCK. 0 on success. */
int  xios_canvas_server_start(const char *sock_path);

/* Tear down the listener + all host connections + all canvases (server exit). */
void xios_canvas_server_stop(void);

/* Allocate a canvas IOSurface for `window_id` at w x h (same IOSurfaceAlign +
 * BGRA8 path as xios_surface_create). Returns the opaque IOSurfaceRef to bind as
 * a GL render target (iosc_gl_bind_target), or NULL. *stride receives the padded
 * bytes-per-row. Re-creating an existing window_id (a resize) releases the old
 * surface first; call xios_canvas_geom afterward to redeliver the port. */
void *xios_canvas_create(uint32_t window_id, int w, int h, int *stride);

/* The opaque IOSurfaceRef for window_id (for iosc_gl_bind_target), or NULL. */
void *xios_canvas_surface(uint32_t window_id);

/* Announce a mapped toplevel to the host that bound `app_id`: send WINDOW_NEW
 * (a=w b=h c=stride d=flags, payload=title) then mach_msg the canvas send-right
 * to that host's BIND reply port. Returns 1 if a bound host received it, 0 if no
 * host matched app_id (iosc.c should route the window to the catch-all Xios app),
 * -1 on error. The canvas must exist (xios_canvas_create) first. The window
 * metadata is retained so a host that binds later (or after jetsam) can receive
 * the live canvas immediately from the BIND path. */
int  xios_canvas_announce(uint32_t window_id, const char *app_id,
                          const char *title, uint32_t flags);

/* After a resize realloc (xios_canvas_create on an existing id): send WINDOW_GEOM
 * (a=w b=h c=stride) then redeliver the fresh canvas port. No-op if unbound. */
void xios_canvas_geom(uint32_t window_id);

/* DIRTY for one window (window_id-targeted core record). Non-blocking, same
 * never-stall/drop-on-backpressure posture as xios_notify_dirty. No-op if the
 * window is unbound. `x,y,w,h` is the damage rect (all 0 = whole canvas). */
void xios_canvas_notify_dirty(uint32_t window_id, int x, int y, int w, int h);

/* Title changed: send WINDOW_TITLE (payload=utf8). No-op if unbound. */
void xios_canvas_title(uint32_t window_id, const char *title);

/* Toplevel unmapped / client exited: send WINDOW_GONE and free the canvas. */
void xios_canvas_gone(uint32_t window_id);

#endif /* XIOS_CANVAS_H */

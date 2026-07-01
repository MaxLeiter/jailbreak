/*
 * xios_surface.h — IOSurface-backed shared framebuffer for the native iOS X server.
 *
 * Plain C, *no X server headers* (so CoreFoundation/IOSurface/mach headers don't
 * collide with dix's macros). The X DDX (hw/vfb/InitOutput.c, built as "Xios")
 * calls these; all the Apple-framework code lives here.
 *
 * Sharing model (validated on iPadOS 17.6.1 — global IOSurfaceLookup(id) is dead,
 * so we hand the IOSurface's mach port to the app over a Unix socket rendezvous):
 *   1. Server creates a BGRA8 IOSurface; X draws straight into its base address.
 *   2. App connects to the Unix socket, sends {pid, mach receive-port name}.
 *   3. Server task_for_pid()s the app, mach_port_extract_right()s a send right to
 *      that port, and mach_msg()s IOSurfaceCreateMachPort() across as a port
 *      descriptor. App does IOSurfaceLookupFromMachPort() -> same backing memory.
 *   4. Server streams damage bounding-boxes over the socket so the app only
 *      re-presents on change (zero-copy: no per-frame texture upload).
 */
#ifndef XIOS_SURFACE_H
#define XIOS_SURFACE_H

#include <stdint.h>
#include <stdbool.h>

/* Create the shared BGRA8 IOSurface for a `width`x`height` screen.
 * Returns the framebuffer base address (the X server draws directly here), or
 * NULL on failure. On success *stride is the real bytes-per-row (may be padded
 * for alignment) and *alloc_size is the total allocation in bytes. */
void *xios_surface_create(int width, int height, int *stride, int *alloc_size);

/* Start the AF_UNIX rendezvous/damage socket at sock_path and write the geometry
 * handshake to json_path (so the app can detect IOSurface mode and find the
 * socket). Spawns one background thread that accepts clients and performs the
 * mach-port hand-off. Must be called after xios_surface_create(). 0 on success.
 * Idempotent: a second call while already serving is a no-op. */
int xios_server_start(const char *sock_path, const char *json_path,
                      int width, int height, int stride);

/* Notify every connected client that the framebuffer changed (the app then
 * re-presents the zero-copy texture). Called from the X server's block handler;
 * a no-op when no clients are attached. Non-blocking — a backed-up/suspended
 * client never stalls the X server. */
void xios_notify_dirty(void);

/* ---- typed app-socket framing (present / cursor / native envelope) ---------
 * The classic ddx protocol (xios_hello -> xios_reply -> a stream of bare
 * XIOS_DIRTY bytes) stays BYTE-IDENTICAL for existing clients. A client that
 * sets XIOS_HELLO_TYPED in xios_hello.reserved instead gets a stream of typed
 * 32-byte records after the same xios_reply handshake, so the compositor can
 * multiplex DIRTY + CURSOR (and later an in-band HELLO + the native per-window
 * lifecycle) over one connection. This is the shared envelope the cursor-overlay,
 * the xios.json->in-band-hello refactor, and the native-iPadOS flavor all use. */
#define XIOS_HELLO_TYPED 0x54595031u   /* 'TYP1' in xios_hello.reserved => typed stream */
#define XIOS_MSG_MAGIC   0x584D5331u   /* 'XMS1' per-record frame sync */
enum {
    XIOS_MSG_HELLO  = 0x01,  /* compositor->app: a=w b=h c=stride d=format; payload=compositor-id */
    XIOS_MSG_DIRTY  = 0x02,  /* compositor->app: a,b,c,d = damage x,y,w,h (all 0 = whole); window_id */
    XIOS_MSG_CURSOR = 0x03,  /* compositor->app: a=x b=y c=shape_id d=flags(bit0 visible) */
    /* 0x04-0x0f reserved core; 0x40-0x5f reserved for native-iPadOS per-window. */
};
typedef struct {
    uint32_t magic;      /* XIOS_MSG_MAGIC */
    uint32_t type;       /* XIOS_MSG_* */
    uint32_t window_id;  /* per-window (native); 0 = the single/default surface */
    uint32_t length;     /* payload bytes after the header (0 if none) */
    int32_t  a, b, c, d;
} xios_msg;              /* 32 bytes, little-endian; optional length-byte payload follows */

/* Optional CURSOR payload (when the compositor wants a SPECIFIC bitmap drawn, e.g.
 * a client-supplied cursor surface): this header then w*h*4 premultiplied BGRA.
 * When the CURSOR record has length==0 the app draws from shape_id instead. */
typedef struct { uint32_t w, h; int32_t hot_x, hot_y; } xios_cursor_bitmap;

/* Send a CURSOR record (pointer position + wp_cursor_shape id, shape_id 0 = hidden)
 * to every TYPED client. No-op for classic clients / when none are attached. Lets
 * a present-side cursor overlay in the app move the pointer with ZERO compositor
 * recomposite. Non-blocking, same never-stall posture as xios_notify_dirty. */
void xios_notify_cursor(int x, int y, int visible, int shape_id);

/* True if at least one connected client negotiated the typed stream (so the
 * compositor knows the app will draw its own cursor overlay and can stop
 * compositing the cursor into the output). */
int xios_have_typed_client(void);

/* Tear down the socket, clients, and IOSurface (server exit). */
void xios_server_stop(void);

/* ---- client→server IOSurface import (Wayland zero-copy GPU buffers) --------
 *
 * The reverse of the app hand-off above: a Wayland client (e.g. an ANGLE-Metal
 * GLES client) renders into its OWN IOSurface, calls IOSurfaceCreateMachPort()
 * to get a port name in its task, and passes that name + its pid to the
 * compositor over the Wayland protocol. These helpers let the compositor import
 * that surface using the SAME task_for_pid + mach_port_extract_right primitives
 * as deliver_surface_port(), then composite it into the output surface. All the
 * Apple-framework code stays in this file (callers see only opaque void*). */

/* Import a client's IOSurface by reaching into its task. `pid` is the client's
 * pid (from the Wayland socket peer credentials); `port_name` is the
 * IOSurfaceCreateMachPort() name in the client's IPC space. Returns an opaque
 * IOSurfaceRef (retained; release with xios_release_client_iosurface), or NULL.
 * On success the w and h out-params receive the surface dimensions. */
void *xios_import_client_iosurface(int pid, unsigned port_name, int *w, int *h);

/* Copy a client IOSurface's pixels into the output IOSurface (the one the Xios
 * app displays). First-light compositing: a CPU blit, top-left aligned, clamped
 * to the output. Locks the source read-only so GPU writes are coherent. The
 * caller still calls xios_notify_dirty() to trigger re-present. */
void xios_blit_client_iosurface(void *client_surface);

/* Release a surface returned by xios_import_client_iosurface(). */
void xios_release_client_iosurface(void *client_surface);

/* The output IOSurface (opaque IOSurfaceRef) the Xios app displays — so a GPU
 * compositor can bind it as an ANGLE render target. NULL before xios_surface_create(). */
void *xios_get_output_iosurface(void);

/* The created output surface's pixel dimensions (0x0 before xios_surface_create()).
 * Backs xios_output_geometry() in the shared glue (MetaMonitorManagerIOS). */
void xios_surface_geometry(int *width, int *height);

/* Read one pixel of the output IOSurface in APP/display space (top-left origin) as
 * a 32-bit little-endian BGRA value — i.e. exactly what the Xios app shows at (x,y).
 * Locks read-only so GPU (Metal/ANGLE) writes are made coherent to the CPU first.
 * Validation/diagnostics only (orientation + placement ground truth, off the hot
 * path). Returns 0 if there is no surface or (x,y) is out of range. */
uint32_t xios_read_output_pixel(int x, int y);

/* Bulk read-back of a w x h region of the output IOSurface at (x,y) in APP/display
 * space (top-left origin) into `dst` (BGRA8, `dst_stride` bytes per row). Locks the
 * surface read-only ONCE so GPU (Metal/ANGLE) writes are made coherent, then copies
 * row by row; the rect is clamped to the surface (out-of-range columns/rows in dst
 * are left untouched). Returns 0 on success, -1 if there is no surface / bad args.
 *
 * This is the SOFTWARE screencopy seam (zwlr_screencopy_v1): a later GPU-blit path
 * (blit the output IOSurface straight into the client's IOSurface-backed buffer, no
 * CPU round-trip) can replace this body without touching the protocol callers. */
int xios_read_output_region(int x, int y, int w, int h, void *dst, int dst_stride);

#endif /* XIOS_SURFACE_H */

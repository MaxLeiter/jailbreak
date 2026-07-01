#ifndef XIOS_XSURFACE_H
#define XIOS_XSURFACE_H

#include <IOSurface/IOSurfaceRef.h>

/*
 * Client side of the Xios IOSurface hand-off. Connects to the X server's Unix
 * socket, performs the mach-port rendezvous (publishes a receive port; the server
 * task_for_pid's us and mach_msg's the IOSurface's port back), and exposes the
 * resulting IOSurface for zero-copy Metal texturing. See xios_surface.c (server).
 */

typedef struct XSurfaceConn XSurfaceConn;

/* Connect + handshake. Returns NULL on any failure (server not up, mach transfer
 * denied, etc.) so the caller can fall back to the Xvfb file path. */
XSurfaceConn *xsurface_connect(const char *sock_path);

/* Borrowed (+0) reference to the shared surface; valid until xsurface_close(). */
IOSurfaceRef xsurface_get(XSurfaceConn *c);

int xsurface_width(XSurfaceConn *c);
int xsurface_height(XSurfaceConn *c);
int xsurface_stride(XSurfaceConn *c);    /* bytes per row (may be padded) */
int xsurface_fd(XSurfaceConn *c);

/* Drain pending "framebuffer changed" notifications (non-blocking). Returns 1 if the
 * surface changed since the last call (present a frame), 0 if nothing pending, -1 if
 * the server disconnected. On a typed connection this also parses the CURSOR/HELLO
 * records interleaved on the same stream (see xsurface_cursor). */
int xsurface_drain(XSurfaceConn *c);

/* Latest pointer state from the typed CURSOR stream. iosc's present-side cursor
 * overlay (IOSC_APP_CURSOR) stops compositing the cursor into the framebuffer and
 * instead streams position+shape here, so the app draws it and a pointer move costs
 * zero compositor recomposite. Returns a sequence number that increments on each
 * CURSOR record — compare against your last-seen value to detect a change. Fills
 * x,y (framebuffer px), visible (0 => hide the overlay), shape_id (the
 * wp_cursor_shape id: 1=default arrow, 9=text, ...). Returns 0 until the first
 * record arrives: a server with the overlay OFF never sends one, so the compositor
 * is still drawing the cursor itself and the app must NOT draw its own. */
uint32_t xsurface_cursor(XSurfaceConn *c, int *x, int *y, int *visible, int *shape_id);

/* Compositor identity from the in-band HELLO (e.g. "iosc", "mutter-ios"), or "" if
 * the server didn't send one (classic connection / a build predating the framing).
 * Valid after xsurface_connect() returns. */
const char *xsurface_compositor_id(XSurfaceConn *c);

void xsurface_close(XSurfaceConn *c);

#endif /* XIOS_XSURFACE_H */

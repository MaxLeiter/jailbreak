#ifndef XIOS_XSURFACE_H
#define XIOS_XSURFACE_H

#include <stddef.h>
#include <stdint.h>
#include <IOSurface/IOSurfaceRef.h>

/*
 * Client side of the Xios IOSurface hand-off. Connects to the X server's Unix
 * socket, performs the mach-port rendezvous (publishes a receive port; the server
 * task_for_pid's us and mach_msg's the IOSurface's port back), and exposes the
 * resulting IOSurface for zero-copy Metal texturing. See xios_surface.c (server).
 */

typedef struct XSurfaceConn XSurfaceConn;

/* Connect + typed handshake. Returns NULL on any failure (server not up, mach
 * transfer denied, protocol mismatch, etc.) so the caller can keep showing its
 * holding frame and retry. */
XSurfaceConn *xsurface_connect(const char *sock_path);

/* Borrowed (+0) reference to the shared surface; valid until xsurface_close(). */
IOSurfaceRef xsurface_get(XSurfaceConn *c);

int xsurface_width(XSurfaceConn *c);
int xsurface_height(XSurfaceConn *c);
int xsurface_stride(XSurfaceConn *c);    /* bytes per row (may be padded) */
int xsurface_fd(XSurfaceConn *c);

/* Drain pending "framebuffer changed" notifications (non-blocking). Returns 1 if the
 * surface changed since the last call (present a frame), 0 if nothing pending, -1 if
 * the server disconnected. Also parses the CURSOR/HELLO records interleaved on
 * the same stream (see xsurface_cursor). */
int xsurface_drain(XSurfaceConn *c);

/* Latest DIRTY present sequence received from the compositor. Echo it back after
 * the Metal command buffer that presents that frame completes. */
uint64_t xsurface_dirty_sequence(XSurfaceConn *c);
int xsurface_presented(XSurfaceConn *c, uint64_t seq);

/* Cross-process GPU fence attached to the most recently drained DIRTY record.
 * Returns 1 and borrows the fixed 32-byte broker capability token when the
 * producer submitted the frame, or 0 for a malformed/incomplete frame. The
 * pointer remains valid until xsurface_close(). */
int xsurface_gpu_fence_token(XSurfaceConn *c, const void **token,
                             size_t *token_size, uint64_t *value);

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

/* Compositor identity from the in-band HELLO (e.g. "iosc", "mutter-ios"). Valid
 * after xsurface_connect() returns. */
const char *xsurface_compositor_id(XSurfaceConn *c);

void xsurface_close(XSurfaceConn *c);

#endif /* XIOS_XSURFACE_H */

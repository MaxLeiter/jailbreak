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
 * the server disconnected. */
int xsurface_drain(XSurfaceConn *c);

void xsurface_close(XSurfaceConn *c);

#endif /* XIOS_XSURFACE_H */

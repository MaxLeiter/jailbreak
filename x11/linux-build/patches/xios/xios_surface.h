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

/* Tear down the socket, clients, and IOSurface (server exit). */
void xios_server_stop(void);

#endif /* XIOS_SURFACE_H */

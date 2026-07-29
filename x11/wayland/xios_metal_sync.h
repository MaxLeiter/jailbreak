#ifndef XIOS_METAL_SYNC_H
#define XIOS_METAL_SYNC_H

#include <EGL/egl.h>
#include <stddef.h>
#include <stdint.h>

/*
 * Export an ANGLE/Metal producer fence through the Xios Metal-event broker.
 *
 * The MTLSharedEventHandle crosses processes exactly once over NSXPC. On
 * success the returned 256-bit capability token remains owned by this module
 * and is stable until process exit. `value` is the monotonically increasing
 * event value that the consumer GPU must wait for before sampling the IOSurface.
 * Returns 1 when EGL_ANGLE_metal_shared_event_sync is active. A 0 return must
 * fail production presentation; callers may use a CPU barrier only behind an
 * explicit diagnostic opt-in.
 */
int xios_metal_sync_signal(EGLDisplay display,
                           const void **token,
                           size_t *token_size,
                           uint64_t *value);

/* Fetch the handle for a broker token and recreate/release its shared event. */
void *xios_metal_sync_import_event(const void *token, size_t token_size);
void xios_metal_sync_release_event(void *event);

/* Enqueue a GPU-side wait in ANGLE's current Metal command stream. The CPU does
 * not block. Returns 1 on success. */
int xios_metal_sync_wait(EGLDisplay display, void *event, uint64_t value);

#endif

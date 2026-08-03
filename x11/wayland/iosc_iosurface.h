#ifndef IOSC_IOSURFACE_H
#define IOSC_IOSURFACE_H

#include <stddef.h>
#include <stdint.h>
#include <wayland-server.h>

#define IOSC_IOSURFACE_VERSION 1

void iosc_iosurface_bind(struct wl_client *client, void *data,
                         uint32_t version, uint32_t id);

int iosc_iosurface_buffer_draw(struct wl_resource *buf,
                               int sx, int sy, int src_w, int src_h,
                               int dx, int dy, int dw, int dh);
int iosc_iosurface_buffer_get_size(struct wl_resource *buf, int *w, int *h);

/* Copy a small client IOSurface out to tightly packed top-down BGRA (stride
 * w*4), flipping a GL-origin surface. For the cursor plane: KWin allocates its
 * cursor through this path rather than wl_shm, and an IOSurface is CPU-mappable,
 * so this is a lock plus a memcpy rather than a GPU readback. Refuses anything
 * with an edge over max_edge. Returns 1 on success. */
int iosc_iosurface_buffer_read_bgra(struct wl_resource *buf, unsigned char *dst,
                                    int max_edge, int *out_w, int *out_h);

/* Direct-present metadata for an IOSurface wl_buffer. Peek does not consume the
 * producer acquire fence; call consume only after the app DIRTY was queued. */
int iosc_iosurface_buffer_peek_direct(struct wl_resource *buf,
                                      uint32_t *surface_id,
                                      const void **token, size_t *token_size,
                                      uint64_t *value);
void iosc_iosurface_buffer_consume_direct(struct wl_resource *buf,
                                          uint64_t value);

#endif

#ifndef IOSC_IOSURFACE_H
#define IOSC_IOSURFACE_H

#include <stdint.h>
#include <wayland-server.h>

void iosc_iosurface_bind(struct wl_client *client, void *data,
                         uint32_t version, uint32_t id);

int iosc_iosurface_buffer_draw(struct wl_resource *buf,
                               int sx, int sy, int src_w, int src_h,
                               int dx, int dy, int dw, int dh);
int iosc_iosurface_buffer_blit_to_output(struct wl_resource *buf);
int iosc_iosurface_buffer_get_size(struct wl_resource *buf, int *w, int *h);

#endif

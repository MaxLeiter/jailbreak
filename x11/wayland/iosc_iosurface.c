#include "iosc_iosurface.h"

#include "iosc-iosurface-server-protocol.h"
#include "iosc_gl.h"
#include "xios_surface.h"

#include <stdio.h>
#include <stdlib.h>
#include <sys/types.h>
#include <wayland-server-protocol.h>

enum {
    IOSC_IOSURFACE_FORMAT_MASK = 0x0000ffffu,
    IOSC_IOSURFACE_KNOWN_FLAGS = IOSC_IOSURFACE_FORMAT_FLAG_TOP_LEFT,
    IOSC_IOSURFACE_SUPPORTED_CAPABILITIES =
        IOSC_IOSURFACE_CAPABILITY_BGRA8888 |
        IOSC_IOSURFACE_CAPABILITY_ORIGIN_FLAGS |
        IOSC_IOSURFACE_CAPABILITY_MACH_PORT_IMPORT,
};

/* A wl_buffer backed by a client IOSurface imported over the iosc_iosurface
 * protocol (see iosc-iosurface.xml). The compositor reached into the client's
 * task to look the surface up; ib->surface is a retained IOSurfaceRef (opaque). */
struct iosc_iosurface_buffer {
    void *surface;   /* imported IOSurfaceRef (from xios_import_client_iosurface) */
    int   w, h;
    int   flip_v;    /* 1 = GL-origin client IOSurface; 0 = already top-left */
};

static void iosurface_buffer_destroy(struct wl_client *c, struct wl_resource *r)
{
    (void)c;
    wl_resource_destroy(r);
}

static const struct wl_buffer_interface iosurface_buffer_impl = {
    .destroy = iosurface_buffer_destroy,
};

static struct iosc_iosurface_buffer *iosurface_buffer_from_resource(struct wl_resource *buf)
{
    if (!buf || !wl_resource_instance_of(buf, &wl_buffer_interface, &iosurface_buffer_impl))
        return NULL;
    return wl_resource_get_user_data(buf);
}

static void iosurface_buffer_resource_destroy(struct wl_resource *r)
{
    struct iosc_iosurface_buffer *ib = wl_resource_get_user_data(r);
    if (!ib) return;
    if (ib->surface) {
        iosc_gl_forget_iosurface(ib->surface);   /* drop the cached GL texture/pbuffer */
        xios_release_client_iosurface(ib->surface);
    }
    free(ib);
}

/* IOSC_CLIENT_PROBE=1 dumps what each client IOSurface actually contains just
 * before we draw it. Every read is a synchronous GPU->CPU stall, so it is
 * throttled to one frame in 60 and off unless asked for. */
static void maybe_probe_client_buffer(struct iosc_iosurface_buffer *ib)
{
    static int enabled = -1;
    static unsigned long n;
    if (enabled < 0)
        enabled = getenv("IOSC_CLIENT_PROBE") ? 1 : 0;
    if (!enabled || (n++ % 60) != 0)
        return;
    char tag[32];
    snprintf(tag, sizeof tag, "client %dx%d", ib->w, ib->h);
    xios_probe_client_iosurface(ib->surface, tag);
}

int iosc_iosurface_buffer_draw(struct wl_resource *buf,
                               int sx, int sy, int src_w, int src_h,
                               int dx, int dy, int dw, int dh)
{
    struct iosc_iosurface_buffer *ib = iosurface_buffer_from_resource(buf);
    if (!ib)
        return 0;
    maybe_probe_client_buffer(ib);
    if (ib->surface)
        iosc_gl_draw_iosurface(ib->surface, ib->w, ib->h, sx, sy, src_w, src_h,
                               dx, dy, dw, dh, ib->flip_v);
    return 1;
}

int iosc_iosurface_buffer_blit_to_output(struct wl_resource *buf)
{
    struct iosc_iosurface_buffer *ib = iosurface_buffer_from_resource(buf);
    if (!ib)
        return 0;
    if (ib->surface)
        xios_blit_client_iosurface(ib->surface);
    return 1;
}

int iosc_iosurface_buffer_get_size(struct wl_resource *buf, int *w, int *h)
{
    struct iosc_iosurface_buffer *ib = iosurface_buffer_from_resource(buf);
    if (!ib)
        return 0;
    if (w) *w = ib->w;
    if (h) *h = ib->h;
    return 1;
}

static void iosurface_factory_create_buffer(struct wl_client *client,
        struct wl_resource *res, uint32_t id, uint32_t mach_port_name,
        int32_t width, int32_t height, uint32_t format)
{
    (void)width; (void)height;
    uint32_t layout = format & IOSC_IOSURFACE_FORMAT_MASK;
    uint32_t flags = format & ~IOSC_IOSURFACE_FORMAT_MASK;
    if (layout != IOSC_IOSURFACE_FORMAT_BGRA8888_GL_ORIGIN ||
        (flags & ~IOSC_IOSURFACE_KNOWN_FLAGS) != 0) {
        wl_resource_post_error(res, IOSC_IOSURFACE_ERROR_UNSUPPORTED_FORMAT,
                               "unsupported IOSurface format/flags 0x%x", format);
        return;
    }

    pid_t pid = 0; uid_t uid = 0; gid_t gid = 0;
    wl_client_get_credentials(client, &pid, &uid, &gid);

    int iw = 0, ih = 0;
    void *surf = xios_import_client_iosurface((int)pid, mach_port_name, &iw, &ih);

    struct iosc_iosurface_buffer *ib = calloc(1, sizeof(*ib));
    if (!ib) { if (surf) xios_release_client_iosurface(surf);
               wl_client_post_no_memory(client); return; }
    ib->surface = surf; ib->w = iw; ib->h = ih;
    ib->flip_v = (flags & IOSC_IOSURFACE_FORMAT_FLAG_TOP_LEFT) ? 0 : 1;

    struct wl_resource *buf = wl_resource_create(client, &wl_buffer_interface, 1, id);
    if (!buf) { if (surf) xios_release_client_iosurface(surf); free(ib);
                wl_client_post_no_memory(client); return; }
    wl_resource_set_implementation(buf, &iosurface_buffer_impl, ib,
                                   iosurface_buffer_resource_destroy);

    if (!surf) {
        wl_resource_post_error(res, IOSC_IOSURFACE_ERROR_IMPORT_FAILED,
                               "IOSurface import failed (pid=%d port=0x%x)",
                               (int)pid, mach_port_name);
        return;
    }
    fprintf(stderr, "iosc: imported client IOSurface as wl_buffer %dx%d (pid=%d)\n",
            iw, ih, (int)pid);
}

static void iosurface_factory_destroy(struct wl_client *c, struct wl_resource *r)
{
    (void)c;
    wl_resource_destroy(r);
}

static const struct iosc_iosurface_interface iosurface_factory_impl = {
    .destroy = iosurface_factory_destroy,
    .create_buffer = iosurface_factory_create_buffer,
};

void iosc_iosurface_bind(struct wl_client *client, void *data,
                         uint32_t version, uint32_t id)
{
    (void)data;
    struct wl_resource *r = wl_resource_create(client, &iosc_iosurface_interface,
                                               version, id);
    if (!r) { wl_client_post_no_memory(client); return; }
    wl_resource_set_implementation(r, &iosurface_factory_impl, NULL, NULL);
    if (wl_resource_get_version(r) >= 2)
        iosc_iosurface_send_capabilities(r, IOSC_IOSURFACE_SUPPORTED_CAPABILITIES);
    fprintf(stderr, "iosc: client bound iosc_iosurface v%u\n", version);
}

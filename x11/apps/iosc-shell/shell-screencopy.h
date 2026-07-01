/*
 * shell-screencopy.h — one-shot synchronous screen capture for the shell
 * clients, via iosc's zwlr_screencopy_manager_v1 (software readback).
 *
 * Used to build the frosted "material" backdrops (shell-blur.h): the overview
 * captures the whole desktop right before it maps; quick settings captures the
 * region its card will cover. The capture is a snapshot — correct for these
 * transient surfaces, and the only way to get "behind" pixels while iosc
 * composites layer surfaces opaque.
 *
 * Protocol flow implemented: capture_output[_region] → `buffer` event
 * (format/size/stride to allocate) [→ `buffer_done` on v3] → copy(wl_shm
 * buffer) → `ready`/`failed`. Runs its own bounded roundtrip loop, so call it
 * OUTSIDE wl event dispatch (before mapping, or from the main loop after
 * dispatch returns), never from inside a listener.
 *
 * Requires shell-draw.h (sd_create_anon_fd) and the generated
 * wlr-screencopy-unstable-v1-client-protocol.h to be included first.
 * Returns a CAIRO_FORMAT_RGB24 image surface in PHYSICAL pixels (the surface
 * owns the mapping; just cairo_surface_destroy it), or NULL.
 */
#ifndef SHELL_SCREENCOPY_H
#define SHELL_SCREENCOPY_H

#include <cairo/cairo.h>

struct sc_state {
    struct wl_shm    *shm;
    struct wl_buffer *buffer;
    void             *map;
    size_t            size;
    int               w, h, stride;
    uint32_t          format;
    int               have_buffer, done, failed;
    int               version;        /* bound manager version */
    struct zwlr_screencopy_frame_v1 *frame;
};

static void sc__munmap(void *data)
{
    struct sc_state *heap = data;
    if (heap->map) munmap(heap->map, heap->size);
    free(heap);
}

static void sc__on_buffer(void *d, struct zwlr_screencopy_frame_v1 *f,
                          uint32_t format, uint32_t w, uint32_t h, uint32_t stride)
{
    (void)f;
    struct sc_state *s = d;
    /* iosc advertises XRGB8888 (opaque BGRA in memory); accept ARGB too. */
    if (s->have_buffer) return;
    if (format != WL_SHM_FORMAT_XRGB8888 && format != WL_SHM_FORMAT_ARGB8888) return;
    s->format = format; s->w = (int)w; s->h = (int)h; s->stride = (int)stride;
    s->size = (size_t)stride * h;
    int fd = sd_create_anon_fd(s->size);
    if (fd < 0) return;
    s->map = mmap(NULL, s->size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (s->map == MAP_FAILED) { s->map = NULL; close(fd); return; }
    struct wl_shm_pool *pool = wl_shm_create_pool(s->shm, fd, (int32_t)s->size);
    s->buffer = wl_shm_pool_create_buffer(pool, 0, s->w, s->h, s->stride, s->format);
    wl_shm_pool_destroy(pool);
    close(fd);
    s->have_buffer = 1;
}

static void sc__on_flags(void *d, struct zwlr_screencopy_frame_v1 *f, uint32_t flags)
{ (void)d;(void)f;(void)flags; /* iosc: top-left origin, no y-invert */ }

static void sc__on_ready(void *d, struct zwlr_screencopy_frame_v1 *f,
                         uint32_t sh, uint32_t sl, uint32_t ns)
{ (void)f;(void)sh;(void)sl;(void)ns; ((struct sc_state *)d)->done = 1; }

static void sc__on_failed(void *d, struct zwlr_screencopy_frame_v1 *f)
{ (void)f; ((struct sc_state *)d)->failed = 1; }

static void sc__on_damage(void *d, struct zwlr_screencopy_frame_v1 *f,
                          uint32_t x, uint32_t y, uint32_t w, uint32_t h)
{ (void)d;(void)f;(void)x;(void)y;(void)w;(void)h; }

static void sc__on_linux_dmabuf(void *d, struct zwlr_screencopy_frame_v1 *f,
                                uint32_t fmt, uint32_t w, uint32_t h)
{ (void)d;(void)f;(void)fmt;(void)w;(void)h; }

static void sc__on_buffer_done(void *d, struct zwlr_screencopy_frame_v1 *f)
{
    struct sc_state *s = d;
    if (s->have_buffer && s->buffer)
        zwlr_screencopy_frame_v1_copy(f, s->buffer);
    else
        s->failed = 1;
}

static const struct zwlr_screencopy_frame_v1_listener sc__frame_listener = {
    .buffer       = sc__on_buffer,
    .flags        = sc__on_flags,
    .ready        = sc__on_ready,
    .failed       = sc__on_failed,
    .damage       = sc__on_damage,
    .linux_dmabuf = sc__on_linux_dmabuf,
    .buffer_done  = sc__on_buffer_done,
};

/*
 * Capture the output (w<=0 or h<=0 → whole output) into a new RGB24 cairo
 * surface in physical px. `mgr_version` is the version the manager was bound
 * at (pre-3 has no buffer_done; we copy right after the first roundtrip).
 */
static cairo_surface_t *sc_capture(struct wl_display *dpy, struct wl_shm *shm,
                                   struct zwlr_screencopy_manager_v1 *mgr,
                                   int mgr_version, struct wl_output *output,
                                   int x, int y, int w, int h)
{
    if (!dpy || !shm || !mgr || !output) return NULL;
    struct sc_state st;
    memset(&st, 0, sizeof st);
    st.shm = shm; st.version = mgr_version;

    if (w > 0 && h > 0)
        st.frame = zwlr_screencopy_manager_v1_capture_output_region(
                       mgr, 0 /*no cursor*/, output, x, y, w, h);
    else
        st.frame = zwlr_screencopy_manager_v1_capture_output(mgr, 0, output);
    if (!st.frame) return NULL;
    zwlr_screencopy_frame_v1_add_listener(st.frame, &sc__frame_listener, &st);

    /* v1/v2: no buffer_done — issue copy() ourselves once the buffer advert
     * arrives. v3+: sc__on_buffer_done sends it. */
    int copied = (mgr_version >= 3);
    for (int i = 0; i < 64 && !st.done && !st.failed; i++) {
        if (wl_display_roundtrip(dpy) < 0) break;
        if (!copied && st.have_buffer && st.buffer) {
            zwlr_screencopy_frame_v1_copy(st.frame, st.buffer);
            copied = 1;
        }
    }
    zwlr_screencopy_frame_v1_destroy(st.frame);
    if (st.buffer) wl_buffer_destroy(st.buffer);

    if (!st.done || !st.map) {
        if (st.map) munmap(st.map, st.size);
        return NULL;
    }

    /* Hand the mapping to a cairo surface; munmap on surface destroy. */
    struct sc_state *heap = malloc(sizeof *heap);
    if (!heap) { munmap(st.map, st.size); return NULL; }
    *heap = st;
    cairo_surface_t *surf = cairo_image_surface_create_for_data(
        (unsigned char *)st.map, CAIRO_FORMAT_RGB24, st.w, st.h, st.stride);
    if (cairo_surface_status(surf) != CAIRO_STATUS_SUCCESS) {
        cairo_surface_destroy(surf); sc__munmap(heap); return NULL;
    }
    static const cairo_user_data_key_t sc_key;
    cairo_surface_set_user_data(surf, &sc_key, heap, sc__munmap);
    return surf;
}

#endif /* SHELL_SCREENCOPY_H */

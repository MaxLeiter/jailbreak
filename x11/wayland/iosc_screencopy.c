/*
 * iosc_screencopy.c — wlr-screencopy-v1 (screenshots).
 *
 * Split out of iosc.c. A client asks for the output (or a region of it) and we
 * hand back the pixels. This is a SOFTWARE readback of the output IOSurface; a
 * GPU blit would be faster but screenshots are rare enough not to matter yet.
 *
 * with_damage capture rides on the compositor's last-present damage record
 * (g_last_present_damage_*), so a client that only wants changed frames is fed
 * from the same region tracking the present path already maintains.
 */
#include <wayland-server.h>
#include <wayland-server-protocol.h>
#include "wlr-screencopy-unstable-v1-server-protocol.h"

#include "xios_surface.h"   /* xios_read_output_region() */
#include "iosc_internal.h"
#include "iosc_util.h"

#include <stdio.h>
#include <time.h>
#include <stdlib.h>
#include <string.h>

/* ---- wlr-screencopy-v1: screenshots (SOFTWARE readback; GPU-blit later) --- *
 * A client (grim, xdg-desktop-portal, spectacle) binds the manager, asks to
 * capture the output (or a sub-region), receives a `buffer` event advertising the
 * format/size/stride to allocate, allocates a wl_shm buffer, and calls copy().
 * We read the composited output IOSurface back into that buffer via
 * xios_read_output_region() -- the SOFTWARE path. The clean seam for a future GPU
 * blit (output IOSurface -> the client's IOSurface-backed buffer, no CPU
 * round-trip) is xios_read_output_region()'s body plus a fast-path here; the
 * protocol code below stays unchanged. */

struct iosc_screencopy_frame {
    struct wl_resource *resource;
    int      x, y, w, h;       /* capture rect in output (physical) px */
    int      stride;           /* advertised buffer stride (w*4) */
    uint32_t format;           /* advertised wl_shm format */
    int      with_cursor;      /* overlay_cursor: include the pointer in the shot */
    int      used;             /* copy() may be called at most once */
};

static void screencopy_frame_res_destroy(struct wl_resource *r)
{ free(wl_resource_get_user_data(r)); }

static void screencopy_frame_destroy(struct wl_client *c, struct wl_resource *r)
{ (void)c; wl_resource_destroy(r); }

/* Read the composited output into the client's wl_shm buffer, honouring
 * overlay_cursor by recompositing without the pointer when it isn't wanted. */
static void screencopy_do_copy(struct iosc_screencopy_frame *f, struct wl_resource *buffer)
{
    struct wl_shm_buffer *shm = wl_shm_buffer_get(buffer);
    if (!shm ||
        wl_shm_buffer_get_format(shm) != f->format ||
        wl_shm_buffer_get_width(shm)  != f->w ||
        wl_shm_buffer_get_height(shm) != f->h ||
        wl_shm_buffer_get_stride(shm) != f->stride) {
        zwlr_screencopy_frame_v1_send_failed(f->resource);
        return;
    }

    int restore_cursor = 0;
    if (!f->with_cursor && g_cursor_visible) {
        output_damage_add_cursor_at(g_cursor_x, g_cursor_y);
        g_cursor_visible = 0;
        restore_cursor = 1;
    }
    g_force_output_composite = 1;
    output_damage_add_full();
    recomposite_now();          /* synchronous: the readback below needs THIS frame */
    g_force_output_composite = 0;

    wl_shm_buffer_begin_access(shm);
    int rc = xios_read_output_region(f->x, f->y, f->w, f->h,
                                     wl_shm_buffer_get_data(shm), f->stride);
    wl_shm_buffer_end_access(shm);

    if (restore_cursor) {
        g_cursor_visible = 1;
        output_damage_add_cursor_at(g_cursor_x, g_cursor_y);
        g_force_output_composite = 1;
        recomposite_now();
        g_force_output_composite = 0;
    }

    if (rc != 0) { zwlr_screencopy_frame_v1_send_failed(f->resource); return; }

    /* Top-left origin, no transform: no y-invert. Then report ready. */
    zwlr_screencopy_frame_v1_send_flags(f->resource, 0);
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    uint64_t sec = (uint64_t)ts.tv_sec;
    zwlr_screencopy_frame_v1_send_ready(f->resource,
        (uint32_t)(sec >> 32), (uint32_t)sec, (uint32_t)ts.tv_nsec);
}

static void screencopy_frame_copy(struct wl_client *c, struct wl_resource *r,
                                  struct wl_resource *buffer)
{ (void)c;
    struct iosc_screencopy_frame *f = wl_resource_get_user_data(r);
    if (!f) return;
    if (f->used) {
        wl_resource_post_error(r, ZWLR_SCREENCOPY_FRAME_V1_ERROR_ALREADY_USED,
                               "screencopy frame already used");
        return;
    }
    f->used = 1;
    screencopy_do_copy(f, buffer);
}

static void screencopy_send_damage(struct iosc_screencopy_frame *f)
{
    struct iosc_rect frame = { f->x, f->y, f->x + f->w, f->y + f->h };
    if (!g_last_present_damage_valid || g_last_present_damage_rect_count <= 0) {
        zwlr_screencopy_frame_v1_send_damage(f->resource, 0, 0, f->w, f->h);
        return;
    }
    for (int i = 0; i < g_last_present_damage_rect_count; i++) {
        struct iosc_rect r = g_last_present_damage_rects[i];
        if (!rect_intersects_rect(&r, &frame))
            continue;
        if (r.x0 < frame.x0) r.x0 = frame.x0;
        if (r.y0 < frame.y0) r.y0 = frame.y0;
        if (r.x1 > frame.x1) r.x1 = frame.x1;
        if (r.y1 > frame.y1) r.y1 = frame.y1;
        if (r.x1 <= r.x0 || r.y1 <= r.y0)
            continue;
        zwlr_screencopy_frame_v1_send_damage(f->resource,
            r.x0 - f->x, r.y0 - f->y, r.x1 - r.x0, r.y1 - r.y0);
    }
}

static void screencopy_frame_copy_with_damage(struct wl_client *c, struct wl_resource *r,
                                              struct wl_resource *buffer)
{
    (void)c;
    struct iosc_screencopy_frame *f = wl_resource_get_user_data(r);
    if (!f) return;
    if (f->used) {
        wl_resource_post_error(r, ZWLR_SCREENCOPY_FRAME_V1_ERROR_ALREADY_USED,
                               "screencopy frame already used");
        return;
    }
    f->used = 1;
    screencopy_send_damage(f);
    screencopy_do_copy(f, buffer);
}

static const struct zwlr_screencopy_frame_v1_interface screencopy_frame_impl = {
    .copy = screencopy_frame_copy,
    .destroy = screencopy_frame_destroy,
    .copy_with_damage = screencopy_frame_copy_with_damage,
};

/* Create + advertise a frame for the given capture rect (already clamped). */
static void screencopy_new_frame(struct wl_client *c, struct wl_resource *mgr,
                                 uint32_t id, int overlay_cursor,
                                 int x, int y, int w, int h)
{
    struct iosc_screencopy_frame *f = calloc(1, sizeof(*f));
    if (!f) { wl_client_post_no_memory(c); return; }
    f->x = x; f->y = y; f->w = w; f->h = h;
    f->stride = w * 4;
    f->format = WL_SHM_FORMAT_XRGB8888;    /* opaque BGRA8 in memory == our output */
    f->with_cursor = overlay_cursor;
    f->resource = wl_resource_create(c, &zwlr_screencopy_frame_v1_interface,
                                     wl_resource_get_version(mgr), id);
    if (!f->resource) { free(f); wl_client_post_no_memory(c); return; }
    wl_resource_set_implementation(f->resource, &screencopy_frame_impl, f,
                                   screencopy_frame_res_destroy);
    zwlr_screencopy_frame_v1_send_buffer(f->resource, f->format,
                                         (uint32_t)w, (uint32_t)h, (uint32_t)f->stride);
    if (wl_resource_get_version(f->resource) >= ZWLR_SCREENCOPY_FRAME_V1_BUFFER_DONE_SINCE_VERSION)
        zwlr_screencopy_frame_v1_send_buffer_done(f->resource);
}

static void screencopy_capture_output(struct wl_client *c, struct wl_resource *mgr,
                                      uint32_t id, int32_t overlay_cursor,
                                      struct wl_resource *output)
{ (void)output;
    screencopy_new_frame(c, mgr, id, overlay_cursor, 0, 0, g_width, g_height);
}

static void screencopy_capture_output_region(struct wl_client *c, struct wl_resource *mgr,
                                             uint32_t id, int32_t overlay_cursor,
                                             struct wl_resource *output,
                                             int32_t x, int32_t y, int32_t w, int32_t h)
{ (void)output;
    if (x < 0) { w += x; x = 0; }
    if (y < 0) { h += y; y = 0; }
    if (x + w > g_width)  w = g_width  - x;
    if (y + h > g_height) h = g_height - y;
    if (w <= 0 || h <= 0) { x = 0; y = 0; w = 1; h = 1; }   /* degenerate -> 1px */
    screencopy_new_frame(c, mgr, id, overlay_cursor, x, y, w, h);
}

static void screencopy_mgr_destroy(struct wl_client *c, struct wl_resource *r)
{ (void)c; wl_resource_destroy(r); }

static const struct zwlr_screencopy_manager_v1_interface screencopy_mgr_impl = {
    .capture_output = screencopy_capture_output,
    .capture_output_region = screencopy_capture_output_region,
    .destroy = screencopy_mgr_destroy,
};

void screencopy_mgr_bind(struct wl_client *client, void *data, uint32_t version, uint32_t id)
{ (void)data;
    struct wl_resource *r = wl_resource_create(client, &zwlr_screencopy_manager_v1_interface, version, id);
    if (!r) { wl_client_post_no_memory(client); return; }
    wl_resource_set_implementation(r, &screencopy_mgr_impl, NULL, NULL);
}

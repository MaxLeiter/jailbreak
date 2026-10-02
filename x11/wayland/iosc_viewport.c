/*
 * iosc_viewport.c — wp_viewporter + wp_fractional_scale_v1.
 *
 * Split out of iosc.c. Two small scale-related protocols GTK/Qt expect:
 *
 *   wp_viewporter          per-surface source crop + destination size, stored
 *                          as each request arrives (not double-buffered) and
 *                          applied by the composite path through s->viewport;
 *                          bad values are protocol errors per the spec, the
 *                          ones tied to the buffer checked at commit
 *   wp_fractional_scale_v1 tells a client the fractional scale to render at;
 *                          fractional_scale_broadcast() re-notifies every bound
 *                          client when the output is reconfigured
 */
#include <wayland-server.h>
#include <wayland-server-protocol.h>
#include "viewporter-server-protocol.h"
#include "fractional-scale-v1-server-protocol.h"

#include "iosc_internal.h"
#include "iosc_util.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ---- wp_viewporter + wp_fractional_scale --------------------------------- */

/* Live wp_fractional_scale_v1 objects, so a runtime output-scale change can
 * re-send preferred_scale to every fractional-scale-aware client. */
#define IOSC_MAX_FRAC_RES 64
static struct wl_resource *g_frac_res[IOSC_MAX_FRAC_RES]; static int g_nfrac_res;

static void viewport_resource_destroy(struct wl_resource *r)
{
    struct iosc_viewport *vp = wl_resource_get_user_data(r);
    if (!vp) return;
    if (vp->surface && vp->surface->viewport == vp)
        vp->surface->viewport = NULL;
    free(vp);
}

static void viewport_destroy(struct wl_client *c, struct wl_resource *r)
{ (void)c; wl_resource_destroy(r); }
static void viewport_set_source(struct wl_client *c, struct wl_resource *r,
                                wl_fixed_t x, wl_fixed_t y,
                                wl_fixed_t w, wl_fixed_t h)
{
    (void)c;
    struct iosc_viewport *vp = wl_resource_get_user_data(r);
    if (!vp) return;
    wl_fixed_t unset = wl_fixed_from_int(-1);
    if (x == unset && y == unset && w == unset && h == unset) {
        vp->has_src = 0;
        return;
    }
    if (x < 0 || y < 0 || w <= 0 || h <= 0) {
        wl_resource_post_error(r, WP_VIEWPORT_ERROR_BAD_VALUE,
                               "invalid source rectangle %.2f,%.2f %.2fx%.2f",
                               wl_fixed_to_double(x), wl_fixed_to_double(y),
                               wl_fixed_to_double(w), wl_fixed_to_double(h));
        return;
    }
    vp->has_src = 1;
    vp->src_fx = x; vp->src_fy = y; vp->src_fw = w; vp->src_fh = h;
    vp->src_x = wl_fixed_to_int(x);
    vp->src_y = wl_fixed_to_int(y);
    vp->src_w = wl_fixed_to_int(w);
    vp->src_h = wl_fixed_to_int(h);
}
static void viewport_set_destination(struct wl_client *c, struct wl_resource *r,
                                     int32_t w, int32_t h)
{
    (void)c;
    struct iosc_viewport *vp = wl_resource_get_user_data(r);
    if (!vp) return;
    if (w == -1 && h == -1) {
        vp->has_dst = 0;
        return;
    }
    if (w <= 0 || h <= 0) {
        wl_resource_post_error(r, WP_VIEWPORT_ERROR_BAD_VALUE,
                               "invalid destination size %dx%d", w, h);
        return;
    }
    vp->has_dst = 1;
    vp->dst_w = w;
    vp->dst_h = h;
}
/* Called by surface_commit_apply() once the commit's buffer and scale are in.
 * A source size that is not whole needs a destination size to land on (or the
 * surface size would be fractional), and the source rectangle, in surface-local
 * units, must lie inside the buffer; a NULL buffer is exempt from the latter. */
int viewport_validate_commit(struct iosc_surface *s)
{
    struct iosc_viewport *vp = s->viewport;
    if (!vp || !vp->has_src) return 0;
    if (!vp->has_dst && ((vp->src_fw & 0xff) || (vp->src_fh & 0xff))) {
        wl_resource_post_error(vp->resource, WP_VIEWPORT_ERROR_BAD_SIZE,
                               "source size %.2fx%.2f is not integral and no "
                               "destination size is set",
                               wl_fixed_to_double(vp->src_fw),
                               wl_fixed_to_double(vp->src_fh));
        return -1;
    }
    if (!s->current_buffer) return 0;
    /* Compare in wl_fixed units scaled by buffer_scale, so no division rounds:
     * (src_x + src_w) * scale <= buffer_width * 256. */
    int64_t scale = s->current_buffer_scale > 0 ? s->current_buffer_scale : 1;
    if (((int64_t)vp->src_fx + vp->src_fw) * scale > (int64_t)s->sw * 256 ||
        ((int64_t)vp->src_fy + vp->src_fh) * scale > (int64_t)s->sh * 256) {
        wl_resource_post_error(vp->resource, WP_VIEWPORT_ERROR_OUT_OF_BUFFER,
                               "source rectangle %.2f,%.2f %.2fx%.2f is outside "
                               "the %dx%d buffer at scale %d",
                               wl_fixed_to_double(vp->src_fx), wl_fixed_to_double(vp->src_fy),
                               wl_fixed_to_double(vp->src_fw), wl_fixed_to_double(vp->src_fh),
                               s->sw, s->sh, (int)scale);
        return -1;
    }
    return 0;
}

static const struct wp_viewport_interface viewport_impl = {
    .destroy = viewport_destroy,
    .set_source = viewport_set_source,
    .set_destination = viewport_set_destination,
};

static void viewporter_destroy(struct wl_client *c, struct wl_resource *r)
{ (void)c; wl_resource_destroy(r); }
static void viewporter_get_viewport(struct wl_client *c, struct wl_resource *r,
                                    uint32_t id, struct wl_resource *surface)
{
    struct iosc_surface *s = wl_resource_get_user_data(surface);
    if (s->viewport) {
        wl_resource_post_error(r, WP_VIEWPORTER_ERROR_VIEWPORT_EXISTS,
                               "surface already has a viewport");
        return;
    }
    struct iosc_viewport *vp = calloc(1, sizeof(*vp));
    if (!vp) { wl_client_post_no_memory(c); return; }
    struct wl_resource *vr = wl_resource_create(c, &wp_viewport_interface,
                                                wl_resource_get_version(r), id);
    if (!vr) { free(vp); wl_client_post_no_memory(c); return; }
    vp->resource = vr;
    vp->surface = s;
    s->viewport = vp;
    wl_resource_set_implementation(vr, &viewport_impl, vp, viewport_resource_destroy);
}
static const struct wp_viewporter_interface viewporter_impl = {
    .destroy = viewporter_destroy,
    .get_viewport = viewporter_get_viewport,
};
void viewporter_bind(struct wl_client *client, void *data, uint32_t version, uint32_t id)
{
    (void)data;
    struct wl_resource *r = wl_resource_create(client, &wp_viewporter_interface, version, id);
    if (!r) { wl_client_post_no_memory(client); return; }
    wl_resource_set_implementation(r, &viewporter_impl, NULL, NULL);
}

static void fractional_scale_destroy(struct wl_client *c, struct wl_resource *r)
{ (void)c; wl_resource_destroy(r); }
static const struct wp_fractional_scale_v1_interface fractional_scale_impl = {
    .destroy = fractional_scale_destroy,
};
static void fractional_scale_resource_destroy(struct wl_resource *r)
{
    for (int i = 0; i < g_nfrac_res; i++)
        if (g_frac_res[i] == r) { g_frac_res[i] = g_frac_res[--g_nfrac_res]; break; }
}
/* Re-notify every live fractional-scale client after a runtime output-scale change. */
void fractional_scale_broadcast(void)
{
    uint32_t pref = (uint32_t)(output_scale() * 120);
    for (int i = 0; i < g_nfrac_res; i++)
        wp_fractional_scale_v1_send_preferred_scale(g_frac_res[i], pref);
}
static void fractional_manager_destroy(struct wl_client *c, struct wl_resource *r)
{ (void)c; wl_resource_destroy(r); }
static void fractional_manager_get(struct wl_client *c, struct wl_resource *r,
                                   uint32_t id, struct wl_resource *surface)
{
    (void)surface;
    struct wl_resource *sr = wl_resource_create(c, &wp_fractional_scale_v1_interface,
                                                wl_resource_get_version(r), id);
    if (!sr) { wl_client_post_no_memory(c); return; }
    wl_resource_set_implementation(sr, &fractional_scale_impl, NULL,
                                   fractional_scale_resource_destroy);
    if (g_nfrac_res < IOSC_MAX_FRAC_RES)
        g_frac_res[g_nfrac_res++] = sr;
    wp_fractional_scale_v1_send_preferred_scale(sr, (uint32_t)(output_scale() * 120));
}
static const struct wp_fractional_scale_manager_v1_interface fractional_manager_impl = {
    .destroy = fractional_manager_destroy,
    .get_fractional_scale = fractional_manager_get,
};
void fractional_scale_bind(struct wl_client *client, void *data, uint32_t version, uint32_t id)
{
    (void)data;
    struct wl_resource *r = wl_resource_create(client, &wp_fractional_scale_manager_v1_interface,
                                               version, id);
    if (!r) { wl_client_post_no_memory(client); return; }
    wl_resource_set_implementation(r, &fractional_manager_impl, NULL, NULL);
}

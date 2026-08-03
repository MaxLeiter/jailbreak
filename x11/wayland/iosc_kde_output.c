/*
 * iosc_kde_output.c — the KDE output-management protocol family.
 *
 * Split out of iosc.c. kscreen/libkscreen (and Plasma's display KCM) drive our
 * single output through four related globals:
 *
 *   kde_output_device_v2      one device object per output, bursting its full
 *                             state (mode/scale/transform/geometry) then "done"
 *   kde_output_management_v2  a configuration object clients build up and apply
 *   kde_primary_output_v1     which output is primary
 *   kde_output_order_v1       the output ordering
 *
 * All four report the same IOSC_OUTPUT_NAME so KDE tooling can cross-reference
 * the one output we expose. Applying a configuration lands in
 * output_reconfigure_px(), which is iosc.c's single entry point for changing the
 * output geometry at runtime.
 */
#include <wayland-server.h>
#include <wayland-server-protocol.h>
#include "xdg-output-unstable-v1-server-protocol.h"   /* broadcast_output_all() */
#include "kde-output-device-v2-server-protocol.h"
#include "kde-output-management-v2-server-protocol.h"
#include "kde-primary-output-v1-server-protocol.h"
#include "kde-output-order-v1-server-protocol.h"

#include "iosc_internal.h"
#include "iosc_util.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ---- KDE output-management family ---------------------------------------- *
 * kde_output_device_v2 / kde_output_management_v2 / kde_primary_output_v1 /
 * kde_output_order_v1. These let kscreen-doctor, libkscreen and plasma enumerate
 * and reconfigure our single output directly (notably a runtime scale change).
 * We advertise exactly one output and one mode (the current physical mode). All
 * geometry values mirror the wl_output/xdg_output ones so the two views agree. */

/* A stable, persistent identifier for the output. We report it as both the device
 * name and the device uuid so kde_primary_output_v1 resolves regardless of whether
 * the consumer keys on name or uuid (the XML comment says uuid; modern plasma
 * matches by name). */
#define IOSC_OUTPUT_UUID IOSC_OUTPUT_NAME

#define IOSC_MAX_KDE_RES 32
static struct wl_resource *g_kde_device_res[IOSC_MAX_KDE_RES];  static int g_nkde_device_res;
static struct wl_resource *g_kde_primary_res[IOSC_MAX_KDE_RES]; static int g_nkde_primary_res;
static struct wl_resource *g_kde_order_res[IOSC_MAX_KDE_RES];   static int g_nkde_order_res;

struct iosc_kde_device {
    struct wl_resource *resource;   /* kde_output_device_v2 (this client) */
    struct wl_resource *mode;       /* the single kde_output_device_mode_v2, or NULL */
    int mode_w, mode_h;             /* physical hardware units of that mode */
    uint32_t mode_generation;       /* bumped per mode resource created (live modes are >= 1);
                                     * defeats pointer reuse in config mode validation */
};

static void kde_mode_resource_destroy(struct wl_resource *r)
{
    struct iosc_kde_device *dev = wl_resource_get_user_data(r);
    if (dev && dev->mode == r) dev->mode = NULL;   /* clear back-pointer: no UAF */
}

/* Send the full property burst for one device resource, ending with `done`. The
 * single mode object is created lazily and recreated only when its size changes
 * (i.e. on rotation), so a scale-only change keeps the client's mode reference. */
static void kde_device_send_state(struct iosc_kde_device *dev)
{
    struct wl_resource *r = dev->resource;
    struct wl_client *c = wl_resource_get_client(r);
    uint32_t ver = wl_resource_get_version(r);

    int mode_w = g_width, mode_h = g_height;
    int32_t tr = KDE_OUTPUT_DEVICE_V2_TRANSFORM_NORMAL;
    if (g_advertise_transform) {
        tr = g_output_transform;
        if (g_output_transform & 1) { mode_w = g_height; mode_h = g_width; }
    }

    kde_output_device_v2_send_geometry(r, 0, 0,
        output_px_to_mm(mode_w), output_px_to_mm(mode_h),
        KDE_OUTPUT_DEVICE_V2_SUBPIXEL_UNKNOWN, "iosc", "IOSurface", tr);

    /* (Re)advertise the single mode when absent or its size changed. */
    if (dev->mode && (dev->mode_w != mode_w || dev->mode_h != mode_h)) {
        kde_output_device_mode_v2_send_removed(dev->mode);
        wl_resource_destroy(dev->mode);   /* destroy hook clears dev->mode */
    }
    if (!dev->mode) {
        dev->mode = wl_resource_create(c, &kde_output_device_mode_v2_interface, 1, 0);
        if (dev->mode) {
            dev->mode_generation++;   /* stale config mode refs stop validating */
            wl_resource_set_implementation(dev->mode, NULL, dev, kde_mode_resource_destroy);
            kde_output_device_v2_send_mode(r, dev->mode);
            kde_output_device_mode_v2_send_size(dev->mode, mode_w, mode_h);
            kde_output_device_mode_v2_send_refresh(dev->mode, 60000);
            kde_output_device_mode_v2_send_preferred(dev->mode);
            dev->mode_w = mode_w;
            dev->mode_h = mode_h;
        }
    }
    if (dev->mode)
        kde_output_device_v2_send_current_mode(r, dev->mode);

    kde_output_device_v2_send_scale(r, wl_fixed_from_int(output_scale()));
    kde_output_device_v2_send_edid(r, "");
    kde_output_device_v2_send_enabled(r, 1);
    kde_output_device_v2_send_uuid(r, IOSC_OUTPUT_UUID);
    kde_output_device_v2_send_serial_number(r, "");
    kde_output_device_v2_send_eisa_id(r, "");
    kde_output_device_v2_send_capabilities(r, 0);   /* no overscan/vrr/rgb-range/HDR */
    kde_output_device_v2_send_overscan(r, 0);
    kde_output_device_v2_send_vrr_policy(r, KDE_OUTPUT_DEVICE_V2_VRR_POLICY_NEVER);
    kde_output_device_v2_send_rgb_range(r, KDE_OUTPUT_DEVICE_V2_RGB_RANGE_AUTOMATIC);
    if (ver >= KDE_OUTPUT_DEVICE_V2_NAME_SINCE_VERSION)
        kde_output_device_v2_send_name(r, IOSC_OUTPUT_NAME);
    kde_output_device_v2_send_done(r);
}

static void kde_device_resource_destroy(struct wl_resource *r)
{
    struct iosc_kde_device *dev = wl_resource_get_user_data(r);
    output_res_remove(g_kde_device_res, &g_nkde_device_res, r);
    if (dev) {
        if (dev->mode) {
            wl_resource_set_user_data(dev->mode, NULL);   /* sever back-pointer first */
            wl_resource_destroy(dev->mode);
        }
        free(dev);
    }
}

void kde_output_device_bind(struct wl_client *client, void *data,
                                   uint32_t version, uint32_t id)
{
    (void)data;
    struct wl_resource *r = wl_resource_create(client, &kde_output_device_v2_interface,
                                               version, id);
    if (!r) { wl_client_post_no_memory(client); return; }
    struct iosc_kde_device *dev = calloc(1, sizeof(*dev));
    if (!dev) { wl_resource_destroy(r); wl_client_post_no_memory(client); return; }
    dev->resource = r;
    wl_resource_set_implementation(r, NULL, dev, kde_device_resource_destroy);
    if (g_nkde_device_res < IOSC_MAX_KDE_RES)
        g_kde_device_res[g_nkde_device_res++] = r;
    kde_device_send_state(dev);
}

/* Broadcast the KDE view of the output to every bound device/order/primary
 * resource (device property bursts + order list + primary name). */
void kde_output_broadcast(void)
{
    for (int i = 0; i < g_nkde_device_res; i++) {
        struct iosc_kde_device *dev = wl_resource_get_user_data(g_kde_device_res[i]);
        if (dev) kde_device_send_state(dev);
    }
    for (int i = 0; i < g_nkde_order_res; i++) {
        kde_output_order_v1_send_output(g_kde_order_res[i], IOSC_OUTPUT_NAME);
        kde_output_order_v1_send_done(g_kde_order_res[i]);
    }
    for (int i = 0; i < g_nkde_primary_res; i++)
        kde_primary_output_v1_send_primary_output(g_kde_primary_res[i], IOSC_OUTPUT_NAME);
}

/* Re-advertise all output globals after a change: wl_output, xdg_output,
 * fractional-scale, and the KDE family. Called by the reconfigure core on every
 * applied change, and by the KDE configuration apply path only for a no-op apply
 * (so a real change broadcasts exactly once). */
void broadcast_output_all(void)
{
    for (int i = 0; i < g_nxdg_output_res; i++) {
        zxdg_output_v1_send_logical_position(g_xdg_output_res[i], 0, 0);
        zxdg_output_v1_send_logical_size(g_xdg_output_res[i],
                                         output_logical_width(), output_logical_height());
        if (wl_resource_get_version(g_xdg_output_res[i]) < 3)
            zxdg_output_v1_send_done(g_xdg_output_res[i]);
    }
    for (int i = 0; i < g_noutput_res; i++)
        output_send_state(g_output_res[i]);
    fractional_scale_broadcast();
    kde_output_broadcast();
}

/* -- kde_output_management_v2 / kde_output_configuration_v2 ----------------- */

struct iosc_kde_config {
    struct wl_resource *resource;
    int applied;                    /* apply() called once already */
    int has_enable; int enable;
    int has_mode;   struct wl_resource *mode;
    uint32_t mode_gen;              /* owning device's mode_generation at mode() time;
                                     * 0 = never matched a live mode */
    int has_transform; int transform;
    int has_scale;  wl_fixed_t scale;
};

static void kde_config_res_destroy(struct wl_resource *r)
{
    free(wl_resource_get_user_data(r));
}

static void kde_config_enable(struct wl_client *c, struct wl_resource *r,
                              struct wl_resource *outputdevice, int32_t enable)
{
    (void)c; (void)outputdevice;
    struct iosc_kde_config *cfg = wl_resource_get_user_data(r);
    if (cfg) { cfg->has_enable = 1; cfg->enable = enable; }
}
static void kde_config_mode(struct wl_client *c, struct wl_resource *r,
                            struct wl_resource *outputdevice, struct wl_resource *mode)
{
    (void)c; (void)outputdevice;
    struct iosc_kde_config *cfg = wl_resource_get_user_data(r);
    if (!cfg) return;
    cfg->has_mode = 1;
    cfg->mode = mode;
    /* Stamp the owning device's mode generation so apply can reject a mode that
     * was destroyed+recreated in between (pointer reuse would otherwise pass). */
    cfg->mode_gen = 0;
    for (int i = 0; i < g_nkde_device_res; i++) {
        struct iosc_kde_device *d = wl_resource_get_user_data(g_kde_device_res[i]);
        if (d && d->mode && d->mode == mode) { cfg->mode_gen = d->mode_generation; break; }
    }
}
static void kde_config_transform(struct wl_client *c, struct wl_resource *r,
                                 struct wl_resource *outputdevice, int32_t transform)
{
    (void)c; (void)outputdevice;
    struct iosc_kde_config *cfg = wl_resource_get_user_data(r);
    if (!cfg) return;
    if (transform < 0 || transform > 7) {
        fprintf(stderr, "iosc: kde-output-config: ignoring out-of-range transform %d\n", transform);
        return;
    }
    cfg->has_transform = 1; cfg->transform = transform;
}
static void kde_config_position(struct wl_client *c, struct wl_resource *r,
                                struct wl_resource *outputdevice, int32_t x, int32_t y)
{
    (void)c; (void)r; (void)outputdevice; (void)x; (void)y;   /* single output: ignore */
}
static void kde_config_scale(struct wl_client *c, struct wl_resource *r,
                             struct wl_resource *outputdevice, wl_fixed_t scale)
{
    (void)c; (void)outputdevice;
    struct iosc_kde_config *cfg = wl_resource_get_user_data(r);
    if (cfg) { cfg->has_scale = 1; cfg->scale = scale; }
}
static void kde_config_apply(struct wl_client *c, struct wl_resource *r)
{
    (void)c;
    struct iosc_kde_config *cfg = wl_resource_get_user_data(r);
    if (!cfg) return;
    if (cfg->applied) {
        wl_resource_post_error(r, KDE_OUTPUT_CONFIGURATION_V2_ERROR_ALREADY_APPLIED,
                               "kde_output_configuration_v2 already applied");
        return;
    }
    cfg->applied = 1;   /* once, regardless of success (XML: apply only once) */

    /* Disabling the only output is not allowed. */
    if (cfg->has_enable && cfg->enable == 0) {
        fprintf(stderr, "iosc: kde-output-config: refusing to disable the only output\n");
        kde_output_configuration_v2_send_failed(r);
        return;
    }
    /* Only the advertised mode object, at the generation recorded when mode() was
     * called, is acceptable. Pointer identity alone would wrongly validate a stale
     * reference if the mode was recreated (rotation) and the allocator reused the
     * address. */
    if (cfg->has_mode) {
        int ok = 0;
        for (int i = 0; i < g_nkde_device_res; i++) {
            struct iosc_kde_device *d = wl_resource_get_user_data(g_kde_device_res[i]);
            if (d && d->mode && d->mode == cfg->mode &&
                cfg->mode_gen && d->mode_generation == cfg->mode_gen) { ok = 1; break; }
        }
        if (!ok) {
            fprintf(stderr, "iosc: kde-output-config: unknown or stale mode object -> failed\n");
            kde_output_configuration_v2_send_failed(r);
            return;
        }
    }

    int new_scale = output_scale();
    if (cfg->has_scale) {
        double sd = wl_fixed_to_double(cfg->scale);
        int rs = (int)(sd + 0.5);       /* round to nearest integer */
        if (rs < 1) rs = 1;
        if (rs > 4) rs = 4;             /* clamp [1,4]; a fractional request rounds */
        new_scale = rs;
    }
    int new_transform = cfg->has_transform ? cfg->transform : g_output_transform;

    /* Target PHYSICAL dims: held exactly fixed for a scale-only change (never
     * re-derived from logical, so a non-divisible size cannot grow through the
     * ceil and repeated scale changes cannot drift the IOSurface); swapped for a
     * quarter-turn transform change (same pixels rotated; that path reallocates
     * anyway). */
    int cur_tr = g_output_transform;
    int quarter_turn = (new_transform ^ cur_tr) & 1;
    int new_pw = quarter_turn ? g_height : g_width;
    int new_ph = quarter_turn ? g_width  : g_height;

    fprintf(stderr, "iosc: kde-output-config apply: scale %d->%d transform %d->%d\n",
            output_scale(), new_scale, cur_tr, new_transform);

    int rc = output_reconfigure_px(new_pw, new_ph, new_transform, new_scale);
    if (rc < 0) {
        kde_output_configuration_v2_send_failed(r);
        return;
    }
    if (rc > 0)   /* no-op: the core sent nothing; still hand the applying client a
                   * fresh snapshot before `applied` (a change broadcasts inside). */
        broadcast_output_all();
    kde_output_configuration_v2_send_applied(r);
}
static void kde_config_destroy(struct wl_client *c, struct wl_resource *r)
{ (void)c; wl_resource_destroy(r); }
static void kde_config_overscan(struct wl_client *c, struct wl_resource *r,
                                struct wl_resource *o, uint32_t v)
{ (void)c; (void)r; (void)o; (void)v; fprintf(stderr, "iosc: kde-output-config: ignoring overscan\n"); }
static void kde_config_set_vrr_policy(struct wl_client *c, struct wl_resource *r,
                                      struct wl_resource *o, uint32_t v)
{ (void)c; (void)r; (void)o; (void)v; fprintf(stderr, "iosc: kde-output-config: ignoring set_vrr_policy\n"); }
static void kde_config_set_rgb_range(struct wl_client *c, struct wl_resource *r,
                                     struct wl_resource *o, uint32_t v)
{ (void)c; (void)r; (void)o; (void)v; fprintf(stderr, "iosc: kde-output-config: ignoring set_rgb_range\n"); }
static void kde_config_set_primary_output(struct wl_client *c, struct wl_resource *r,
                                          struct wl_resource *o)
{ (void)c; (void)r; (void)o; fprintf(stderr, "iosc: kde-output-config: ignoring set_primary_output (single output)\n"); }
static void kde_config_set_priority(struct wl_client *c, struct wl_resource *r,
                                    struct wl_resource *o, uint32_t v)
{ (void)c; (void)r; (void)o; (void)v; fprintf(stderr, "iosc: kde-output-config: ignoring set_priority\n"); }
static void kde_config_set_hdr(struct wl_client *c, struct wl_resource *r,
                               struct wl_resource *o, uint32_t v)
{ (void)c; (void)r; (void)o; (void)v; fprintf(stderr, "iosc: kde-output-config: ignoring set_high_dynamic_range\n"); }
static void kde_config_set_sdr_brightness(struct wl_client *c, struct wl_resource *r,
                                          struct wl_resource *o, uint32_t v)
{ (void)c; (void)r; (void)o; (void)v; fprintf(stderr, "iosc: kde-output-config: ignoring set_sdr_brightness\n"); }
static void kde_config_set_wcg(struct wl_client *c, struct wl_resource *r,
                               struct wl_resource *o, uint32_t v)
{ (void)c; (void)r; (void)o; (void)v; fprintf(stderr, "iosc: kde-output-config: ignoring set_wide_color_gamut\n"); }
static void kde_config_set_auto_rotate(struct wl_client *c, struct wl_resource *r,
                                       struct wl_resource *o, uint32_t v)
{ (void)c; (void)r; (void)o; (void)v; fprintf(stderr, "iosc: kde-output-config: ignoring set_auto_rotate_policy\n"); }
static void kde_config_set_icc(struct wl_client *c, struct wl_resource *r,
                               struct wl_resource *o, const char *v)
{ (void)c; (void)r; (void)o; (void)v; fprintf(stderr, "iosc: kde-output-config: ignoring set_icc_profile_path\n"); }
static void kde_config_set_brightness_overrides(struct wl_client *c, struct wl_resource *r,
                                                struct wl_resource *o, int32_t a, int32_t b, int32_t d)
{ (void)c; (void)r; (void)o; (void)a; (void)b; (void)d; fprintf(stderr, "iosc: kde-output-config: ignoring set_brightness_overrides\n"); }
static void kde_config_set_sdr_gamut_wideness(struct wl_client *c, struct wl_resource *r,
                                              struct wl_resource *o, uint32_t v)
{ (void)c; (void)r; (void)o; (void)v; fprintf(stderr, "iosc: kde-output-config: ignoring set_sdr_gamut_wideness\n"); }
static void kde_config_set_color_profile_source(struct wl_client *c, struct wl_resource *r,
                                                struct wl_resource *o, uint32_t v)
{ (void)c; (void)r; (void)o; (void)v; fprintf(stderr, "iosc: kde-output-config: ignoring set_color_profile_source\n"); }
static void kde_config_set_brightness(struct wl_client *c, struct wl_resource *r,
                                      struct wl_resource *o, uint32_t v)
{ (void)c; (void)r; (void)o; (void)v; fprintf(stderr, "iosc: kde-output-config: ignoring set_brightness\n"); }

static const struct kde_output_configuration_v2_interface kde_config_impl = {
    .enable = kde_config_enable,
    .mode = kde_config_mode,
    .transform = kde_config_transform,
    .position = kde_config_position,
    .scale = kde_config_scale,
    .apply = kde_config_apply,
    .destroy = kde_config_destroy,
    .overscan = kde_config_overscan,
    .set_vrr_policy = kde_config_set_vrr_policy,
    .set_rgb_range = kde_config_set_rgb_range,
    .set_primary_output = kde_config_set_primary_output,
    .set_priority = kde_config_set_priority,
    .set_high_dynamic_range = kde_config_set_hdr,
    .set_sdr_brightness = kde_config_set_sdr_brightness,
    .set_wide_color_gamut = kde_config_set_wcg,
    .set_auto_rotate_policy = kde_config_set_auto_rotate,
    .set_icc_profile_path = kde_config_set_icc,
    .set_brightness_overrides = kde_config_set_brightness_overrides,
    .set_sdr_gamut_wideness = kde_config_set_sdr_gamut_wideness,
    .set_color_profile_source = kde_config_set_color_profile_source,
    .set_brightness = kde_config_set_brightness,
};

static void kde_management_create_configuration(struct wl_client *c, struct wl_resource *r,
                                                uint32_t id)
{
    struct iosc_kde_config *cfg = calloc(1, sizeof(*cfg));
    if (!cfg) { wl_client_post_no_memory(c); return; }
    struct wl_resource *cr = wl_resource_create(c, &kde_output_configuration_v2_interface,
                                                wl_resource_get_version(r), id);
    if (!cr) { free(cfg); wl_client_post_no_memory(c); return; }
    cfg->resource = cr;
    wl_resource_set_implementation(cr, &kde_config_impl, cfg, kde_config_res_destroy);
}
static const struct kde_output_management_v2_interface kde_management_impl = {
    .create_configuration = kde_management_create_configuration,
};
void kde_management_bind(struct wl_client *client, void *data, uint32_t version, uint32_t id)
{
    (void)data;
    struct wl_resource *r = wl_resource_create(client, &kde_output_management_v2_interface,
                                               version, id);
    if (!r) { wl_client_post_no_memory(client); return; }
    wl_resource_set_implementation(r, &kde_management_impl, NULL, NULL);
}

/* -- kde_primary_output_v1 -------------------------------------------------- */

static void kde_primary_resource_destroy(struct wl_resource *r)
{ output_res_remove(g_kde_primary_res, &g_nkde_primary_res, r); }
static void kde_primary_destroy(struct wl_client *c, struct wl_resource *r)
{ (void)c; wl_resource_destroy(r); }
static const struct kde_primary_output_v1_interface kde_primary_impl = {
    .destroy = kde_primary_destroy,
};
void kde_primary_bind(struct wl_client *client, void *data, uint32_t version, uint32_t id)
{
    (void)data;
    struct wl_resource *r = wl_resource_create(client, &kde_primary_output_v1_interface,
                                               version, id);
    if (!r) { wl_client_post_no_memory(client); return; }
    wl_resource_set_implementation(r, &kde_primary_impl, NULL, kde_primary_resource_destroy);
    if (g_nkde_primary_res < IOSC_MAX_KDE_RES)
        g_kde_primary_res[g_nkde_primary_res++] = r;
    kde_primary_output_v1_send_primary_output(r, IOSC_OUTPUT_NAME);
}

/* -- kde_output_order_v1 ---------------------------------------------------- */

static void kde_order_resource_destroy(struct wl_resource *r)
{ output_res_remove(g_kde_order_res, &g_nkde_order_res, r); }
static void kde_order_destroy(struct wl_client *c, struct wl_resource *r)
{ (void)c; wl_resource_destroy(r); }
static const struct kde_output_order_v1_interface kde_order_impl = {
    .destroy = kde_order_destroy,
};
void kde_order_bind(struct wl_client *client, void *data, uint32_t version, uint32_t id)
{
    (void)data;
    struct wl_resource *r = wl_resource_create(client, &kde_output_order_v1_interface,
                                               version, id);
    if (!r) { wl_client_post_no_memory(client); return; }
    wl_resource_set_implementation(r, &kde_order_impl, NULL, kde_order_resource_destroy);
    if (g_nkde_order_res < IOSC_MAX_KDE_RES)
        g_kde_order_res[g_nkde_order_res++] = r;
    kde_output_order_v1_send_output(r, IOSC_OUTPUT_NAME);
    kde_output_order_v1_send_done(r);
}

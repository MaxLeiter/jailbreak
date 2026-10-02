/*
 * iosc_pointer_ext.c — the three wl_pointer extension protocols.
 *
 * Split out of iosc.c. All three hang off the same absolute-pointer stream the
 * Xios app sends us, and all three are consumed by the seat/pointer code in
 * iosc.c rather than standing alone:
 *
 *   zwp_relative_pointer_manager_v1  iosc only ever receives ABSOLUTE positions,
 *                                    so handle_motion() synthesises the delta and
 *                                    relptr_send() reports it
 *   zwp_pointer_gestures_v1          trackpad pinch/rotate, fed by XIOS_IN_GESTURE
 *   zwp_pointer_constraints_v1       pointer lock + confinement, which gate the
 *                                    cursor updates in handle_motion()
 *
 * The entry points iosc.c calls back into (relptr_send, handle_gesture,
 * pointer_locked_for, confine_point, constraints_update_focus,
 * constraints_surface_gone) are declared in iosc_internal.h.
 */
#include <wayland-server.h>
#include <wayland-server-protocol.h>
#include "relative-pointer-unstable-v1-server-protocol.h"
#include "pointer-gestures-unstable-v1-server-protocol.h"
#include "pointer-constraints-unstable-v1-server-protocol.h"

#include "iosc_internal.h"
#include "xios_input_socket.h"   /* XIOS_GESTURE_* codes (via XiosProtocol.h) */
#include "iosc_util.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ===========================================================================
 * relative-pointer (zwp_relative_pointer_manager_v1)
 *
 * iosc only ever receives ABSOLUTE positions from the Xios app, so the relative
 * delta is synthesised in handle_motion() (Δ from the previous absolute point)
 * and reported here. Deltas go to the client that currently holds pointer focus.
 * Unaccelerated == accelerated (no pointer accel curve on a touch device).
 * =========================================================================== */

#define IOSC_MAX_RELPTR 32
static struct wl_resource *g_relptr[IOSC_MAX_RELPTR]; static int g_nrelptr;

static void relptr_res_destroy(struct wl_resource *r){ reslist_remove(g_relptr, &g_nrelptr, r); }
static void relptr_destroy(struct wl_client *c, struct wl_resource *r){ (void)c; wl_resource_destroy(r); }
static const struct zwp_relative_pointer_v1_interface relptr_impl = { .destroy = relptr_destroy };

void relptr_send(uint32_t time, double dx, double dy)
{
    if (!g_ptr_focus) return;
    struct wl_client *fc = wl_resource_get_client(g_ptr_focus->resource);
    uint64_t us = (uint64_t)time * 1000u;
    uint32_t hi = (uint32_t)(us >> 32), lo = (uint32_t)(us & 0xffffffffu);
    wl_fixed_t fdx = wl_fixed_from_double(dx), fdy = wl_fixed_from_double(dy);
    for (int i = 0; i < g_nrelptr; i++)
        if (wl_resource_get_client(g_relptr[i]) == fc)
            zwp_relative_pointer_v1_send_relative_motion(g_relptr[i], hi, lo, fdx, fdy, fdx, fdy);
}

static void relptr_mgr_get(struct wl_client *c, struct wl_resource *r, uint32_t id,
                           struct wl_resource *pointer)
{ (void)pointer;
    struct wl_resource *rp = wl_resource_create(c, &zwp_relative_pointer_v1_interface,
                                                wl_resource_get_version(r), id);
    if (!rp) { wl_client_post_no_memory(c); return; }
    wl_resource_set_implementation(rp, &relptr_impl, NULL, relptr_res_destroy);
    if (g_nrelptr < IOSC_MAX_RELPTR) g_relptr[g_nrelptr++] = rp;
}
static void relptr_mgr_destroy(struct wl_client *c, struct wl_resource *r){ (void)c; wl_resource_destroy(r); }
static const struct zwp_relative_pointer_manager_v1_interface relptr_mgr_impl = {
    .destroy = relptr_mgr_destroy, .get_relative_pointer = relptr_mgr_get };
void relptr_mgr_bind(struct wl_client *c, void *data, uint32_t version, uint32_t id)
{ (void)data;
    struct wl_resource *r = wl_resource_create(c, &zwp_relative_pointer_manager_v1_interface, version, id);
    if (!r) { wl_client_post_no_memory(c); return; }
    wl_resource_set_implementation(r, &relptr_mgr_impl, NULL, NULL);
}

/* ===========================================================================
 * pointer-gestures (zwp_pointer_gestures_v1)
 *
 * A Magic Trackpad's pinch and rotate reach the Xios app as UIKit gesture
 * recognizers rather than as touches, so they cross the wire as XIOS_IN_GESTURE
 * and land here. Like axis and relative motion, gestures go to whichever client
 * holds pointer focus.
 *
 * Only pinch has a source today: iPadOS hands an app two-finger pinch and
 * rotation but keeps three- and four-finger swipes for the app switcher and
 * Home, so nothing can drive the swipe interface, and there is no iOS gesture
 * that means "hold". Both are still implemented, because a client that binds
 * this global may create any of the three and an unimplemented resource is a
 * protocol error on first use rather than a quiet no-op. KWin's Wayland backend
 * links the client side of this protocol, which is what makes KDE pinch work
 * without patching KWin.
 * =========================================================================== */

#define IOSC_MAX_PTRGEST 32
static struct wl_resource *g_gswipe[IOSC_MAX_PTRGEST]; static int g_ngswipe;
static struct wl_resource *g_gpinch[IOSC_MAX_PTRGEST]; static int g_ngpinch;
static struct wl_resource *g_ghold[IOSC_MAX_PTRGEST];  static int g_nghold;

static void gswipe_res_destroy(struct wl_resource *r){ reslist_remove(g_gswipe, &g_ngswipe, r); }
static void gpinch_res_destroy(struct wl_resource *r){ reslist_remove(g_gpinch, &g_ngpinch, r); }
static void ghold_res_destroy(struct wl_resource *r) { reslist_remove(g_ghold,  &g_nghold,  r); }
static void gesture_destroy(struct wl_client *c, struct wl_resource *r){ (void)c; wl_resource_destroy(r); }
static const struct zwp_pointer_gesture_swipe_v1_interface gswipe_impl = { .destroy = gesture_destroy };
static const struct zwp_pointer_gesture_pinch_v1_interface gpinch_impl = { .destroy = gesture_destroy };
static const struct zwp_pointer_gesture_hold_v1_interface  ghold_impl  = { .destroy = gesture_destroy };

/* code/x/y/state/mods carry one gesture frame; see XIOS_IN_GESTURE in
 * xios_input_socket.h for the packing. Translation arrives in the same 1/256
 * physical-pixel fixed point AXIS uses, so dividing by output_scale() yields a
 * logical-px wl_fixed directly. Scale and rotation are already wl_fixed by
 * construction (1/256 units), and rotation is a signed value riding in an
 * unsigned wire field. */
void handle_gesture(uint32_t code, int32_t dx256, int32_t dy256,
                           uint32_t scale256, uint32_t rot256)
{
    idle_note_activity();
    if (!g_ptr_focus) return;
    uint32_t kind    = code & 0xffu;
    uint32_t phase   = (code >> 8) & 0xffu;
    uint32_t fingers = (code >> 16) & 0xffu;
    if (!fingers) fingers = 2;

    struct wl_client *fc = wl_resource_get_client(g_ptr_focus->resource);
    struct wl_resource *focus = g_ptr_focus->resource;
    uint32_t t = now_ms();
    uint32_t serial = wl_display_next_serial(g_display);
    wl_fixed_t dx = (wl_fixed_t)(dx256 / output_scale());
    wl_fixed_t dy = (wl_fixed_t)(dy256 / output_scale());
    wl_fixed_t scale = (wl_fixed_t)scale256;
    wl_fixed_t rot = (wl_fixed_t)(int32_t)rot256;
    int cancelled = phase == XIOS_GESTURE_CANCEL;

    if (kind == XIOS_GESTURE_PINCH) {
        for (int i = 0; i < g_ngpinch; i++) {
            struct wl_resource *g = g_gpinch[i];
            if (wl_resource_get_client(g) != fc) continue;
            if (phase == XIOS_GESTURE_BEGIN)
                zwp_pointer_gesture_pinch_v1_send_begin(g, serial, t, focus, fingers);
            else if (phase == XIOS_GESTURE_UPDATE)
                zwp_pointer_gesture_pinch_v1_send_update(g, t, dx, dy, scale, rot);
            else
                zwp_pointer_gesture_pinch_v1_send_end(g, serial, t, cancelled);
        }
    } else if (kind == XIOS_GESTURE_SWIPE) {
        for (int i = 0; i < g_ngswipe; i++) {
            struct wl_resource *g = g_gswipe[i];
            if (wl_resource_get_client(g) != fc) continue;
            if (phase == XIOS_GESTURE_BEGIN)
                zwp_pointer_gesture_swipe_v1_send_begin(g, serial, t, focus, fingers);
            else if (phase == XIOS_GESTURE_UPDATE)
                zwp_pointer_gesture_swipe_v1_send_update(g, t, dx, dy);
            else
                zwp_pointer_gesture_swipe_v1_send_end(g, serial, t, cancelled);
        }
    } else if (kind == XIOS_GESTURE_HOLD) {
        for (int i = 0; i < g_nghold; i++) {
            struct wl_resource *g = g_ghold[i];
            if (wl_resource_get_client(g) != fc) continue;
            if (phase == XIOS_GESTURE_BEGIN)
                zwp_pointer_gesture_hold_v1_send_begin(g, serial, t, focus, fingers);
            else if (phase != XIOS_GESTURE_UPDATE)   /* hold has no update event */
                zwp_pointer_gesture_hold_v1_send_end(g, serial, t, cancelled);
        }
    }
}

static void ptrgest_get(struct wl_client *c, struct wl_resource *r, uint32_t id,
                        struct wl_resource *pointer, const struct wl_interface *iface,
                        const void *impl, wl_resource_destroy_func_t on_destroy,
                        struct wl_resource **arr, int *n)
{ (void)pointer;
    struct wl_resource *g = wl_resource_create(c, iface, wl_resource_get_version(r), id);
    if (!g) { wl_client_post_no_memory(c); return; }
    wl_resource_set_implementation(g, impl, NULL, on_destroy);
    if (*n < IOSC_MAX_PTRGEST) arr[(*n)++] = g;
}
static void ptrgest_get_swipe(struct wl_client *c, struct wl_resource *r, uint32_t id,
                              struct wl_resource *p)
{ ptrgest_get(c, r, id, p, &zwp_pointer_gesture_swipe_v1_interface, &gswipe_impl,
              gswipe_res_destroy, g_gswipe, &g_ngswipe); }
static void ptrgest_get_pinch(struct wl_client *c, struct wl_resource *r, uint32_t id,
                              struct wl_resource *p)
{ ptrgest_get(c, r, id, p, &zwp_pointer_gesture_pinch_v1_interface, &gpinch_impl,
              gpinch_res_destroy, g_gpinch, &g_ngpinch); }
static void ptrgest_get_hold(struct wl_client *c, struct wl_resource *r, uint32_t id,
                             struct wl_resource *p)
{ ptrgest_get(c, r, id, p, &zwp_pointer_gesture_hold_v1_interface, &ghold_impl,
              ghold_res_destroy, g_ghold, &g_nghold); }
static void ptrgest_release(struct wl_client *c, struct wl_resource *r){ (void)c; wl_resource_destroy(r); }
static const struct zwp_pointer_gestures_v1_interface ptrgest_mgr_impl = {
    .get_swipe_gesture = ptrgest_get_swipe,
    .get_pinch_gesture = ptrgest_get_pinch,
    .release           = ptrgest_release,
    .get_hold_gesture  = ptrgest_get_hold };
void ptrgest_mgr_bind(struct wl_client *c, void *data, uint32_t version, uint32_t id)
{ (void)data;
    struct wl_resource *r = wl_resource_create(c, &zwp_pointer_gestures_v1_interface, version, id);
    if (!r) { wl_client_post_no_memory(c); return; }
    wl_resource_set_implementation(r, &ptrgest_mgr_impl, NULL, NULL);
}

/* ===========================================================================
 * pointer-constraints (zwp_pointer_constraints_v1)
 *
 * A constraint targets a surface. It becomes ACTIVE when that surface holds
 * pointer focus (constraints_update_focus, called on focus change + on create).
 *   - locked:  the cursor freezes; handle_motion() reports only relative deltas.
 *   - confined: the cursor is clamped to the requested surface-local region
 *     (or the whole surface when no region was supplied).
 * Lock cursor-position hints are applied when the lock deactivates. Oneshot
 * lifetime constraints are marked dead after their first deactivation.
 * =========================================================================== */

#define IOSC_MAX_CONSTRAINTS 16
struct iosc_constraint {
    struct wl_resource *resource;
    struct iosc_surface *surface;
    int type;            /* 0 = locked, 1 = confined */
    uint32_t lifetime;   /* ZWP_POINTER_CONSTRAINTS_V1_LIFETIME_* */
    int active;
    int dead;            /* oneshot consumed */
    int region_has;
    int region_x0, region_y0, region_x1, region_y1; /* surface-local bbox */
    int hint_has;
    int hint_x, hint_y;   /* surface-local logical coordinates */
};
static struct iosc_constraint *g_constraints[IOSC_MAX_CONSTRAINTS]; static int g_nconstraints;
static struct iosc_constraint *g_active_constraint;

static struct iosc_constraint *constraint_for_surface(struct iosc_surface *s)
{
    if (!s) return NULL;
    for (int i = 0; i < g_nconstraints; i++)
        if (!g_constraints[i]->dead && g_constraints[i]->surface == s)
            return g_constraints[i];
    return NULL;
}
static void constraint_deactivate(struct iosc_constraint *cc)
{
    if (!cc || !cc->active) return;
    cc->active = 0;
    g_motion_input_valid = 0;
    if (cc->type == 0) {
        zwp_locked_pointer_v1_send_unlocked(cc->resource);
        if (cc->hint_has && cc->surface) {
            int w = 0, h = 0;
            surface_output_size(cc->surface, &w, &h);
            int nx = cc->surface->dx + (w > 0 ? clampi(cc->hint_x, 0, w - 1) : 0);
            int ny = cc->surface->dy + (h > 0 ? clampi(cc->hint_y, 0, h - 1) : 0);
            output_damage_add_cursor_at(g_cursor_x, g_cursor_y);
            g_cursor_x = nx; g_cursor_y = ny;
            output_damage_add_cursor_at(g_cursor_x, g_cursor_y);
            if (iosc_app_cursor()) app_cursor_notify();
            else if (g_cursor_visible) recomposite_all();
        }
    }
    else               zwp_confined_pointer_v1_send_unconfined(cc->resource);
    if (cc->lifetime == ZWP_POINTER_CONSTRAINTS_V1_LIFETIME_ONESHOT) cc->dead = 1;
    if (g_active_constraint == cc) g_active_constraint = NULL;
}
static void constraint_activate(struct iosc_constraint *cc)
{
    if (!cc || cc->active) return;
    cc->active = 1;
    g_motion_input_valid = 0;
    g_active_constraint = cc;
    if (cc->type == 0) zwp_locked_pointer_v1_send_locked(cc->resource);
    else               zwp_confined_pointer_v1_send_confined(cc->resource);
}
void constraints_update_focus(struct iosc_surface *newfocus)
{
    if (g_active_constraint && g_active_constraint->surface != newfocus)
        constraint_deactivate(g_active_constraint);
    if (!g_active_constraint) {
        struct iosc_constraint *cc = constraint_for_surface(newfocus);
        if (cc) constraint_activate(cc);
    }
}
int pointer_locked_for(struct iosc_surface *s)
{
    return g_active_constraint && g_active_constraint->active &&
           g_active_constraint->type == 0 && g_active_constraint->surface == s;
}
int confine_point(struct iosc_surface *s, int *x, int *y)
{
    if (!(g_active_constraint && g_active_constraint->active &&
          g_active_constraint->type == 1 && g_active_constraint->surface == s))
        return 0;
    int w = 0, h = 0; surface_output_size(s, &w, &h);
    int x0 = 0, y0 = 0, x1 = w, y1 = h;
    if (g_active_constraint->region_has) {
        x0 = clampi(g_active_constraint->region_x0, 0, w);
        y0 = clampi(g_active_constraint->region_y0, 0, h);
        x1 = clampi(g_active_constraint->region_x1, x0, w);
        y1 = clampi(g_active_constraint->region_y1, y0, h);
    }
    if (x1 > x0) *x = clampi(*x, s->dx + x0, s->dx + x1 - 1);
    if (y1 > y0) *y = clampi(*y, s->dy + y0, s->dy + y1 - 1);
    return 1;
}
void constraints_surface_gone(struct iosc_surface *s)
{
    for (int i = 0; i < g_nconstraints; i++)
        if (g_constraints[i]->surface == s) {
            if (g_constraints[i]->active) constraint_deactivate(g_constraints[i]);
            g_constraints[i]->surface = NULL;
        }
}

static void constraint_res_destroy(struct wl_resource *r)
{
    struct iosc_constraint *cc = wl_resource_get_user_data(r);
    if (!cc) return;
    if (g_active_constraint == cc) g_active_constraint = NULL;
    for (int i = 0; i < g_nconstraints; i++)
        if (g_constraints[i] == cc) { g_constraints[i] = g_constraints[--g_nconstraints]; break; }
    free(cc);
}
static void constraint_destroy_req(struct wl_client *c, struct wl_resource *r){ (void)c; wl_resource_destroy(r); }
static void locked_ptr_set_hint(struct wl_client *c, struct wl_resource *r, wl_fixed_t x, wl_fixed_t y)
{ (void)c;
    struct iosc_constraint *cc = wl_resource_get_user_data(r);
    if (!cc) return;
    cc->hint_has = 1;
    cc->hint_x = wl_fixed_to_int(x);
    cc->hint_y = wl_fixed_to_int(y);
}

static void constraint_copy_region(struct iosc_constraint *cc, struct wl_resource *region)
{
    struct iosc_region *reg = region ? wl_resource_get_user_data(region) : NULL;
    cc->region_has = reg && reg->has;
    if (cc->region_has) {
        cc->region_x0 = reg->x0; cc->region_y0 = reg->y0;
        cc->region_x1 = reg->x1; cc->region_y1 = reg->y1;
    }
}
static void constraint_set_region(struct wl_client *c, struct wl_resource *r, struct wl_resource *region)
{ (void)c;
    struct iosc_constraint *cc = wl_resource_get_user_data(r);
    if (cc) constraint_copy_region(cc, region);
}

static const struct zwp_locked_pointer_v1_interface locked_ptr_impl = {
    .destroy = constraint_destroy_req,
    .set_cursor_position_hint = locked_ptr_set_hint,
    .set_region = constraint_set_region,
};
static const struct zwp_confined_pointer_v1_interface confined_ptr_impl = {
    .destroy = constraint_destroy_req,
    .set_region = constraint_set_region,
};

static void constraint_new(struct wl_client *c, struct wl_resource *r, uint32_t id,
        struct wl_resource *surface, struct wl_resource *region,
        uint32_t lifetime, int type,
        const struct wl_interface *iface, const void *impl)
{
    if (g_nconstraints >= IOSC_MAX_CONSTRAINTS) { wl_client_post_no_memory(c); return; }
    struct iosc_constraint *cc = calloc(1, sizeof(*cc));
    if (!cc) { wl_client_post_no_memory(c); return; }
    cc->resource = wl_resource_create(c, iface, wl_resource_get_version(r), id);
    if (!cc->resource) { free(cc); wl_client_post_no_memory(c); return; }
    cc->surface  = surface ? wl_resource_get_user_data(surface) : NULL;
    cc->type     = type;
    cc->lifetime = lifetime;
    constraint_copy_region(cc, region);
    wl_resource_set_implementation(cc->resource, impl, cc, constraint_res_destroy);
    g_constraints[g_nconstraints++] = cc;
    /* Activate right away if the target already owns the pointer. */
    if (cc->surface && cc->surface == g_ptr_focus && !g_active_constraint)
        constraint_activate(cc);
}
static void constraints_lock_pointer(struct wl_client *c, struct wl_resource *r, uint32_t id,
        struct wl_resource *surface, struct wl_resource *pointer,
        struct wl_resource *region, uint32_t lifetime)
{ (void)pointer;
    constraint_new(c, r, id, surface, region, lifetime, 0,
                   &zwp_locked_pointer_v1_interface, &locked_ptr_impl);
}
static void constraints_confine_pointer(struct wl_client *c, struct wl_resource *r, uint32_t id,
        struct wl_resource *surface, struct wl_resource *pointer,
        struct wl_resource *region, uint32_t lifetime)
{ (void)pointer;
    constraint_new(c, r, id, surface, region, lifetime, 1,
                   &zwp_confined_pointer_v1_interface, &confined_ptr_impl);
}
static void constraints_destroy(struct wl_client *c, struct wl_resource *r){ (void)c; wl_resource_destroy(r); }
static const struct zwp_pointer_constraints_v1_interface constraints_impl = {
    .destroy = constraints_destroy,
    .lock_pointer = constraints_lock_pointer,
    .confine_pointer = constraints_confine_pointer,
};
void constraints_bind(struct wl_client *c, void *data, uint32_t version, uint32_t id)
{ (void)data;
    struct wl_resource *r = wl_resource_create(c, &zwp_pointer_constraints_v1_interface, version, id);
    if (!r) { wl_client_post_no_memory(c); return; }
    wl_resource_set_implementation(r, &constraints_impl, NULL, NULL);
}

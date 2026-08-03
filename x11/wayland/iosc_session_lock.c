/*
 * iosc_session_lock.c — ext-session-lock-v1 (screen locking).
 *
 * Split out of iosc.c. While locked, the output shows ONLY the lock surface
 * (blank black until it maps) and all input is confined to it: surface_at()
 * resolves to it exclusively and keyboard_set_focus() redirects to it, so
 * normal windows can neither show nor steal focus.
 *
 * If the locker dies without unlocking, the session STAYS locked — that is a
 * spec security requirement, not an oversight. A fresh lock request may then
 * take over and unlock.
 *
 * The lock state itself (g_slock) lives in iosc_internal.h rather than here,
 * because it is a compositor-wide mode: the composite path, surface_unmap(),
 * surface_at() and the focus path all have to honour it.
 */
#include <wayland-server.h>
#include <wayland-server-protocol.h>
#include "ext-session-lock-v1-server-protocol.h"

#include "iosc_internal.h"
#include "iosc_util.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ===========================================================================
 * ext-session-lock-v1 (screen locking)
 *
 * State + the render/input/focus confinement hooks live at the top of the file
 * (g_slock; recomposite_all, surface_at, keyboard_set_focus, surface_unmap).
 * This section is just the protocol plumbing: grant/deny the lock, hand out
 * the (single-output) lock surface with an output-sized configure, and unlock.
 * =========================================================================== */

static void slock_surface_destroy_req(struct wl_client *c, struct wl_resource *r)
{ (void)c; wl_resource_destroy(r); }
static void slock_surface_ack_configure(struct wl_client *c, struct wl_resource *r, uint32_t serial)
{ (void)c; (void)r; (void)serial; }   /* single fixed-size configure; nothing to track */
static const struct ext_session_lock_surface_v1_interface slock_surface_impl = {
    .destroy = slock_surface_destroy_req,
    .ack_configure = slock_surface_ack_configure,
};

static void slock_surface_resource_destroy(struct wl_resource *r)
{
    struct iosc_surface *s = wl_resource_get_user_data(r);
    if (!s) return;                     /* disarmed by surface_unmap */
    s->role = IOSC_ROLE_NONE;           /* the wl_surface may be reused */
    if (g_slock.surface == s) {
        g_slock.surface = NULL;
        g_slock.lock_surface = NULL;
        if (g_kbd_focus == s) keyboard_set_focus(NULL);
        output_damage_add_full();
        recomposite_all();              /* blank again while still locked */
    }
}

static void slock_get_lock_surface(struct wl_client *c, struct wl_resource *r, uint32_t id,
                                   struct wl_resource *surf, struct wl_resource *output)
{ (void)output;   /* single output */
    struct iosc_surface *s = surf ? wl_resource_get_user_data(surf) : NULL;
    if (!s) return;
    if (g_slock.lock != r || !g_slock.locked) return;   /* denied lock: inert */
    if (s->role != IOSC_ROLE_NONE) {
        wl_resource_post_error(r, EXT_SESSION_LOCK_V1_ERROR_ROLE,
                               "surface already has a role");
        return;
    }
    if (g_slock.surface) {
        wl_resource_post_error(r, EXT_SESSION_LOCK_V1_ERROR_DUPLICATE_OUTPUT,
                               "output already has a lock surface");
        return;
    }
    struct wl_resource *ls = wl_resource_create(c, &ext_session_lock_surface_v1_interface,
                                                wl_resource_get_version(r), id);
    if (!ls) { wl_client_post_no_memory(c); return; }
    s->role = IOSC_ROLE_LOCK;
    s->dx = 0;
    s->dy = 0;
    g_slock.surface = s;
    g_slock.lock_surface = ls;
    wl_resource_set_implementation(ls, &slock_surface_impl, s, slock_surface_resource_destroy);
    ext_session_lock_surface_v1_send_configure(ls, wl_display_next_serial(g_display),
                                               (uint32_t)output_logical_width(),
                                               (uint32_t)output_logical_height());
    keyboard_set_focus(s);
    fprintf(stderr, "iosc: session-lock surface created (%dx%d configure)\n",
            output_logical_width(), output_logical_height());
}

static void slock_destroy_req(struct wl_client *c, struct wl_resource *r)
{ (void)c;
    /* Plain destroy is only legal while NOT locked through this object (i.e.
     * after a finished event); a locked client must use unlock_and_destroy. */
    if (g_slock.lock == r && g_slock.locked) {
        wl_resource_post_error(r, EXT_SESSION_LOCK_V1_ERROR_INVALID_DESTROY,
                               "destroy while locked (use unlock_and_destroy)");
        return;
    }
    wl_resource_destroy(r);
}

static void slock_unlock_and_destroy(struct wl_client *c, struct wl_resource *r)
{ (void)c;
    if (g_slock.lock != r || !g_slock.locked) {
        wl_resource_post_error(r, EXT_SESSION_LOCK_V1_ERROR_INVALID_UNLOCK,
                               "unlock on a lock that was never granted");
        return;
    }
    g_slock.locked = 0;
    g_slock.lock = NULL;
    fprintf(stderr, "iosc: session UNLOCKED\n");
    keyboard_set_focus(topmost_focusable());
    g_ptr_focus = NULL;                /* next motion re-enters normally */
    output_damage_add_full();
    recomposite_all();                 /* windows come back */
    wl_resource_destroy(r);
}

static const struct ext_session_lock_v1_interface slock_impl = {
    .destroy = slock_destroy_req,
    .get_lock_surface = slock_get_lock_surface,
    .unlock_and_destroy = slock_unlock_and_destroy,
};

static void slock_resource_destroy(struct wl_resource *r)
{
    /* Reached with the session still locked only when the locker died or its
     * client misbehaved: keep the session locked (spec: never unlock on crash);
     * a new ext_session_lock_manager_v1.lock may take over and unlock. */
    if (g_slock.lock == r) {
        g_slock.lock = NULL;
        if (g_slock.locked)
            fprintf(stderr, "iosc: session lock ABANDONED; staying locked "
                            "(run a locker again to take over)\n");
    }
}

static void slock_mgr_lock(struct wl_client *c, struct wl_resource *r, uint32_t id)
{
    struct wl_resource *lk = wl_resource_create(c, &ext_session_lock_v1_interface,
                                                wl_resource_get_version(r), id);
    if (!lk) { wl_client_post_no_memory(c); return; }
    wl_resource_set_implementation(lk, &slock_impl, NULL, slock_resource_destroy);
    if (g_slock.lock) {
        /* Another locker is active: deny (client should destroy the object). */
        ext_session_lock_v1_send_finished(lk);
        fprintf(stderr, "iosc: session-lock denied (already locked)\n");
        return;
    }
    g_slock.lock = lk;
    g_slock.locked = 1;                /* also adopts an abandoned locked session */
    ext_session_lock_v1_send_locked(lk);
    fprintf(stderr, "iosc: session LOCKED\n");
    keyboard_set_focus(NULL);          /* redirected to the lock surface once it exists */
    g_ptr_focus = NULL;
    dnd_cancel_active();               /* a drag can't survive the screen locking */
    touch_cancel_all();                /* nor can in-flight touch sequences */
    pen_leave(now_ms());               /* nor a pen stroke */
    output_damage_add_full();
    recomposite_all();                 /* blank the output right away */
}

static void slock_mgr_destroy(struct wl_client *c, struct wl_resource *r)
{ (void)c; wl_resource_destroy(r); }
static const struct ext_session_lock_manager_v1_interface slock_mgr_impl = {
    .destroy = slock_mgr_destroy,
    .lock = slock_mgr_lock,
};
void slock_mgr_bind(struct wl_client *c, void *data, uint32_t version, uint32_t id)
{ (void)data;
    struct wl_resource *r = wl_resource_create(c, &ext_session_lock_manager_v1_interface, version, id);
    if (!r) { wl_client_post_no_memory(c); return; }
    wl_resource_set_implementation(r, &slock_mgr_impl, NULL, NULL);
}

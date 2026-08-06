/*
 * iosc_idle.c — ext-idle-notify-v1 + idle-inhibit-v1.
 *
 * Split out of iosc.c. Clients register an idle timeout and get told when the
 * seat goes idle and when it comes back; an inhibitor surface suppresses that
 * entirely (a video player keeping the screen awake). Every real input event
 * funnels through idle_note_activity(), which is the module's one entry point
 * from the input paths.
 */
#include <wayland-server.h>
#include <wayland-server-protocol.h>
#include "ext-idle-notify-v1-server-protocol.h"
#include "idle-inhibit-unstable-v1-server-protocol.h"

#include "iosc_internal.h"
#include "iosc_util.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ===========================================================================
 * idle: ext_idle_notifier_v1 (notifications) + zwp_idle_inhibit_manager_v1.
 *
 * Each notification arms a timer for its timeout; input activity (pointer/key)
 * just stamps g_idle_last_activity_ms — no timer syscalls on the hot input
 * path — and sends `resumed` to any that had `idled`. When a timer fires it
 * checks the stamp and re-arms itself for the remaining time if there was
 * activity since it was armed. While any idle inhibitor exists (video players,
 * presentations) the timers never fire idle.
 * =========================================================================== */

#define IOSC_MAX_IDLE_NOTIF 32
struct iosc_idle_notif {
    struct wl_resource *resource;
    uint32_t timeout_ms;
    struct wl_event_source *timer;
    int idled;
};
static struct iosc_idle_notif *g_idle_notifs[IOSC_MAX_IDLE_NOTIF]; static int g_nidle_notifs;
static int g_idle_inhibitors;
static uint32_t g_idle_last_activity_ms;

static int idle_timer_cb(void *data)
{
    struct iosc_idle_notif *n = data;
    if (g_idle_inhibitors > 0) {          /* inhibited: stay awake, re-arm */
        if (n->timer && n->timeout_ms) wl_event_source_timer_update(n->timer, n->timeout_ms);
        return 0;
    }
    uint32_t elapsed = now_ms() - g_idle_last_activity_ms;
    if (elapsed < n->timeout_ms) {        /* activity since arming: sleep the rest */
        if (n->timer) wl_event_source_timer_update(n->timer, n->timeout_ms - elapsed);
        return 0;
    }
    if (!n->idled) { n->idled = 1; ext_idle_notification_v1_send_idled(n->resource); }
    return 0;
}
void idle_note_activity(void)
{
    g_idle_last_activity_ms = now_ms();   /* timers check this lazily when they fire */
    for (int i = 0; i < g_nidle_notifs; i++) {
        struct iosc_idle_notif *n = g_idle_notifs[i];
        if (!n->idled) continue;
        n->idled = 0; ext_idle_notification_v1_send_resumed(n->resource);
        if (n->timer && n->timeout_ms) wl_event_source_timer_update(n->timer, n->timeout_ms);
    }
}

static void idle_notif_destroy_req(struct wl_client *c, struct wl_resource *r){ (void)c; wl_resource_destroy(r); }
static const struct ext_idle_notification_v1_interface idle_notif_impl = { .destroy = idle_notif_destroy_req };
static void idle_notif_res_destroy(struct wl_resource *r)
{
    struct iosc_idle_notif *n = wl_resource_get_user_data(r);
    if (!n) return;
    if (n->timer) wl_event_source_remove(n->timer);
    for (int i = 0; i < g_nidle_notifs; i++)
        if (g_idle_notifs[i] == n) { g_idle_notifs[i] = g_idle_notifs[--g_nidle_notifs]; break; }
    free(n);
}
static void idle_notifier_get(struct wl_client *c, struct wl_resource *r, uint32_t id,
                              uint32_t timeout, struct wl_resource *seat)
{ (void)seat;
    if (g_nidle_notifs >= IOSC_MAX_IDLE_NOTIF) { wl_client_post_no_memory(c); return; }
    struct iosc_idle_notif *n = calloc(1, sizeof(*n));
    if (!n) { wl_client_post_no_memory(c); return; }
    n->resource = wl_resource_create(c, &ext_idle_notification_v1_interface, wl_resource_get_version(r), id);
    if (!n->resource) { free(n); wl_client_post_no_memory(c); return; }
    n->timeout_ms = timeout ? timeout : 1;
    wl_resource_set_implementation(n->resource, &idle_notif_impl, n, idle_notif_res_destroy);
    n->timer = wl_event_loop_add_timer(wl_display_get_event_loop(g_display), idle_timer_cb, n);
    if (n->timer) wl_event_source_timer_update(n->timer, n->timeout_ms);
    g_idle_notifs[g_nidle_notifs++] = n;
}
static void idle_notifier_destroy(struct wl_client *c, struct wl_resource *r){ (void)c; wl_resource_destroy(r); }
static const struct ext_idle_notifier_v1_interface idle_notifier_impl = {
    .destroy = idle_notifier_destroy, .get_idle_notification = idle_notifier_get };
void idle_notifier_bind(struct wl_client *c, void *data, uint32_t version, uint32_t id)
{ (void)data;
    struct wl_resource *r = wl_resource_create(c, &ext_idle_notifier_v1_interface, version, id);
    if (!r) { wl_client_post_no_memory(c); return; }
    wl_resource_set_implementation(r, &idle_notifier_impl, NULL, NULL);
}

static void idle_inhibitor_destroy_req(struct wl_client *c, struct wl_resource *r){ (void)c; wl_resource_destroy(r); }
static const struct zwp_idle_inhibitor_v1_interface idle_inhibitor_impl = { .destroy = idle_inhibitor_destroy_req };
static void idle_inhibitor_res_destroy(struct wl_resource *r){ (void)r; if (g_idle_inhibitors > 0) g_idle_inhibitors--; }
static void idle_inhibit_create(struct wl_client *c, struct wl_resource *r, uint32_t id,
                                struct wl_resource *surface)
{ (void)surface;
    struct wl_resource *inh = wl_resource_create(c, &zwp_idle_inhibitor_v1_interface, wl_resource_get_version(r), id);
    if (!inh) { wl_client_post_no_memory(c); return; }
    wl_resource_set_implementation(inh, &idle_inhibitor_impl, NULL, idle_inhibitor_res_destroy);
    g_idle_inhibitors++;
}
static void idle_inhibit_mgr_destroy(struct wl_client *c, struct wl_resource *r){ (void)c; wl_resource_destroy(r); }
static const struct zwp_idle_inhibit_manager_v1_interface idle_inhibit_mgr_impl = {
    .create_inhibitor = idle_inhibit_create, .destroy = idle_inhibit_mgr_destroy };
void idle_inhibit_mgr_bind(struct wl_client *c, void *data, uint32_t version, uint32_t id)
{ (void)data;
    struct wl_resource *r = wl_resource_create(c, &zwp_idle_inhibit_manager_v1_interface, version, id);
    if (!r) { wl_client_post_no_memory(c); return; }
    wl_resource_set_implementation(r, &idle_inhibit_mgr_impl, NULL, NULL);
}

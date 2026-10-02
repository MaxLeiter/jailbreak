/*
 * iosc_foreign_toplevel.c — zwlr_foreign_toplevel_management_v1.
 *
 * Split out of iosc.c. This is the taskbar/window-list protocol: every mapped
 * toplevel gets a handle per bound manager, and the shell drives
 * activate/minimise/maximise/close through it.
 *
 * The surface code calls in whenever a toplevel's advertised state changes
 * (ftl_toplevel_mapped/closed, ftl_broadcast_state/title/app_id); each handle is
 * stored back on the surface in s->ftl_handles[].
 */
#include <wayland-server.h>
#include <wayland-server-protocol.h>
#include "wlr-foreign-toplevel-management-unstable-v1-server-protocol.h"
#include "xdg-shell-server-protocol.h"   /* xdg_toplevel_send_close */

#include "iosc_internal.h"
#include "iosc_xwm.h"        /* iosc_xwm_request_close for adopted X11 windows */
#include "iosc_util.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ---- zwlr_foreign_toplevel_management_v1 --------------------------------- */
/* The window list as a protocol: a taskbar/overview binds the manager, receives
 * one handle per open toplevel (title/app_id/state), and can activate or close
 * them. State broadcasts hook the existing map/focus/maximize paths above. */

#define IOSC_MAX_FTL_MANAGERS 8
static struct wl_resource *g_ftl_managers[IOSC_MAX_FTL_MANAGERS];
static int g_nftl_managers;
static void ftl_handle_res_destroy(struct wl_resource *r);

/* Build the wl_array of zwlr_foreign_toplevel_handle_v1 state enums. */
static void ftl_state_array(struct iosc_surface *s, struct wl_array *a)
{
    wl_array_init(a);
    uint32_t *e;
    if (s->toplevel_maximized) {
        e = wl_array_add(a, sizeof(uint32_t));
        if (e) *e = ZWLR_FOREIGN_TOPLEVEL_HANDLE_V1_STATE_MAXIMIZED;
    }
    if (s->toplevel_minimized) {
        e = wl_array_add(a, sizeof(uint32_t));
        if (e) *e = ZWLR_FOREIGN_TOPLEVEL_HANDLE_V1_STATE_MINIMIZED;
    }
    if (s == g_kbd_focus) {
        e = wl_array_add(a, sizeof(uint32_t));
        if (e) *e = ZWLR_FOREIGN_TOPLEVEL_HANDLE_V1_STATE_ACTIVATED;
    }
    if (s->toplevel_fullscreen) {
        e = wl_array_add(a, sizeof(uint32_t));
        if (e) *e = ZWLR_FOREIGN_TOPLEVEL_HANDLE_V1_STATE_FULLSCREEN;
    }
}

static void ftl_handle_send_state(struct wl_resource *h, struct iosc_surface *s)
{
    struct wl_array a;
    ftl_state_array(s, &a);
    zwlr_foreign_toplevel_handle_v1_send_state(h, &a);
    wl_array_release(&a);
}

/* Initial dump for a freshly created handle: title, app_id, state, done. */
static void ftl_handle_send_initial(struct wl_resource *h, struct iosc_surface *s)
{
    zwlr_foreign_toplevel_handle_v1_send_title(h, s->title[0] ? s->title : "");
    zwlr_foreign_toplevel_handle_v1_send_app_id(h, s->app_id[0] ? s->app_id : "");
    ftl_handle_send_state(h, s);
    zwlr_foreign_toplevel_handle_v1_send_done(h);
}

static const struct zwlr_foreign_toplevel_handle_v1_interface ftl_handle_impl;

/* Create a handle for surface `s` on manager `m`, register it, dump initial state. */
static struct wl_resource *ftl_new_handle(struct wl_resource *m, struct iosc_surface *s)
{
    if (s->ftl_nhandles >= (int)(sizeof(s->ftl_handles) / sizeof(s->ftl_handles[0])))
        return NULL;
    struct wl_client *c = wl_resource_get_client(m);
    struct wl_resource *h = wl_resource_create(
        c, &zwlr_foreign_toplevel_handle_v1_interface, wl_resource_get_version(m), 0);
    if (!h) return NULL;
    wl_resource_set_implementation(h, &ftl_handle_impl, s, ftl_handle_res_destroy);
    s->ftl_handles[s->ftl_nhandles++] = h;
    zwlr_foreign_toplevel_manager_v1_send_toplevel(m, h);
    ftl_handle_send_initial(h, s);
    return h;
}

void ftl_toplevel_mapped(struct iosc_surface *s)
{
    if (s->role != IOSC_ROLE_TOPLEVEL) return;
    for (int i = 0; i < g_nftl_managers; i++)
        ftl_new_handle(g_ftl_managers[i], s);
}

void ftl_toplevel_closed(struct iosc_surface *s)
{
    for (int i = 0; i < s->ftl_nhandles; i++) {
        zwlr_foreign_toplevel_handle_v1_send_closed(s->ftl_handles[i]);
        wl_resource_set_user_data(s->ftl_handles[i], NULL);   /* handle goes inert */
    }
    s->ftl_nhandles = 0;
}

void ftl_broadcast_state(struct iosc_surface *s)
{
    if (!s) return;
    for (int i = 0; i < s->ftl_nhandles; i++) {
        ftl_handle_send_state(s->ftl_handles[i], s);
        zwlr_foreign_toplevel_handle_v1_send_done(s->ftl_handles[i]);
    }
}

void ftl_broadcast_title(struct iosc_surface *s)
{
    if (!s) return;
    for (int i = 0; i < s->ftl_nhandles; i++) {
        zwlr_foreign_toplevel_handle_v1_send_title(s->ftl_handles[i], s->title);
        zwlr_foreign_toplevel_handle_v1_send_done(s->ftl_handles[i]);
    }
}

void ftl_broadcast_app_id(struct iosc_surface *s)
{
    if (!s) return;
    for (int i = 0; i < s->ftl_nhandles; i++) {
        zwlr_foreign_toplevel_handle_v1_send_app_id(s->ftl_handles[i], s->app_id);
        zwlr_foreign_toplevel_handle_v1_send_done(s->ftl_handles[i]);
    }
}

/* Handle requests. After `closed`, user_data is NULL and requests are ignored. */
static void ftl_handle_res_destroy(struct wl_resource *r)
{
    struct iosc_surface *s = wl_resource_get_user_data(r);
    if (s) reslist_remove(s->ftl_handles, &s->ftl_nhandles, r);
}

static void ftlh_set_maximized(struct wl_client *c, struct wl_resource *h)
{ (void)c; struct iosc_surface *s = wl_resource_get_user_data(h);
  if (s) { s->toplevel_maximized = 1; toplevel_reconfigure_state(s); ftl_broadcast_state(s); } }
static void ftlh_unset_maximized(struct wl_client *c, struct wl_resource *h)
{ (void)c; struct iosc_surface *s = wl_resource_get_user_data(h);
  if (s) { s->toplevel_maximized = 0; toplevel_reconfigure_state(s); ftl_broadcast_state(s); } }
static void ftlh_set_minimized(struct wl_client *c, struct wl_resource *h)
{ (void)c; surface_set_minimized(wl_resource_get_user_data(h), 1); }
static void ftlh_unset_minimized(struct wl_client *c, struct wl_resource *h)
{ (void)c; surface_set_minimized(wl_resource_get_user_data(h), 0); }
static void ftlh_activate(struct wl_client *c, struct wl_resource *h, struct wl_resource *seat)
{ (void)c; (void)seat; struct iosc_surface *s = wl_resource_get_user_data(h);
  if (s) { surface_set_minimized(s, 0); surface_raise(s); keyboard_set_focus(s);
           if (g_output_damage_valid) recomposite_all(); } }
static void ftlh_close(struct wl_client *c, struct wl_resource *h)
{ (void)c; struct iosc_surface *s = wl_resource_get_user_data(h);
  if (s && s->is_xwayland) iosc_xwm_request_close(s->resource);
  else if (s && s->xdg_toplevel) xdg_toplevel_send_close(s->xdg_toplevel); }
static void ftlh_set_rectangle(struct wl_client *c, struct wl_resource *h, struct wl_resource *surf,
                               int32_t x, int32_t y, int32_t w, int32_t ht)
{ (void)c; (void)h; (void)surf; (void)x; (void)y; (void)w; (void)ht; /* minimize hint; unused */ }
static void ftlh_destroy(struct wl_client *c, struct wl_resource *h)
{ (void)c; wl_resource_destroy(h); }
static void ftlh_set_fullscreen(struct wl_client *c, struct wl_resource *h, struct wl_resource *out)
{ (void)c; (void)out; struct iosc_surface *s = wl_resource_get_user_data(h);
  if (s) { s->toplevel_fullscreen = 1; toplevel_reconfigure_state(s); ftl_broadcast_state(s); } }
static void ftlh_unset_fullscreen(struct wl_client *c, struct wl_resource *h)
{ (void)c; struct iosc_surface *s = wl_resource_get_user_data(h);
  if (s) { s->toplevel_fullscreen = 0; toplevel_reconfigure_state(s); ftl_broadcast_state(s); } }

static const struct zwlr_foreign_toplevel_handle_v1_interface ftl_handle_impl = {
    .set_maximized   = ftlh_set_maximized,
    .unset_maximized = ftlh_unset_maximized,
    .set_minimized   = ftlh_set_minimized,
    .unset_minimized = ftlh_unset_minimized,
    .activate        = ftlh_activate,
    .close           = ftlh_close,
    .set_rectangle   = ftlh_set_rectangle,
    .destroy         = ftlh_destroy,
    .set_fullscreen  = ftlh_set_fullscreen,
    .unset_fullscreen = ftlh_unset_fullscreen,
};

static void ftl_manager_stop(struct wl_client *c, struct wl_resource *m)
{ (void)c; zwlr_foreign_toplevel_manager_v1_send_finished(m); wl_resource_destroy(m); }

static const struct zwlr_foreign_toplevel_manager_v1_interface ftl_manager_impl = {
    .stop = ftl_manager_stop,
};

static void ftl_manager_res_destroy(struct wl_resource *m)
{ reslist_remove(g_ftl_managers, &g_nftl_managers, m); }

void ftl_manager_bind(struct wl_client *client, void *data,
                             uint32_t version, uint32_t id)
{
    (void)data;
    struct wl_resource *m = wl_resource_create(
        client, &zwlr_foreign_toplevel_manager_v1_interface, version, id);
    if (!m) { wl_client_post_no_memory(client); return; }
    wl_resource_set_implementation(m, &ftl_manager_impl, NULL, ftl_manager_res_destroy);
    if (g_nftl_managers < IOSC_MAX_FTL_MANAGERS)
        g_ftl_managers[g_nftl_managers++] = m;
    int n = 0;
    for (int i = 0; i < g_nmapped; i++)      /* replay current window list */
        if (g_mapped[i]->role == IOSC_ROLE_TOPLEVEL) { ftl_new_handle(m, g_mapped[i]); n++; }
    fprintf(stderr, "iosc: client bound zwlr_foreign_toplevel_manager_v1 v%u (%d open toplevel(s))\n",
            version, n);
}

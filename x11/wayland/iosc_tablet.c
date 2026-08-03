/*
 * iosc_tablet.c — tablet-v2 (Apple Pencil).
 *
 * Split out of iosc.c. Pencil samples arrive from the Xios app as IOSC_IN_TABLET
 * records and are turned into zwp_tablet_tool_v2 proximity/tip/motion events
 * here. The tool grabs a surface on tip-down and holds it until tip-up, so
 * handle_pencil() resolves the surface once and pen_surface_gone() drops the
 * grab if that surface unmaps underneath it.
 */
#include <wayland-server.h>
#include <wayland-server-protocol.h>
#include "tablet-v2-server-protocol.h"

#include "iosc_internal.h"
#include "iosc_util.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ---- tablet-v2 (Apple Pencil; fed by IOSC_IN_TABLET) ----------------------- *
 * One virtual tablet ("Apple Pencil") with one PEN tool advertising PRESSURE +
 * TILT, announced to every zwp_tablet_seat_v2 as it is created. The iPad 7 has
 * no hover, so each stroke is bracketed proximity_in .. down .. motion ..
 * up .. proximity_out; like touch, the surface under the pen at `down` owns
 * the whole stroke. */

#define IOSC_PEN_UP     0     /* wire phases in iosc_in_msg.state */
#define IOSC_PEN_DOWN   1
#define IOSC_PEN_MOTION 2
#define IOSC_PEN_CANCEL 3

#define IOSC_MAX_TABLET_SEATS 16
struct iosc_tablet_seat {          /* one per zwp_tablet_seat_v2 resource */
    struct wl_resource *seat;
    struct wl_resource *tablet;    /* zwp_tablet_v2 announced on it */
    struct wl_resource *tool;      /* zwp_tablet_tool_v2 (the pen) */
};
static struct iosc_tablet_seat *g_tablet_seats[IOSC_MAX_TABLET_SEATS];
static int g_ntablet_seats;

static struct iosc_surface *g_pen_focus;   /* surface owning the current stroke */
static int g_pen_down;

static struct iosc_tablet_seat *tablet_seat_for_client(struct wl_client *cl)
{
    for (int i = 0; i < g_ntablet_seats; i++)
        if (g_tablet_seats[i] && g_tablet_seats[i]->seat &&
            wl_resource_get_client(g_tablet_seats[i]->seat) == cl)
            return g_tablet_seats[i];
    return NULL;
}

/* End the current stroke: up (if the tip is down) + proximity_out. */
void pen_leave(uint32_t t)
{
    if (!g_pen_focus) return;
    struct iosc_tablet_seat *ts =
        tablet_seat_for_client(wl_resource_get_client(g_pen_focus->resource));
    if (ts && ts->tool) {
        if (g_pen_down)
            zwp_tablet_tool_v2_send_up(ts->tool);
        zwp_tablet_tool_v2_send_proximity_out(ts->tool);
        zwp_tablet_tool_v2_send_frame(ts->tool, t);
    }
    g_pen_focus = NULL;
    g_pen_down = 0;
}

void pen_surface_gone(struct iosc_surface *s)
{
    if (g_pen_focus == s) pen_leave(now_ms());
}

static void pen_send_axes(struct iosc_tablet_seat *ts, struct iosc_surface *s,
                          int x, int y, uint32_t pressure, int tiltx, int tilty)
{
    wl_fixed_t px, py; surface_local_coords(s, x, y, &px, &py);
    zwp_tablet_tool_v2_send_motion(ts->tool, px, py);
    zwp_tablet_tool_v2_send_pressure(ts->tool, pressure > 65535u ? 65535u : pressure);
    zwp_tablet_tool_v2_send_tilt(ts->tool, wl_fixed_from_int(tiltx),
                                 wl_fixed_from_int(tilty));
}

void handle_pencil(int phase, int x, int y, uint32_t pressure, int tiltx, int tilty)
{
    idle_note_activity();
    uint32_t t = now_ms();
    if (phase == IOSC_PEN_CANCEL) { pen_leave(t); return; }
    if (phase == IOSC_PEN_DOWN) {
        struct iosc_surface *hit = surface_at(x, y);   /* honors session lock */
        if (hit != g_pen_focus) pen_leave(t);
        if (!hit) return;
        press_focus(hit);
        int entering = (g_pen_focus != hit);
        g_pen_focus = hit;
        g_pen_down = 1;
        struct iosc_tablet_seat *ts =
            tablet_seat_for_client(wl_resource_get_client(hit->resource));
        if (!ts || !ts->tool || !ts->tablet) return;   /* client has no tablet seat */
        if (entering)
            zwp_tablet_tool_v2_send_proximity_in(ts->tool, wl_display_next_serial(g_display),
                                                 ts->tablet, hit->resource);
        pen_send_axes(ts, hit, x, y, pressure, tiltx, tilty);
        zwp_tablet_tool_v2_send_down(ts->tool, wl_display_next_serial(g_display));
        zwp_tablet_tool_v2_send_frame(ts->tool, t);
        return;
    }
    /* MOTION / UP belong to the stroke's grab surface. */
    if (!g_pen_focus) return;
    struct iosc_tablet_seat *ts =
        tablet_seat_for_client(wl_resource_get_client(g_pen_focus->resource));
    if (!ts || !ts->tool) {
        if (phase == IOSC_PEN_UP) { g_pen_focus = NULL; g_pen_down = 0; }
        return;
    }
    if (phase == IOSC_PEN_MOTION) {
        pen_send_axes(ts, g_pen_focus, x, y, pressure, tiltx, tilty);
        zwp_tablet_tool_v2_send_frame(ts->tool, t);
    } else if (phase == IOSC_PEN_UP) {
        pen_leave(t);   /* up + proximity_out + frame */
    }
}

/* -- protocol plumbing: manager / seat / tablet / tool objects -------------- */

static void tablet_tool_set_cursor(struct wl_client *c, struct wl_resource *r, uint32_t serial,
                                   struct wl_resource *surf, int32_t hx, int32_t hy)
{ (void)c; (void)r; (void)serial; (void)surf; (void)hx; (void)hy; }   /* pen has no cursor here */
static void tablet_obj_destroy_req(struct wl_client *c, struct wl_resource *r)
{ (void)c; wl_resource_destroy(r); }
static const struct zwp_tablet_tool_v2_interface tablet_tool_impl = {
    .set_cursor = tablet_tool_set_cursor,
    .destroy = tablet_obj_destroy_req,
};
static const struct zwp_tablet_v2_interface tablet_impl = {
    .destroy = tablet_obj_destroy_req,
};

static void tablet_tool_res_destroy(struct wl_resource *r)
{
    struct iosc_tablet_seat *ts = wl_resource_get_user_data(r);
    if (ts && ts->tool == r) ts->tool = NULL;
}
static void tablet_res_destroy(struct wl_resource *r)
{
    struct iosc_tablet_seat *ts = wl_resource_get_user_data(r);
    if (ts && ts->tablet == r) ts->tablet = NULL;
}
static void tablet_seat_res_destroy(struct wl_resource *r)
{
    struct iosc_tablet_seat *ts = wl_resource_get_user_data(r);
    if (!ts) return;
    /* Disarm surviving child resources so their destructors don't touch us. */
    if (ts->tool)   wl_resource_set_user_data(ts->tool, NULL);
    if (ts->tablet) wl_resource_set_user_data(ts->tablet, NULL);
    for (int i = 0; i < g_ntablet_seats; i++)
        if (g_tablet_seats[i] == ts) {
            g_tablet_seats[i] = g_tablet_seats[--g_ntablet_seats];
            break;
        }
    free(ts);
}

static const struct zwp_tablet_seat_v2_interface tablet_seat_impl = {
    .destroy = tablet_obj_destroy_req,
};

static void tablet_mgr_get_tablet_seat(struct wl_client *c, struct wl_resource *r,
                                       uint32_t id, struct wl_resource *seat)
{ (void)seat;
    if (g_ntablet_seats >= IOSC_MAX_TABLET_SEATS) { wl_client_post_no_memory(c); return; }
    struct iosc_tablet_seat *ts = calloc(1, sizeof(*ts));
    if (!ts) { wl_client_post_no_memory(c); return; }
    uint32_t v = wl_resource_get_version(r);
    ts->seat   = wl_resource_create(c, &zwp_tablet_seat_v2_interface, v, id);
    ts->tablet = wl_resource_create(c, &zwp_tablet_v2_interface, v, 0);
    ts->tool   = wl_resource_create(c, &zwp_tablet_tool_v2_interface, v, 0);
    if (!ts->seat || !ts->tablet || !ts->tool) {
        if (ts->seat)   wl_resource_destroy(ts->seat);
        if (ts->tablet) wl_resource_destroy(ts->tablet);
        if (ts->tool)   wl_resource_destroy(ts->tool);
        free(ts);
        wl_client_post_no_memory(c);
        return;
    }
    wl_resource_set_implementation(ts->seat,   &tablet_seat_impl, ts, tablet_seat_res_destroy);
    wl_resource_set_implementation(ts->tablet, &tablet_impl,      ts, tablet_res_destroy);
    wl_resource_set_implementation(ts->tool,   &tablet_tool_impl, ts, tablet_tool_res_destroy);
    g_tablet_seats[g_ntablet_seats++] = ts;
    /* Announce the pencil: tablet first, then the pen tool with its axes. */
    zwp_tablet_seat_v2_send_tablet_added(ts->seat, ts->tablet);
    zwp_tablet_v2_send_name(ts->tablet, "Apple Pencil");
    zwp_tablet_v2_send_path(ts->tablet, "iosc/pencil");
    zwp_tablet_v2_send_done(ts->tablet);
    zwp_tablet_seat_v2_send_tool_added(ts->seat, ts->tool);
    zwp_tablet_tool_v2_send_type(ts->tool, ZWP_TABLET_TOOL_V2_TYPE_PEN);
    zwp_tablet_tool_v2_send_capability(ts->tool, ZWP_TABLET_TOOL_V2_CAPABILITY_PRESSURE);
    zwp_tablet_tool_v2_send_capability(ts->tool, ZWP_TABLET_TOOL_V2_CAPABILITY_TILT);
    zwp_tablet_tool_v2_send_done(ts->tool);
    fprintf(stderr, "iosc: tablet seat created (now %d)\n", g_ntablet_seats);
}

static const struct zwp_tablet_manager_v2_interface tablet_mgr_impl = {
    .get_tablet_seat = tablet_mgr_get_tablet_seat,
    .destroy = tablet_obj_destroy_req,
};
void tablet_mgr_bind(struct wl_client *c, void *data, uint32_t version, uint32_t id)
{ (void)data;
    struct wl_resource *r = wl_resource_create(c, &zwp_tablet_manager_v2_interface, version, id);
    if (!r) { wl_client_post_no_memory(c); return; }
    wl_resource_set_implementation(r, &tablet_mgr_impl, NULL, NULL);
}

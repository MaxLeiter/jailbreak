/*
 * iosc-ftl-test.c — a tiny zwlr_foreign_toplevel_management_v1 client, to
 * validate iosc's taskbar/window-list implementation (§5.2) without the full
 * panel. It binds the manager, logs every toplevel handle it is told about
 * (title / app_id / state / done / closed), and can drive one of them:
 *
 *   iosc-ftl-test              just list the open windows (then keep listening)
 *   iosc-ftl-test -activate N  activate the Nth toplevel (0-based, in arrival order)
 *   iosc-ftl-test -close N     ask the Nth toplevel to close
 *
 * MIT. Standard libwayland-client boilerplate.
 */
#include <wayland-client.h>
#include "wlr-foreign-toplevel-management-unstable-v1-client-protocol.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static struct zwlr_foreign_toplevel_manager_v1 *manager;
static struct wl_seat *seat;

#define MAXH 32
static struct zwlr_foreign_toplevel_handle_v1 *handles[MAXH];
static char titles[MAXH][256];
static int  nhandles;

static int   opt_activate = -1, opt_close = -1;
static int   acted = 0;

static const char *state_names(struct wl_array *st, char *out, size_t n)
{
    out[0] = 0;
    uint32_t *s;
    wl_array_for_each(s, st) {
        const char *nm = *s == ZWLR_FOREIGN_TOPLEVEL_HANDLE_V1_STATE_MAXIMIZED  ? "max"
                       : *s == ZWLR_FOREIGN_TOPLEVEL_HANDLE_V1_STATE_MINIMIZED  ? "min"
                       : *s == ZWLR_FOREIGN_TOPLEVEL_HANDLE_V1_STATE_ACTIVATED  ? "active"
                       : *s == ZWLR_FOREIGN_TOPLEVEL_HANDLE_V1_STATE_FULLSCREEN ? "fs" : "?";
        strncat(out, nm, n - strlen(out) - 1);
        strncat(out, " ", n - strlen(out) - 1);
    }
    return out;
}

static int handle_index(struct zwlr_foreign_toplevel_handle_v1 *h)
{
    for (int i = 0; i < nhandles; i++) if (handles[i] == h) return i;
    return -1;
}

static void h_title(void *d, struct zwlr_foreign_toplevel_handle_v1 *h, const char *t)
{ (void)d; int i = handle_index(h); if (i >= 0) snprintf(titles[i], sizeof(titles[i]), "%s", t);
  fprintf(stderr, "ftl: [%d] title=\"%s\"\n", i, t); }
static void h_app_id(void *d, struct zwlr_foreign_toplevel_handle_v1 *h, const char *a)
{ (void)d; fprintf(stderr, "ftl: [%d] app_id=\"%s\"\n", handle_index(h), a); }
static void h_output_enter(void *d, struct zwlr_foreign_toplevel_handle_v1 *h, struct wl_output *o)
{ (void)d; (void)h; (void)o; }
static void h_output_leave(void *d, struct zwlr_foreign_toplevel_handle_v1 *h, struct wl_output *o)
{ (void)d; (void)h; (void)o; }
static void h_state(void *d, struct zwlr_foreign_toplevel_handle_v1 *h, struct wl_array *st)
{ (void)d; char b[128]; fprintf(stderr, "ftl: [%d] state: %s\n", handle_index(h), state_names(st, b, sizeof(b))); }
static void h_done(void *d, struct zwlr_foreign_toplevel_handle_v1 *h)
{ (void)d; (void)h; }
static void h_closed(void *d, struct zwlr_foreign_toplevel_handle_v1 *h)
{ (void)d; int i = handle_index(h); fprintf(stderr, "ftl: [%d] CLOSED\n", i);
  if (i >= 0) handles[i] = NULL;
  zwlr_foreign_toplevel_handle_v1_destroy(h); }
static void h_parent(void *d, struct zwlr_foreign_toplevel_handle_v1 *h,
                     struct zwlr_foreign_toplevel_handle_v1 *p)
{ (void)d; (void)h; (void)p; }
static const struct zwlr_foreign_toplevel_handle_v1_listener h_listener = {
    .title = h_title, .app_id = h_app_id, .output_enter = h_output_enter,
    .output_leave = h_output_leave, .state = h_state, .done = h_done,
    .closed = h_closed, .parent = h_parent,
};

static void m_toplevel(void *d, struct zwlr_foreign_toplevel_manager_v1 *m,
                       struct zwlr_foreign_toplevel_handle_v1 *h)
{
    (void)d; (void)m;
    int i = nhandles < MAXH ? nhandles++ : MAXH - 1;
    handles[i] = h;
    titles[i][0] = 0;
    fprintf(stderr, "ftl: toplevel [%d] appeared\n", i);
    zwlr_foreign_toplevel_handle_v1_add_listener(h, &h_listener, NULL);
}
static void m_finished(void *d, struct zwlr_foreign_toplevel_manager_v1 *m)
{ (void)d; (void)m; fprintf(stderr, "ftl: manager finished\n"); }
static const struct zwlr_foreign_toplevel_manager_v1_listener m_listener = {
    .toplevel = m_toplevel, .finished = m_finished,
};

static void reg_global(void *data, struct wl_registry *reg, uint32_t name,
                       const char *iface, uint32_t version)
{
    (void)data; (void)version;
    if (!strcmp(iface, "zwlr_foreign_toplevel_manager_v1"))
        manager = wl_registry_bind(reg, name, &zwlr_foreign_toplevel_manager_v1_interface,
                                   version < 3 ? version : 3);
    else if (!strcmp(iface, "wl_seat"))
        seat = wl_registry_bind(reg, name, &wl_seat_interface, 1);
}
static void reg_global_remove(void *d, struct wl_registry *r, uint32_t n)
{ (void)d; (void)r; (void)n; }
static const struct wl_registry_listener registry_listener = {
    .global = reg_global, .global_remove = reg_global_remove,
};

int main(int argc, char **argv)
{
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-activate") && i + 1 < argc) opt_activate = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-close") && i + 1 < argc) opt_close = atoi(argv[++i]);
    }

    struct wl_display *dpy = wl_display_connect(NULL);
    if (!dpy) { fprintf(stderr, "ftl: wl_display_connect failed\n"); return 1; }
    struct wl_registry *reg = wl_display_get_registry(dpy);
    wl_registry_add_listener(reg, &registry_listener, NULL);
    wl_display_roundtrip(dpy);      /* globals */
    if (!manager) {
        fprintf(stderr, "ftl: compositor lacks zwlr_foreign_toplevel_manager_v1\n");
        return 1;
    }
    zwlr_foreign_toplevel_manager_v1_add_listener(manager, &m_listener, NULL);
    wl_display_roundtrip(dpy);      /* toplevel events + their initial state */
    wl_display_roundtrip(dpy);
    fprintf(stderr, "ftl: %d open toplevel(s)\n", nhandles);

    if (opt_activate >= 0 && opt_activate < nhandles && handles[opt_activate] && seat) {
        fprintf(stderr, "ftl: activating [%d] \"%s\"\n", opt_activate, titles[opt_activate]);
        zwlr_foreign_toplevel_handle_v1_activate(handles[opt_activate], seat);
        acted = 1;
    }
    if (opt_close >= 0 && opt_close < nhandles && handles[opt_close]) {
        fprintf(stderr, "ftl: closing [%d] \"%s\"\n", opt_close, titles[opt_close]);
        zwlr_foreign_toplevel_handle_v1_close(handles[opt_close]);
        acted = 1;
    }
    if (acted) wl_display_flush(dpy);

    while (wl_display_dispatch(dpy) != -1)
        ;
    wl_display_disconnect(dpy);
    return 0;
}

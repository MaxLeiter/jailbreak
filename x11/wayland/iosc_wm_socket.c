/*
 * iosc_wm_socket.c — the wm control socket (/var/jb/tmp/iosc-wm.sock).
 *
 * Split out of iosc.c. A tiny line-oriented AF_UNIX protocol that lets the Xios
 * app (and shell tooling) raise, focus and minimise windows by app_id without
 * speaking Wayland — the same raise+focus the xdg-activation path performs.
 */
#include <wayland-server.h>
#include <wayland-server-protocol.h>

#include "iosc_internal.h"
#include "iosc_util.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <errno.h>

/* ---- wm control socket (/var/jb/tmp/iosc-wm.sock) ------------------------ */
/* A tiny line protocol so a NON-Wayland client (ioscd, the panel) can raise an
 * existing window by app_id without becoming a wl client: `raise\t<app_id>\n` ->
 * surface_raise + keyboard_set_focus, reply "ok\n" / "notfound\n". This is the
 * "second-tap raises the live window" hook (docs/iosc-desktop-env.md §7); it just
 * drives the same raise+focus the xdg-activation path does, keyed by the app_id
 * we already store on the surface. Graceful-degrades: absent, the window is still
 * mapped, it just may not restack to the top. */

#define IOSC_MAX_WM_CLIENTS 8
#define IOSC_WM_BUF 256
struct iosc_wm_client { int fd; struct wl_event_source *src; char buf[IOSC_WM_BUF]; int have; };
static struct iosc_wm_client *g_wm_clients[IOSC_MAX_WM_CLIENTS];

static struct iosc_surface *wm_find_toplevel_by_app_id(const char *app_id)
{
    if (!app_id || !*app_id) return NULL;
    for (int i = g_nmapped - 1; i >= 0; i--) {   /* top-most match wins */
        struct iosc_surface *s = g_mapped[i];
        if (s->role == IOSC_ROLE_TOPLEVEL && s->app_id[0] &&
            strcmp(s->app_id, app_id) == 0)
            return s;
    }
    return NULL;
}

static int wm_raise_app(const char *app_id)
{
    struct iosc_surface *s = wm_find_toplevel_by_app_id(app_id);
    if (!s) return 0;
    surface_set_minimized(s, 0);
    surface_raise(s);
    keyboard_set_focus(s);
    if (g_output_damage_valid) recomposite_all();
    wl_display_flush_clients(g_display);
    fprintf(stderr, "iosc: wm raise app_id=\"%s\" -> raised\n", app_id);
    return 1;
}

/* Handle one line: "raise\t<app_id>". Best-effort reply on fd. */
static void wm_handle_line(int fd, char *line)
{
    char *tab = strchr(line, '\t');
    const char *reply = "err\n";
    if (tab && (size_t)(tab - line) == 5 && strncmp(line, "raise", 5) == 0)
        reply = wm_raise_app(tab + 1) ? "ok\n" : "notfound\n";
    ssize_t n = write(fd, reply, strlen(reply));   /* best-effort */
    (void)n;
}

static void wm_client_drop(struct iosc_wm_client *c)
{
    if (!c) return;
    for (int i = 0; i < IOSC_MAX_WM_CLIENTS; i++)
        if (g_wm_clients[i] == c) g_wm_clients[i] = NULL;
    if (c->src) wl_event_source_remove(c->src);
    if (c->fd >= 0) close(c->fd);
    free(c);
}

static int wm_client_readable(int fd, uint32_t mask, void *data)
{
    struct iosc_wm_client *c = data;
    if (mask & (WL_EVENT_HANGUP | WL_EVENT_ERROR)) { wm_client_drop(c); return 0; }
    for (;;) {
        if (c->have >= IOSC_WM_BUF - 1) c->have = 0;   /* overflow: drop partial */
        ssize_t r = read(fd, c->buf + c->have, IOSC_WM_BUF - 1 - c->have);
        if (r > 0) {
            c->have += (int)r;
            char *nl;
            while ((nl = memchr(c->buf, '\n', (size_t)c->have)) != NULL) {
                *nl = 0;
                char *cr = strchr(c->buf, '\r'); if (cr) *cr = 0;
                wm_handle_line(fd, c->buf);
                int consumed = (int)(nl + 1 - c->buf);
                c->have -= consumed;
                memmove(c->buf, nl + 1, (size_t)c->have);
            }
            continue;
        }
        if (r == 0) { wm_client_drop(c); return 0; }
        if (errno == EAGAIN || errno == EWOULDBLOCK) break;
        if (errno == EINTR) continue;
        wm_client_drop(c); return 0;
    }
    return 0;
}

static int wm_listen_readable(int fd, uint32_t mask, void *data)
{
    (void)mask;
    struct wl_event_loop *loop = data;
    int cfd = accept(fd, NULL, NULL);
    if (cfd < 0) return 0;
    fcntl(cfd, F_SETFL, fcntl(cfd, F_GETFL, 0) | O_NONBLOCK);
    int slot = -1;
    for (int i = 0; i < IOSC_MAX_WM_CLIENTS; i++) if (!g_wm_clients[i]) { slot = i; break; }
    if (slot < 0) { close(cfd); return 0; }
    struct iosc_wm_client *c = calloc(1, sizeof(*c));
    if (!c) { close(cfd); return 0; }
    c->fd = cfd;
    c->src = wl_event_loop_add_fd(loop, cfd, WL_EVENT_READABLE, wm_client_readable, c);
    g_wm_clients[slot] = c;
    return 0;
}

int wm_socket_start(struct wl_event_loop *loop, const char *path)
{
    /* ioscd / the panel connect from outside the app sandbox; unix_listen_start
     * hands the socket to mobile with 0660 permissions. */
    return unix_listen_start(loop, path, wm_listen_readable);
}

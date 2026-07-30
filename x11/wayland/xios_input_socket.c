/*
 * xios_input_socket.c — the Xios app input-socket reader. See xios_input_socket.h.
 *
 * Extracted from iosc.c's inline reader (in_client_readable / in_listen_readable /
 * input_socket_start) so iosc and MetaBackendIOS share one framing implementation.
 * The per-client state machine is identical; only the transport around it changed:
 * a single owned kqueue multiplexes the listen socket + client sockets into one
 * pollable fd, and complete records go to a caller callback instead of straight to
 * iosc's handle_*.
 */
#include "xios_input_socket.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <sys/event.h>
#include <pwd.h>

#define XIOS_MAX_INPUT_CLIENTS 16
#define XIOS_IN_TEXT_MAX       4096u

struct xios_in_client {
    int fd;
    uint32_t bound_window;
    int improxy;              /* registered XIOS_IN_IMPROXY: input-method proxy */
    int hello_received;
    uint8_t hdr[sizeof(xios_msg)];
    int hdr_have;
    xios_msg msg;
    char *payload;
    uint32_t payload_have;
};

struct xios_input_socket {
    int listen_fd;
    int kq;
    char path[108];   /* sun_path max */
    struct xios_in_client *clients[XIOS_MAX_INPUT_CLIENTS];
};

static void chmod_mobile_socket(const char *path)
{
    struct passwd *pw = getpwnam("mobile");
    uid_t uid = pw ? pw->pw_uid : 501;
    gid_t gid = pw ? pw->pw_gid : 501;
    if (chown(path, uid, gid) == 0) {
        chmod(path, 0660);
    } else {
        chmod(path, 0600);
        fprintf(stderr, "xios_input_socket: keeping %s owner-only; chown mobile failed: %s\n",
                path, strerror(errno));
    }
}

static void set_nonblock(int fd)
{
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK);
}

xios_input_socket *xios_input_socket_new(const char *path)
{
    if (!path) return NULL;
    if (strlen(path) >= sizeof(((struct sockaddr_un *)0)->sun_path)) return NULL;
    xios_input_socket *s = calloc(1, sizeof(*s));
    if (!s) return NULL;
    s->listen_fd = -1;
    s->kq = -1;
    snprintf(s->path, sizeof(s->path), "%s", path);

    unlink(path);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) { free(s); return NULL; }
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, path, sizeof(addr.sun_path) - 1);
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) { close(fd); free(s); return NULL; }
    if (listen(fd, 4) < 0) { close(fd); free(s); return NULL; }
    /* The Xios app runs as mobile and must connect. Prefer mobile-owned 0660;
     * fall back to owner-only rather than opening the socket to every uid. */
    chmod_mobile_socket(path);
    set_nonblock(fd);
    s->listen_fd = fd;

    s->kq = kqueue();
    if (s->kq < 0) { close(fd); free(s); return NULL; }
    struct kevent kev;
    EV_SET(&kev, fd, EVFILT_READ, EV_ADD, 0, 0, NULL);   /* udata NULL = the listener */
    if (kevent(s->kq, &kev, 1, NULL, 0, NULL) < 0) {
        close(s->kq); close(fd); free(s); return NULL;
    }
    return s;
}

int xios_input_socket_fd(xios_input_socket *s)
{
    return s ? s->kq : -1;
}

static void client_drop(xios_input_socket *s, struct xios_in_client *c)
{
    if (!c) return;
    for (int i = 0; i < XIOS_MAX_INPUT_CLIENTS; i++)
        if (s->clients[i] == c) s->clients[i] = NULL;
    struct kevent kev;
    EV_SET(&kev, c->fd, EVFILT_READ, EV_DELETE, 0, 0, NULL);
    kevent(s->kq, &kev, 1, NULL, 0, NULL);   /* closing the fd also clears it */
    if (c->fd >= 0) close(c->fd);
    free(c->payload);
    free(c);
}

static void client_reset(struct xios_in_client *c)
{
    free(c->payload);
    c->payload = NULL;
    c->payload_have = 0;
    c->hdr_have = 0;
    memset(&c->msg, 0, sizeof(c->msg));
}

static int is_client_message(uint32_t type)
{
    switch (type) {
    case XIOS_IN_MOTION:
    case XIOS_IN_BUTTON:
    case XIOS_IN_KEY:
    case XIOS_IN_TEXT:
    case XIOS_IN_TOUCH:
    case XIOS_IN_TABLET:
    case XIOS_IN_BIND:
    case XIOS_IN_AXIS:
    case XIOS_IN_OUTPUT:
    case XIOS_IN_GESTURE:
    case XIOS_IN_IMPROXY:
    case XIOS_IN_VOLUME:
    case XIOS_IN_APPEARANCE:
    case XIOS_IN_BRIGHTNESS:
        return 1;
    case XIOS_IN_TRAITS:
        return 1; /* accepted below only from an authenticated improxy */
    default:
        return 0;
    }
}

static int write_all(int fd, const void *buf, size_t len);

static int send_hello(int fd)
{
    xios_msg hello = xios_protocol_hello();
    return write_all(fd, &hello, sizeof(hello));
}

/* Drain a readable client, invoking cb for each complete record. Returns the
 * number dispatched; sets *closed if the client hit EOF/error and was dropped. */
static int client_read(xios_input_socket *s, struct xios_in_client *c,
                       xios_input_cb cb, void *user, int *closed)
{
    int n = 0;
    for (;;) {
        if (c->hdr_have < (int)sizeof(c->hdr)) {
            ssize_t r = read(c->fd, c->hdr + c->hdr_have, sizeof(c->hdr) - (size_t)c->hdr_have);
            if (r > 0) {
                c->hdr_have += (int)r;
                if (c->hdr_have < (int)sizeof(c->hdr)) continue;
                memcpy(&c->msg, c->hdr, sizeof(c->msg));
                if (!c->hello_received) {
                    if (!xios_protocol_is_exact_hello(&c->msg)) goto drop;
                    c->hello_received = 1;
                    client_reset(c);
                    continue;
                }
                if (c->msg.magic != XIOS_MSG_MAGIC ||
                    c->msg.type == XIOS_MSG_HELLO ||
                    !is_client_message(c->msg.type))
                    goto drop;
                if (c->msg.type != XIOS_IN_TEXT && c->msg.length != 0)
                    goto drop;
                if (c->msg.type == XIOS_IN_BIND) {
                    c->bound_window = XIOS_INPUT_CODE(&c->msg);
                    client_reset(c);
                } else if (c->msg.type == XIOS_IN_IMPROXY) {
                    c->improxy = XIOS_INPUT_CODE(&c->msg) ? 1 : 0;
                    client_reset(c);
                } else if (c->msg.type == XIOS_IN_TRAITS && !c->improxy) {
                    goto drop;
                } else if (c->msg.type == XIOS_IN_TEXT) {
                    if (c->msg.length == 0 ||
                        c->msg.length > XIOS_IN_TEXT_MAX ||
                        XIOS_INPUT_CODE(&c->msg) != c->msg.length)
                        goto drop;
                    c->payload = calloc(1, c->msg.length + 1u);
                    if (!c->payload) goto drop;
                } else {
                    if (cb) cb(&c->msg, NULL, 0, c->bound_window, user);
                    n++;
                    client_reset(c);
                }
                continue;
            }
            if (r == 0) goto drop;
            if (errno == EAGAIN || errno == EWOULDBLOCK) break;
            if (errno == EINTR) continue;
            goto drop;
        }
        while (c->msg.type == XIOS_IN_TEXT && c->payload_have < c->msg.length) {
            ssize_t r = read(c->fd, c->payload + c->payload_have,
                             c->msg.length - c->payload_have);
            if (r > 0) { c->payload_have += (uint32_t)r; continue; }
            if (r == 0) goto drop;
            if (errno == EAGAIN || errno == EWOULDBLOCK) return n;
            if (errno == EINTR) continue;
            goto drop;
        }
        if (c->msg.type == XIOS_IN_TEXT) {
            if (cb) cb(&c->msg, c->payload, c->msg.length, c->bound_window, user);
            n++;
            client_reset(c);
            continue;
        }
    }
    return n;
drop:
    client_drop(s, c);
    if (closed) *closed = 1;
    return n;
}

static void accept_clients(xios_input_socket *s)
{
    for (;;) {
        int cfd = accept(s->listen_fd, NULL, NULL);
        if (cfd < 0) break;                 /* EAGAIN when no more pending */
        int on = 1;                         /* broadcast writes must get EPIPE, not SIGPIPE */
        setsockopt(cfd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));
        if (send_hello(cfd) != 0) { close(cfd); continue; }
        set_nonblock(cfd);
        int slot = -1;
        for (int i = 0; i < XIOS_MAX_INPUT_CLIENTS; i++)
            if (!s->clients[i]) { slot = i; break; }
        if (slot < 0) { close(cfd); continue; }
        struct xios_in_client *c = calloc(1, sizeof(*c));
        if (!c) { close(cfd); continue; }
        c->fd = cfd;
        struct kevent kev;
        EV_SET(&kev, cfd, EVFILT_READ, EV_ADD, 0, 0, c);
        if (kevent(s->kq, &kev, 1, NULL, 0, NULL) < 0) { close(cfd); free(c); continue; }
        s->clients[slot] = c;
    }
}

int xios_input_socket_dispatch(xios_input_socket *s, xios_input_cb cb, void *user)
{
    if (!s || s->kq < 0) return -1;
    struct kevent evs[8];
    struct timespec zero = { 0, 0 };
    int n = kevent(s->kq, NULL, 0, evs, 8, &zero);
    if (n < 0) return (errno == EINTR) ? 0 : -1;

    int dispatched = 0;
    for (int i = 0; i < n; i++) {
        if ((int)evs[i].ident == s->listen_fd) {
            accept_clients(s);
            continue;
        }
        struct xios_in_client *c = (struct xios_in_client *)evs[i].udata;
        if (!c) continue;
        int closed = 0;
        dispatched += client_read(s, c, cb, user, &closed);
        if (!closed && (evs[i].flags & EV_EOF))
            client_drop(s, c);
    }
    return dispatched;
}

static int write_all(int fd, const void *buf, size_t len)
{
    const char *p = buf;
    size_t put = 0;
    while (put < len) {
        ssize_t w = write(fd, p + put, len - put);
        if (w > 0) { put += (size_t)w; continue; }
        if (w < 0 && errno == EINTR) continue;
        return -1;
    }
    return 0;
}

static int client_matches_bound(struct xios_in_client *c, uint32_t bound_window)
{
    return bound_window == 0 || c->bound_window == 0 || c->bound_window == bound_window;
}

static int broadcast_to_clients(xios_input_socket *s, uint32_t bound_window,
                                const void *buf, size_t len)
{
    if (!s || !buf || len == 0) return -1;
    int sent = 0;
    for (int i = 0; i < XIOS_MAX_INPUT_CLIENTS; i++) {
        struct xios_in_client *c = s->clients[i];
        if (!c || c->fd < 0) continue;
        if (!c->hello_received) continue;
        if (c->improxy) continue;           /* not a display host; see XIOS_IN_IMPROXY */
        if (!client_matches_bound(c, bound_window)) continue;
        if (write_all(c->fd, buf, len) == 0) { sent++; continue; }
        /* Dead/wedged peer. Do NOT free here: broadcast runs inside dispatch's
         * callback (e.g. iosc click-to-focus -> traits), so `c` may be the client
         * client_read() is mid-loop on, or a later udata in the same kevent
         * batch. Shut the socket down instead; kqueue reports EOF and the
         * read path, the sole owner of client lifetime, does the one free. */
        shutdown(c->fd, SHUT_RDWR);
    }
    return sent;
}

int xios_input_socket_broadcast(xios_input_socket *s, const void *buf, size_t len)
{
    return broadcast_to_clients(s, 0, buf, len);
}

int xios_input_socket_broadcast_bound(xios_input_socket *s, uint32_t bound_window,
                                      const void *buf, size_t len)
{
    if (bound_window == 0) return -1;
    return broadcast_to_clients(s, bound_window, buf, len);
}

int xios_input_socket_send_improxy(xios_input_socket *s, const void *buf, size_t len)
{
    if (!s || !buf || len == 0) return 0;
    int sent = 0;
    for (int i = 0; i < XIOS_MAX_INPUT_CLIENTS; i++) {
        struct xios_in_client *c = s->clients[i];
        if (!c || c->fd < 0 || !c->hello_received || !c->improxy) continue;
        if (write_all(c->fd, buf, len) == 0) { sent++; continue; }
        /* Same lifetime rule as broadcast_to_clients(): shut down, let the read
         * path do the single free. A wedged proxy must not look alive, or text
         * would keep being routed into a dead socket instead of falling back. */
        shutdown(c->fd, SHUT_RDWR);
        c->improxy = 0;
    }
    return sent;
}

int xios_input_socket_has_improxy(xios_input_socket *s)
{
    if (!s) return 0;
    for (int i = 0; i < XIOS_MAX_INPUT_CLIENTS; i++)
        if (s->clients[i] && s->clients[i]->fd >= 0 && s->clients[i]->improxy) return 1;
    return 0;
}

int xios_input_socket_client_count(xios_input_socket *s)
{
    if (!s) return 0;
    int n = 0;
    for (int i = 0; i < XIOS_MAX_INPUT_CLIENTS; i++)
        if (s->clients[i] && s->clients[i]->hello_received) n++;
    return n;
}

void xios_input_socket_free(xios_input_socket *s)
{
    if (!s) return;
    for (int i = 0; i < XIOS_MAX_INPUT_CLIENTS; i++)
        if (s->clients[i]) client_drop(s, s->clients[i]);
    if (s->kq >= 0) close(s->kq);
    if (s->listen_fd >= 0) close(s->listen_fd);
    if (s->path[0]) unlink(s->path);
    free(s);
}

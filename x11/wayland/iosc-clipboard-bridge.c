/*
 * iosc-clipboard-bridge.c — see iosc-clipboard-bridge.h.
 *
 * Wire format: XIOS_MSG_CLIPBOARD records (xios_surface.h), both directions,
 * on the dedicated clipboard socket. a=kind, b=generation, payload=item data.
 * Same-generation records merge into one logical clipboard; a generation
 * change replaces it. Little-endian structs on the wire (both ends arm64).
 */
#include "iosc-clipboard-bridge.h"

#include <errno.h>
#include <fcntl.h>
#include <pwd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

#include <wayland-server-core.h>

#include "xios_surface.h"   /* xios_msg, XIOS_MSG_CLIPBOARD, XIOS_CLIP_* */

#define CLIP_MAX_CLIENTS 4
#define CLIP_MAX_KIND    XIOS_CLIP_KIND_HTML
/* A client whose unread outbound backlog passes this is gone/wedged; drop it
 * rather than buffer without bound. Big enough for a full 4-item snapshot. */
#define CLIP_TX_BACKLOG_MAX (64u * 1024u * 1024u)

struct clip_client {
    int fd;
    struct wl_event_source *src;
    uint32_t src_mask;              /* mask currently registered on src */
    int handshaken;
    /* rx: one record at a time (header, then payload accumulate) */
    uint8_t  rx_hdr[sizeof(xios_msg)];
    uint32_t rx_hdr_have;
    xios_msg rx_msg;                /* valid once rx_hdr_have == sizeof */
    uint8_t *rx_payload;            /* len+1 bytes (NUL just past the end) */
    uint32_t rx_payload_have;
    uint32_t last_rx_gen;           /* 0 = nothing received yet */
    /* tx: contiguous byte queue, head-consumed */
    uint8_t *tx;
    size_t   tx_len, tx_off, tx_cap;
};

struct clip_item {
    uint8_t *data;                  /* len+1 bytes, NUL-terminated */
    size_t   len;
    int      set;
};

static struct clip_client *g_clients[CLIP_MAX_CLIENTS];
static struct wl_event_loop *g_loop;
static ioscclip_recv_fn g_recv_cb;
static void *g_recv_ud;

/* The current clipboard SET (whichever side produced it), one slot per kind,
 * so a host that (re)connects mid-session gets the session clipboard. */
static struct clip_item g_items[CLIP_MAX_KIND + 1];
static uint32_t g_gen;              /* outbound generation; bumped per new set */

uint32_t ioscclip_kind_for_mime(const char *mime)
{
    if (!mime) return XIOS_CLIP_KIND_NONE;
    if (!strcmp(mime, "text/uri-list")) return XIOS_CLIP_KIND_URI;
    if (!strcmp(mime, "image/png"))     return XIOS_CLIP_KIND_PNG;
    if (!strcmp(mime, "text/html"))     return XIOS_CLIP_KIND_HTML;
    if (!strncmp(mime, "text/plain", 10) || !strcmp(mime, "UTF8_STRING"))
        return XIOS_CLIP_KIND_TEXT;
    return XIOS_CLIP_KIND_NONE;
}

const char *ioscclip_mime_for_kind(uint32_t kind)
{
    switch (kind) {
    case XIOS_CLIP_KIND_TEXT: return "text/plain;charset=utf-8";
    case XIOS_CLIP_KIND_URI:  return "text/uri-list";
    case XIOS_CLIP_KIND_PNG:  return "image/png";
    case XIOS_CLIP_KIND_HTML: return "text/html";
    default:                  return NULL;
    }
}

static void items_clear(void)
{
    for (int k = 0; k <= CLIP_MAX_KIND; k++) {
        free(g_items[k].data);
        memset(&g_items[k], 0, sizeof(g_items[k]));
    }
}

static int item_store(uint32_t kind, const void *data, size_t len)
{
    if (kind == 0 || kind > CLIP_MAX_KIND || len > XIOS_CLIP_ITEM_MAX)
        return -1;
    uint8_t *copy = malloc(len + 1);
    if (!copy) return -1;
    if (len) memcpy(copy, data, len);
    copy[len] = 0;
    free(g_items[kind].data);
    g_items[kind].data = copy;
    g_items[kind].len = len;
    g_items[kind].set = 1;
    return 0;
}

static void client_drop(struct clip_client *c)
{
    if (!c) return;
    for (int i = 0; i < CLIP_MAX_CLIENTS; i++)
        if (g_clients[i] == c) g_clients[i] = NULL;
    if (c->src) wl_event_source_remove(c->src);
    if (c->fd >= 0) close(c->fd);
    free(c->rx_payload);
    free(c->tx);
    free(c);
    fprintf(stderr, "iosc: clipboard host disconnected\n");
}

static void client_update_mask(struct clip_client *c, uint32_t mask)
{
    if (c->src_mask == mask) return;
    wl_event_source_fd_update(c->src, mask);
    c->src_mask = mask;
}

/* Append bytes to the client's outbound queue (registering for WRITABLE);
 * returns -1 when the backlog cap is blown (caller drops the client). */
static int tx_queue(struct clip_client *c, const void *buf, size_t len)
{
    size_t pending = c->tx_len - c->tx_off;
    if (pending + len > CLIP_TX_BACKLOG_MAX) return -1;
    if (c->tx_off > 0 && (c->tx_off >= c->tx_len || c->tx_off > c->tx_cap / 2)) {
        memmove(c->tx, c->tx + c->tx_off, pending);
        c->tx_len = pending;
        c->tx_off = 0;
    }
    if (c->tx_len + len > c->tx_cap) {
        size_t ncap = c->tx_cap ? c->tx_cap : 4096;
        while (ncap < c->tx_len + len) ncap *= 2;
        uint8_t *nb = realloc(c->tx, ncap);
        if (!nb) return -1;
        c->tx = nb;
        c->tx_cap = ncap;
    }
    memcpy(c->tx + c->tx_len, buf, len);
    c->tx_len += len;
    client_update_mask(c, WL_EVENT_READABLE | WL_EVENT_WRITABLE);
    return 0;
}

static int tx_flush(struct clip_client *c)
{
    while (c->tx_off < c->tx_len) {
        ssize_t w = write(c->fd, c->tx + c->tx_off, c->tx_len - c->tx_off);
        if (w > 0) { c->tx_off += (size_t)w; continue; }
        if (w < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) return 0;
        if (w < 0 && errno == EINTR) continue;
        return -1;
    }
    c->tx_len = c->tx_off = 0;
    client_update_mask(c, WL_EVENT_READABLE);
    return 0;
}

static int tx_record(struct clip_client *c, uint32_t kind, uint32_t gen,
                     const void *data, size_t len)
{
    xios_msg h = { XIOS_MSG_MAGIC, XIOS_MSG_CLIPBOARD, 0, (uint32_t)len,
                   (int32_t)kind, (int32_t)gen, 0, 0 };
    if (tx_queue(c, &h, sizeof(h)) != 0) return -1;
    if (len && tx_queue(c, data, len) != 0) return -1;
    return tx_flush(c);
}

static int tx_hello(struct clip_client *c)
{
    xios_msg hello = {
        XIOS_MSG_MAGIC, XIOS_MSG_HELLO, XIOS_PROTOCOL_VERSION, 0,
        0, 0, 0, 0
    };
    if (tx_queue(c, &hello, sizeof(hello)) != 0) return -1;
    return tx_flush(c);
}

static int replay_snapshot(struct clip_client *c)
{
    for (int k = 1; k <= CLIP_MAX_KIND; k++) {
        if (!g_items[k].set) continue;
        if (tx_record(c, (uint32_t)k, g_gen,
                      g_items[k].data, g_items[k].len) != 0)
            return -1;
    }
    return 0;
}

static void broadcast(uint32_t kind, const void *data, size_t len,
                      struct clip_client *skip)
{
    for (int i = 0; i < CLIP_MAX_CLIENTS; i++) {
        struct clip_client *c = g_clients[i];
        if (!c || !c->handshaken || c == skip) continue;
        if (tx_record(c, kind, g_gen, data, len) != 0) client_drop(c);
    }
}

void ioscclip_selection_begin(void)
{
    g_gen++;
    if (g_gen == 0) g_gen = 1;
    items_clear();
}

int ioscclip_publish(uint32_t kind, const void *data, size_t len)
{
    /* Alias mimes (text/plain + ;charset=utf-8 + UTF8_STRING) snapshot the
     * same bytes several times per selection; send them once. */
    if (kind > 0 && kind <= CLIP_MAX_KIND && g_items[kind].set &&
        g_items[kind].len == len &&
        (len == 0 || !memcmp(g_items[kind].data, data, len)))
        return 0;
    if (item_store(kind, data, len) != 0) return -1;
    broadcast(kind, data, len, NULL);
    return 0;
}

void ioscclip_selection_clear(void)
{
    ioscclip_selection_begin();
    broadcast(XIOS_CLIP_KIND_NONE, NULL, 0, NULL);
}

static void rx_reset(struct clip_client *c)
{
    free(c->rx_payload);
    c->rx_payload = NULL;
    c->rx_payload_have = 0;
    c->rx_hdr_have = 0;
    memset(&c->rx_msg, 0, sizeof(c->rx_msg));
}

/* One complete record from the host. Returns -1 on protocol violation. */
static int rx_dispatch(struct clip_client *c)
{
    const xios_msg *m = &c->rx_msg;
    uint32_t kind = (uint32_t)m->a;
    uint32_t gen = (uint32_t)m->b;
    if (!c->handshaken ||
        m->window_id != 0 ||
        kind > CLIP_MAX_KIND ||
        gen == 0 ||
        m->c != 0 ||
        m->d != 0)
        return -1;
    int first = (gen != c->last_rx_gen);
    c->last_rx_gen = gen;

    if (kind == XIOS_CLIP_KIND_NONE) {
        if (m->length != 0) return -1;
        ioscclip_selection_begin();          /* new outbound gen for relays/snapshots */
        broadcast(XIOS_CLIP_KIND_NONE, NULL, 0, c);
        if (g_recv_cb) g_recv_cb(XIOS_CLIP_KIND_NONE, "", 0, 1, g_recv_ud);
        return 0;
    }

    /* Mirror into the bridge store (snapshot source for later connects) and
     * relay to any other connected host, renumbered to our own generation. */
    if (first) ioscclip_selection_begin();
    const void *data = c->rx_payload ? c->rx_payload : (const void *)"";
    item_store(kind, data, m->length);
    broadcast(kind, data, m->length, c);
    if (g_recv_cb) g_recv_cb(kind, data, m->length, first, g_recv_ud);
    return 0;
}

static int client_dispatch(int fd, uint32_t mask, void *data)
{
    struct clip_client *c = data;
    if (mask & (WL_EVENT_HANGUP | WL_EVENT_ERROR)) goto drop;
    if ((mask & WL_EVENT_WRITABLE) && tx_flush(c) != 0) goto drop;
    if (!(mask & WL_EVENT_READABLE)) return 0;

    for (;;) {
        if (c->rx_hdr_have < sizeof(c->rx_hdr)) {
            ssize_t r = read(fd, c->rx_hdr + c->rx_hdr_have,
                             sizeof(c->rx_hdr) - c->rx_hdr_have);
            if (r > 0) {
                c->rx_hdr_have += (uint32_t)r;
                if (c->rx_hdr_have < sizeof(c->rx_hdr)) continue;
                memcpy(&c->rx_msg, c->rx_hdr, sizeof(c->rx_msg));
                if (c->rx_msg.magic != XIOS_MSG_MAGIC)
                    goto drop;               /* desync or violation */
                if (!c->handshaken) {
                    if (c->rx_msg.type != XIOS_MSG_HELLO ||
                        c->rx_msg.window_id != XIOS_PROTOCOL_VERSION ||
                        c->rx_msg.length != 0 ||
                        c->rx_msg.a != 0 || c->rx_msg.b != 0 ||
                        c->rx_msg.c != 0 || c->rx_msg.d != 0)
                        goto drop;
                    c->handshaken = 1;
                    rx_reset(c);
                    if (tx_hello(c) != 0 || replay_snapshot(c) != 0)
                        goto drop;
                    fprintf(stderr, "iosc: clipboard v%u host connected (fd=%d)\n",
                            XIOS_PROTOCOL_VERSION, fd);
                    continue;
                }
                if (c->rx_msg.type != XIOS_MSG_CLIPBOARD ||
                    c->rx_msg.window_id != 0 ||
                    c->rx_msg.length > XIOS_CLIP_ITEM_MAX)
                    goto drop;
                c->rx_payload = calloc(1, (size_t)c->rx_msg.length + 1);
                if (!c->rx_payload) goto drop;
            } else {
                if (r == 0) goto drop;
                if (errno == EAGAIN || errno == EWOULDBLOCK) break;
                if (errno == EINTR) continue;
                goto drop;
            }
        }
        while (c->rx_payload_have < c->rx_msg.length) {
            ssize_t r = read(fd, c->rx_payload + c->rx_payload_have,
                             c->rx_msg.length - c->rx_payload_have);
            if (r > 0) { c->rx_payload_have += (uint32_t)r; continue; }
            if (r == 0) goto drop;
            if (errno == EAGAIN || errno == EWOULDBLOCK) return 0;
            if (errno == EINTR) continue;
            goto drop;
        }
        if (rx_dispatch(c) != 0) goto drop;
        rx_reset(c);
    }
    return 0;
drop:
    client_drop(c);
    return 0;
}

static int listen_dispatch(int fd, uint32_t mask, void *data)
{
    (void)mask; (void)data;
    int cfd = accept(fd, NULL, NULL);
    if (cfd < 0) return 0;
    fcntl(cfd, F_SETFL, fcntl(cfd, F_GETFL, 0) | O_NONBLOCK);
    /* tx_flush() writes to this fd; Darwin has no MSG_NOSIGNAL, so a dead host
     * must surface as EPIPE (client_drop) rather than a fatal SIGPIPE. */
    int on = 1;
    setsockopt(cfd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));

    int slot = -1;
    for (int i = 0; i < CLIP_MAX_CLIENTS; i++)
        if (!g_clients[i]) { slot = i; break; }
    if (slot < 0) { close(cfd); return 0; }

    struct clip_client *c = calloc(1, sizeof(*c));
    if (!c) { close(cfd); return 0; }
    c->fd = cfd;
    c->src_mask = WL_EVENT_READABLE;
    c->src = wl_event_loop_add_fd(g_loop, cfd, WL_EVENT_READABLE,
                                  client_dispatch, c);
    if (!c->src) { close(cfd); free(c); return 0; }
    g_clients[slot] = c;

    /* Snapshot replay waits for the exact-v1 HELLO in client_dispatch. */
    return 0;
}

int ioscclip_start(struct wl_event_loop *loop, const char *path,
                   ioscclip_recv_fn on_recv, void *user_data)
{
    unlink(path);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, path, sizeof(addr.sun_path) - 1);
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0 ||
        listen(fd, 4) < 0) {
        close(fd);
        return -1;
    }
    /* iosc runs as root, the host app as mobile: restrict to mobile (0660)
     * like the ddx socket, falling back to numeric mobile on stripped images. */
    struct passwd *pw = getpwnam("mobile");
    uid_t uid = pw ? pw->pw_uid : 501;
    gid_t gid = pw ? pw->pw_gid : 501;
    if (chown(path, uid, gid) == 0) {
        chmod(path, 0660);
    } else {
        chmod(path, 0600);
        fprintf(stderr, "iosc: keeping clipboard socket %s owner-only; chown mobile failed: %s\n",
                path, strerror(errno));
    }
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK);

    if (!wl_event_loop_add_fd(loop, fd, WL_EVENT_READABLE, listen_dispatch, NULL)) {
        close(fd);
        return -1;
    }
    g_loop = loop;
    g_recv_cb = on_recv;
    g_recv_ud = user_data;
    return 0;
}

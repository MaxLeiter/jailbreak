#include "IoscClipboard.h"
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/un.h>

// Copy-event generation. Process-wide on purpose: a reconnect (or a switch
// back to this desktop) must not restart at 1, or the compositor would read a
// new copy as one more representation of the previous event.
static uint32_t s_tx_gen = 0;   // bumped per iOS copy event (never 0 once used)

// One clipboard connection. The handle owns the fd and the partial-record
// receive state; Xios v2 keeps one per presented session.
struct iosc_clipboard {
    int fd;
    // rx: one record at a time; partial reads span poll calls
    uint8_t hdr[sizeof(xios_msg)];
    uint32_t hdr_have;
    xios_msg msg;
    uint8_t *payload;
    uint32_t payload_have;
};

static bool write_fd(int fd, const void *buf, size_t len);

static void reset_rx(iosc_clipboard_t *h) {
    free(h->payload);
    h->payload = NULL;
    h->payload_have = 0;
    h->hdr_have = 0;
    memset(&h->msg, 0, sizeof(h->msg));
}

int iosc_clipboard_connect(const char *sock_path) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    int on = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));
    // The fd stays BLOCKING: sends must deliver whole records (a partial
    // write desyncs the stream), so a bounded send timeout on a writer thread
    // beats a nonblocking retry dance. Reads poll with MSG_DONTWAIT instead,
    // so the display-link tick never blocks.
    struct timeval tv = { 2, 0 };
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    struct sockaddr_un a;
    memset(&a, 0, sizeof(a));
    a.sun_family = AF_UNIX;
    strncpy(a.sun_path, sock_path, sizeof(a.sun_path) - 1);
    if (connect(fd, (struct sockaddr *)&a, sizeof(a)) < 0) { close(fd); return -1; }
    xios_msg hello = {
        XIOS_MSG_MAGIC, XIOS_MSG_HELLO, XIOS_PROTOCOL_VERSION, 0,
        0, 0, 0, 0
    };
    xios_msg reply;
    if (!write_fd(fd, &hello, sizeof(hello))) {
        close(fd);
        return -1;
    }
    size_t got = 0;
    while (got < sizeof(reply)) {
        ssize_t r = read(fd, (uint8_t *)&reply + got, sizeof(reply) - got);
        if (r > 0) { got += (size_t)r; continue; }
        if (r < 0 && errno == EINTR) continue;
        close(fd);
        return -1;
    }
    if (reply.magic != XIOS_MSG_MAGIC ||
        reply.type != XIOS_MSG_HELLO ||
        reply.window_id != XIOS_PROTOCOL_VERSION ||
        reply.length != 0 ||
        reply.a != 0 || reply.b != 0 || reply.c != 0 || reply.d != 0) {
        close(fd);
        return -1;
    }
    return fd;
}

iosc_clipboard_t *iosc_clipboard_adopt(int fd) {
    if (fd < 0) return NULL;
    iosc_clipboard_t *h = calloc(1, sizeof(*h));
    if (!h) { close(fd); return NULL; }
    h->fd = fd;
    return h;
}

void iosc_clipboard_close(iosc_clipboard_t *h) {
    if (!h) return;
    if (h->fd >= 0) close(h->fd);
    free(h->payload);
    free(h);
}

bool iosc_clipboard_is_open(iosc_clipboard_t *h) { return h && h->fd >= 0; }

// Drop the connection but keep the handle valid, so a poll after a desync
// reports -1 once and later calls stay safe.
static void drop(iosc_clipboard_t *h) {
    if (h->fd >= 0) { close(h->fd); h->fd = -1; }
    reset_rx(h);
}

static bool write_fd(int fd, const void *buf, size_t len) {
    const char *p = (const char *)buf;
    size_t put = 0;
    while (put < len) {
        ssize_t w = write(fd, p + put, len - put);
        if (w > 0) { put += (size_t)w; continue; }
        if (w < 0 && errno == EINTR) continue;
        return false;   // includes the SNDTIMEO expiring mid-record
    }
    return true;
}

static int write_record(int fd, uint32_t generation, uint32_t kind,
                        const void *data, size_t len) {
    if (fd < 0) return -1;
    if (len > XIOS_CLIP_ITEM_MAX) return 0;
    xios_msg h = { XIOS_MSG_MAGIC, XIOS_MSG_CLIPBOARD, 0, (uint32_t)len,
                   (int32_t)kind, (int32_t)generation, 0, 0 };
    if (!write_fd(fd, &h, sizeof(h)) || (len > 0 && !write_fd(fd, data, len)))
        return -1;
    return 1;
}

uint32_t iosc_clipboard_send_begin(void) {
    s_tx_gen++;
    if (s_tx_gen == 0) s_tx_gen = 1;
    return s_tx_gen;
}

int iosc_clipboard_writer_fd(iosc_clipboard_t *h) {
    return h && h->fd >= 0 ? dup(h->fd) : -1;
}

int iosc_clipboard_write_item(int fd, uint32_t generation, uint32_t kind,
                              const void *data, size_t len) {
    if (kind == XIOS_CLIP_KIND_NONE || kind > XIOS_CLIP_KIND_HTML) return 0;
    return write_record(fd, generation, kind, data, len);
}

int iosc_clipboard_write_clear(int fd, uint32_t generation) {
    return write_record(fd, generation, XIOS_CLIP_KIND_NONE, NULL, 0);
}

int iosc_clipboard_poll_item(iosc_clipboard_t *h, uint32_t *kind,
                             uint32_t *generation, uint8_t **data, uint32_t *len) {
    if (kind) *kind = 0;
    if (generation) *generation = 0;
    if (data) *data = NULL;
    if (len) *len = 0;
    if (!h || h->fd < 0 || !kind || !data || !len) return (!h || h->fd < 0) ? -1 : 0;
    for (;;) {
        if (h->hdr_have < sizeof(h->hdr)) {
            ssize_t r = recv(h->fd, h->hdr + h->hdr_have,
                             sizeof(h->hdr) - h->hdr_have, MSG_DONTWAIT);
            if (r > 0) {
                h->hdr_have += (uint32_t)r;
                if (h->hdr_have < sizeof(h->hdr)) continue;
                memcpy(&h->msg, h->hdr, sizeof(h->msg));
                if (h->msg.magic != XIOS_MSG_MAGIC ||
                    h->msg.type != XIOS_MSG_CLIPBOARD ||
                    h->msg.window_id != 0 ||
                    h->msg.length > XIOS_CLIP_ITEM_MAX ||
                    (uint32_t)h->msg.a > XIOS_CLIP_KIND_HTML ||
                    h->msg.b == 0 ||
                    h->msg.c != 0 || h->msg.d != 0 ||
                    (h->msg.a == XIOS_CLIP_KIND_NONE && h->msg.length != 0)) {
                    drop(h);   // desync: reconnect from scratch
                    return -1;
                }
                h->payload = calloc(1, (size_t)h->msg.length + 1u);
                if (!h->payload) { drop(h); return -1; }
            } else {
                if (r == 0) { drop(h); return -1; }
                if (errno == EAGAIN || errno == EWOULDBLOCK) return 0;
                if (errno == EINTR) continue;
                drop(h);
                return -1;
            }
        }
        while (h->payload_have < h->msg.length) {
            ssize_t r = recv(h->fd, h->payload + h->payload_have,
                             h->msg.length - h->payload_have, MSG_DONTWAIT);
            if (r > 0) { h->payload_have += (uint32_t)r; continue; }
            if (r == 0) { drop(h); return -1; }
            if (errno == EAGAIN || errno == EWOULDBLOCK) return 0;
            if (errno == EINTR) continue;
            drop(h);
            return -1;
        }
        *kind = (uint32_t)h->msg.a;
        if (generation) *generation = (uint32_t)h->msg.b;
        *data = h->payload;              // ownership moves to the caller
        *len = h->msg.length;
        h->payload = NULL;
        reset_rx(h);
        return 1;
    }
}

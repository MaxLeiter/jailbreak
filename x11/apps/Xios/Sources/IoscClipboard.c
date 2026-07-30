#include "IoscClipboard.h"
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/un.h>

static int s_fd = -1;
static uint32_t s_tx_gen = 0;   // bumped per iOS copy event (never 0 once used)
// rx: one record at a time; partial reads span poll calls
static uint8_t s_hdr[sizeof(xios_msg)];
static uint32_t s_hdr_have = 0;
static xios_msg s_msg;
static uint8_t *s_payload = NULL;
static uint32_t s_payload_have = 0;

static bool write_all(const void *buf, size_t len);

static void reset_rx(void) {
    free(s_payload);
    s_payload = NULL;
    s_payload_have = 0;
    s_hdr_have = 0;
    memset(&s_msg, 0, sizeof(s_msg));
}

bool iosc_clipboard_open(const char *sock_path) {
    if (s_fd >= 0) return true;
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return false;
    int on = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));
    // The fd stays BLOCKING: sends must deliver whole records (a partial
    // write desyncs the stream) and the compositor drains promptly, so a
    // bounded send timeout beats a nonblocking retry dance. Reads poll with
    // MSG_DONTWAIT instead, so the display-link tick never blocks.
    struct timeval tv = { 2, 0 };
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    struct sockaddr_un a;
    memset(&a, 0, sizeof(a));
    a.sun_family = AF_UNIX;
    strncpy(a.sun_path, sock_path, sizeof(a.sun_path) - 1);
    if (connect(fd, (struct sockaddr *)&a, sizeof(a)) < 0) { close(fd); return false; }
    s_fd = fd;
    xios_msg hello = {
        XIOS_MSG_MAGIC, XIOS_MSG_HELLO, XIOS_PROTOCOL_VERSION, 0,
        0, 0, 0, 0
    };
    xios_msg reply;
    if (!write_all(&hello, sizeof(hello))) {
        iosc_clipboard_close();
        return false;
    }
    size_t got = 0;
    while (got < sizeof(reply)) {
        ssize_t r = read(fd, (uint8_t *)&reply + got, sizeof(reply) - got);
        if (r > 0) { got += (size_t)r; continue; }
        if (r < 0 && errno == EINTR) continue;
        iosc_clipboard_close();
        return false;
    }
    if (reply.magic != XIOS_MSG_MAGIC ||
        reply.type != XIOS_MSG_HELLO ||
        reply.window_id != XIOS_PROTOCOL_VERSION ||
        reply.length != 0 ||
        reply.a != 0 || reply.b != 0 || reply.c != 0 || reply.d != 0) {
        iosc_clipboard_close();
        return false;
    }
    reset_rx();
    return true;
}

void iosc_clipboard_close(void) {
    if (s_fd >= 0) { close(s_fd); s_fd = -1; }
    reset_rx();
}

bool iosc_clipboard_is_open(void) { return s_fd >= 0; }

static bool write_all(const void *buf, size_t len) {
    const char *p = (const char *)buf;
    size_t put = 0;
    while (put < len) {
        ssize_t w = write(s_fd, p + put, len - put);
        if (w > 0) { put += (size_t)w; continue; }
        if (w < 0 && errno == EINTR) continue;
        return false;   // includes the SNDTIMEO expiring mid-record
    }
    return true;
}

static bool send_record(uint32_t kind, const void *data, size_t len) {
    if (s_fd < 0 || len > XIOS_CLIP_ITEM_MAX) return false;
    xios_msg h = { XIOS_MSG_MAGIC, XIOS_MSG_CLIPBOARD, 0, (uint32_t)len,
                   (int32_t)kind, (int32_t)s_tx_gen, 0, 0 };
    if (!write_all(&h, sizeof(h)) || (len > 0 && !write_all(data, len))) {
        iosc_clipboard_close();
        return false;
    }
    return true;
}

void iosc_clipboard_send_begin(void) {
    s_tx_gen++;
    if (s_tx_gen == 0) s_tx_gen = 1;
}

bool iosc_clipboard_send_item(uint32_t kind, const void *data, size_t len) {
    if (kind == XIOS_CLIP_KIND_NONE || kind > XIOS_CLIP_KIND_HTML) return false;
    if (s_tx_gen == 0) iosc_clipboard_send_begin();
    return send_record(kind, data, len);
}

bool iosc_clipboard_send_clear(void) {
    iosc_clipboard_send_begin();
    return send_record(XIOS_CLIP_KIND_NONE, NULL, 0);
}

int iosc_clipboard_poll_item(uint32_t *kind, uint32_t *generation,
                             uint8_t **data, uint32_t *len) {
    if (kind) *kind = 0;
    if (generation) *generation = 0;
    if (data) *data = NULL;
    if (len) *len = 0;
    if (s_fd < 0 || !kind || !data || !len) return s_fd < 0 ? -1 : 0;
    for (;;) {
        if (s_hdr_have < sizeof(s_hdr)) {
            ssize_t r = recv(s_fd, s_hdr + s_hdr_have,
                             sizeof(s_hdr) - s_hdr_have, MSG_DONTWAIT);
            if (r > 0) {
                s_hdr_have += (uint32_t)r;
                if (s_hdr_have < sizeof(s_hdr)) continue;
                memcpy(&s_msg, s_hdr, sizeof(s_msg));
                if (s_msg.magic != XIOS_MSG_MAGIC ||
                    s_msg.type != XIOS_MSG_CLIPBOARD ||
                    s_msg.window_id != 0 ||
                    s_msg.length > XIOS_CLIP_ITEM_MAX ||
                    (uint32_t)s_msg.a > XIOS_CLIP_KIND_HTML ||
                    s_msg.b == 0 ||
                    s_msg.c != 0 || s_msg.d != 0 ||
                    (s_msg.a == XIOS_CLIP_KIND_NONE && s_msg.length != 0)) {
                    iosc_clipboard_close();   // desync: reconnect from scratch
                    return -1;
                }
                s_payload = calloc(1, (size_t)s_msg.length + 1u);
                if (!s_payload) { iosc_clipboard_close(); return -1; }
            } else {
                if (r == 0) { iosc_clipboard_close(); return -1; }
                if (errno == EAGAIN || errno == EWOULDBLOCK) return 0;
                if (errno == EINTR) continue;
                iosc_clipboard_close();
                return -1;
            }
        }
        while (s_payload_have < s_msg.length) {
            ssize_t r = recv(s_fd, s_payload + s_payload_have,
                             s_msg.length - s_payload_have, MSG_DONTWAIT);
            if (r > 0) { s_payload_have += (uint32_t)r; continue; }
            if (r == 0) { iosc_clipboard_close(); return -1; }
            if (errno == EAGAIN || errno == EWOULDBLOCK) return 0;
            if (errno == EINTR) continue;
            iosc_clipboard_close();
            return -1;
        }
        *kind = (uint32_t)s_msg.a;
        if (generation) *generation = (uint32_t)s_msg.b;
        *data = s_payload;              // ownership moves to the caller
        *len = s_msg.length;
        s_payload = NULL;
        reset_rx();
        return 1;
    }
}

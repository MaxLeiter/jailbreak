#include "IoscClipboard.h"
#include <errno.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <sys/un.h>

#define IOSC_CLIP_SET 1u
#define IOSC_CLIP_MAX (1024u * 1024u)

struct iosc_clip_msg {
    uint32_t type;
    uint32_t len;
};

static int s_fd = -1;
static uint8_t s_hdr[sizeof(struct iosc_clip_msg)];
static int s_hdr_have = 0;
static struct iosc_clip_msg s_msg;
static char *s_payload = NULL;
static uint32_t s_payload_have = 0;

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
    struct sockaddr_un a;
    memset(&a, 0, sizeof(a));
    a.sun_family = AF_UNIX;
    strncpy(a.sun_path, sock_path, sizeof(a.sun_path) - 1);
    if (connect(fd, (struct sockaddr *)&a, sizeof(a)) < 0) { close(fd); return false; }
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK);
    reset_rx();
    s_fd = fd;
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
        return false;
    }
    return true;
}

bool iosc_clipboard_set_text(const char *utf8) {
    if (s_fd < 0) return false;
    uint32_t len = utf8 ? (uint32_t)strnlen(utf8, IOSC_CLIP_MAX) : 0u;
    struct iosc_clip_msg h = { .type = IOSC_CLIP_SET, .len = len };
    if (!write_all(&h, sizeof(h)) || (len > 0 && !write_all(utf8, len))) {
        iosc_clipboard_close();
        return false;
    }
    return true;
}

bool iosc_clipboard_poll(char *out, int out_cap, int *out_len) {
    if (out_len) *out_len = 0;
    if (s_fd < 0 || !out || out_cap <= 0) return false;
    for (;;) {
        if (s_hdr_have < (int)sizeof(s_hdr)) {
            ssize_t r = read(s_fd, s_hdr + s_hdr_have, sizeof(s_hdr) - (size_t)s_hdr_have);
            if (r > 0) {
                s_hdr_have += (int)r;
                if (s_hdr_have < (int)sizeof(s_hdr)) continue;
                memcpy(&s_msg, s_hdr, sizeof(s_msg));
                if (s_msg.len > IOSC_CLIP_MAX) { iosc_clipboard_close(); return false; }
                s_payload = s_msg.len ? calloc(1, s_msg.len + 1u) : NULL;
                if (s_msg.len && !s_payload) { iosc_clipboard_close(); return false; }
            } else {
                if (r == 0) { iosc_clipboard_close(); return false; }
                if (errno == EAGAIN || errno == EWOULDBLOCK) return false;
                if (errno == EINTR) continue;
                iosc_clipboard_close();
                return false;
            }
        }
        while (s_payload_have < s_msg.len) {
            ssize_t r = read(s_fd, s_payload + s_payload_have, s_msg.len - s_payload_have);
            if (r > 0) { s_payload_have += (uint32_t)r; continue; }
            if (r == 0) { iosc_clipboard_close(); return false; }
            if (errno == EAGAIN || errno == EWOULDBLOCK) return false;
            if (errno == EINTR) continue;
            iosc_clipboard_close();
            return false;
        }
        uint32_t type = s_msg.type;
        uint32_t len = s_msg.len;
        int copy = (len < (uint32_t)(out_cap - 1)) ? (int)len : out_cap - 1;
        if (copy > 0) memcpy(out, s_payload, (size_t)copy);
        out[copy] = '\0';
        if (out_len) *out_len = copy;
        reset_rx();
        if (type == IOSC_CLIP_SET) return true;
    }
}

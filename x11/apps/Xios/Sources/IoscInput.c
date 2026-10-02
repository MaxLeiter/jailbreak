#include "IoscInput.h"
#include "../../shared/XiosProtocol.h"
#include <stdint.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <sys/un.h>

// One persistent AF_UNIX stream to the compositor. The socket is non-blocking,
// and a compositor that stalls for a moment fills its few KB of buffer: what
// the socket will not take yet is queued, in order, and flushed by later sends
// and by every poll_traits() call (the app's tick). Records are queued whole,
// so a short write never leaves half a record ahead of the next one. Only a
// real write error, or a stall that outgrows the queue, marks the connection
// dead so the app's poll loop reconnects.
static int s_fd = -1;

#define OUTQ_MAX (64u * 1024u)   // ~2000 records; the same bound iosc uses per client
static uint8_t s_outq[OUTQ_MAX];
static size_t s_outq_head = 0, s_outq_len = 0;

static uint8_t s_rx[sizeof(xios_msg)];
static int s_rx_have = 0;
static int s_hello_received = 0;

static int write_full_fd(int fd, const void *buf, size_t n) {
    const char *p = buf;
    size_t put = 0;
    while (put < n) {
        ssize_t w = write(fd, p + put, n - put);
        if (w > 0) { put += (size_t)w; continue; }
        if (w < 0 && errno == EINTR) continue;
        return -1;
    }
    return 0;
}

bool iosc_input_open(const char *sock_path) {
    if (s_fd >= 0) return true;
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return false;
    // Never let a write to a half-closed socket raise SIGPIPE (would kill the app);
    // surface it as EPIPE so send_msg() can recover instead.
    int on = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));
    struct sockaddr_un a;
    memset(&a, 0, sizeof(a));
    a.sun_family = AF_UNIX;
    strncpy(a.sun_path, sock_path, sizeof(a.sun_path) - 1);
    if (connect(fd, (struct sockaddr *)&a, sizeof(a)) < 0) { close(fd); return false; }
    xios_msg hello = xios_protocol_hello();
    if (write_full_fd(fd, &hello, sizeof(hello)) != 0) { close(fd); return false; }
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK);
    s_fd = fd;
    s_hello_received = 0;
    return true;
}

void iosc_input_close(void) {
    if (s_fd >= 0) { close(s_fd); s_fd = -1; }
    s_outq_head = s_outq_len = 0;
    s_rx_have = 0;
    s_hello_received = 0;
}

bool iosc_input_is_open(void) { return s_fd >= 0; }

// Write as much of the queue as the socket takes now. 0 = fine (some may
// still be queued), -1 = write error, connection closed.
static int flush_out(void) {
    while (s_fd >= 0 && s_outq_len > 0) {
        ssize_t w = write(s_fd, s_outq + s_outq_head, s_outq_len);
        if (w > 0) { s_outq_head += (size_t)w; s_outq_len -= (size_t)w; continue; }
        if (w < 0 && errno == EINTR) continue;
        if (w < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) break;
        iosc_input_close();   // EPIPE etc.: the app reconnects on its next poll
        return -1;
    }
    if (s_outq_len == 0) s_outq_head = 0;
    return s_fd >= 0 ? 0 : -1;
}

// Send one record (a header plus an optional payload) without ever splitting
// it across a drop: write directly while nothing is queued, queue the rest.
static void send_record(const void *hdr, size_t hdr_len,
                        const void *payload, size_t payload_len) {
    if (s_fd < 0 || flush_out() < 0) return;
    const void *part[2] = { hdr, payload };
    size_t part_len[2] = { hdr_len, payload_len };
    size_t i = 0, put = 0;
    while (s_outq_len == 0 && i < 2) {
        if (put == part_len[i]) { i++; put = 0; continue; }
        ssize_t w = write(s_fd, (const char *)part[i] + put, part_len[i] - put);
        if (w > 0) { put += (size_t)w; continue; }
        if (w < 0 && errno == EINTR) continue;
        if (w < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) break;
        iosc_input_close();
        return;
    }
    size_t rest = 0;
    for (size_t j = i; j < 2; j++) rest += part_len[j] - (j == i ? put : 0);
    if (rest == 0) return;
    if (s_outq_len + rest > OUTQ_MAX) {
        // Stalled past the bound: same recovery as a dead peer.
        iosc_input_close();
        return;
    }
    if (s_outq_head + s_outq_len + rest > OUTQ_MAX) {
        memmove(s_outq, s_outq + s_outq_head, s_outq_len);
        s_outq_head = 0;
    }
    for (size_t j = i; j < 2; j++) {
        size_t from = j == i ? put : 0, n = part_len[j] - from;
        if (n == 0) continue;
        memcpy(s_outq + s_outq_head + s_outq_len, (const char *)part[j] + from, n);
        s_outq_len += n;
    }
}

static void send_msg(const xios_msg *m) {
    send_record(m, sizeof(*m), NULL, 0);
}

void iosc_input_motion(int x, int y) {
    xios_msg m = xios_input_message(XIOS_IN_MOTION, x, y, 0, 0, 0);
    send_msg(&m);
}

void iosc_input_button(int button, bool down, int x, int y) {
    xios_msg m = xios_input_message(XIOS_IN_BUTTON, x, y, (uint32_t)button,
                                    down ? 1u : 0u, 0);
    send_msg(&m);
}

void iosc_input_key(unsigned keysym, bool down, unsigned mods) {
    xios_msg m = xios_input_message(XIOS_IN_KEY, 0, 0, keysym,
                                    down ? 1u : 0u, mods);
    send_msg(&m);
}

void iosc_input_text(const char *utf8) {
    if (!utf8) return;
    size_t left = strlen(utf8);
    // The compositor drops a TEXT record over 4096 bytes, so longer text (a
    // paste, dictation) goes out as several records, each cut on a code point
    // boundary: a split multi-byte sequence would reach the client as invalid
    // UTF-8. Text beyond what the send queue can hold is cut off rather than
    // costing the connection.
    while (left > 0 && s_fd >= 0) {
        size_t len = left;
        if (len > 4096) {
            len = 4096;
            while (len > 0 && ((unsigned char)utf8[len] & 0xC0) == 0x80) len--;
            if (len == 0) return;
        }
        if (s_outq_len + sizeof(xios_msg) + len > OUTQ_MAX) return;
        xios_msg m = xios_input_message(XIOS_IN_TEXT, 0, 0, (uint32_t)len, 0, 0);
        m.length = (uint32_t)len;
        send_record(&m, sizeof(m), utf8, len);
        utf8 += len;
        left -= len;
    }
}

void iosc_input_touch(int slot, int phase, int x, int y) {
    xios_msg m = xios_input_message(XIOS_IN_TOUCH, x, y, (uint32_t)slot,
                                    (uint32_t)phase, 0);
    send_msg(&m);
}

void iosc_input_tablet(int phase, int x, int y, unsigned pressure16,
                       int tilt_x_deg, int tilt_y_deg) {
    if (tilt_x_deg < -90) tilt_x_deg = -90; if (tilt_x_deg > 90) tilt_x_deg = 90;
    if (tilt_y_deg < -90) tilt_y_deg = -90; if (tilt_y_deg > 90) tilt_y_deg = 90;
    xios_msg m = xios_input_message(
        XIOS_IN_TABLET, x, y,
        pressure16 > 65535u ? 65535u : pressure16, (uint32_t)phase,
        (uint32_t)(tilt_x_deg + 90) | ((uint32_t)(tilt_y_deg + 90) << 8));
    send_msg(&m);
}

void iosc_input_axis(int dx256, int dy256, unsigned source, unsigned mods, bool stop) {
    xios_msg m = xios_input_message(XIOS_IN_AXIS, dx256, dy256, source,
                                    stop ? 1u : 0u, mods);
    send_msg(&m);
}

void iosc_input_gesture(unsigned kind, unsigned phase, unsigned fingers,
                        int dx256, int dy256, unsigned scale256, int rot256) {
    xios_msg m = xios_input_message(
        XIOS_IN_GESTURE, dx256, dy256,
        (kind & 0xffu) | ((phase & 0xffu) << 8) | ((fingers & 0xffu) << 16),
        scale256, (unsigned)rot256);
    send_msg(&m);
}

int iosc_input_poll_traits(unsigned *hint, unsigned *purpose, unsigned *enabled) {
    if (s_fd < 0 || flush_out() < 0) return -1;
    for (;;) {
        ssize_t r = read(s_fd, s_rx + s_rx_have, sizeof(s_rx) - (size_t)s_rx_have);
        if (r > 0) {
            s_rx_have += (int)r;
            if (s_rx_have == (int)sizeof(s_rx)) {
                xios_msg m;
                memcpy(&m, s_rx, sizeof(m));
                s_rx_have = 0;
                if (!s_hello_received) {
                    if (!xios_protocol_is_exact_hello(&m)) {
                        iosc_input_close();
                        return -1;
                    }
                    s_hello_received = 1;
                    continue;
                }
                if (m.magic != XIOS_MSG_MAGIC || m.type == XIOS_MSG_HELLO ||
                    m.length != 0 ||
                    (m.type != XIOS_IN_TRAITS && m.type != XIOS_IN_HAPTIC)) {
                    iosc_input_close();
                    return -1;
                }
                if (m.type == XIOS_IN_TRAITS) {
                    if (hint) *hint = XIOS_INPUT_CODE(&m);
                    if (purpose) *purpose = XIOS_INPUT_STATE(&m);
                    if (enabled) *enabled = XIOS_INPUT_MODS(&m);
                    // One record per call: the auto-keyboard policy needs every
                    // enable/disable transition, so a disable+enable pair queued
                    // in the same tick must not coalesce into the newest values.
                    return 1;
                }
            }
            continue;
        }
        if (r == 0) { iosc_input_close(); return -1; }
        if (errno == EINTR) continue;
        if (errno == EAGAIN || errno == EWOULDBLOCK) return 0;
        iosc_input_close();
        return -1;
    }
}

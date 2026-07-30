/*
 * IoscInput.c — host (handle-based) copy of apps/Xios/Sources/IoscInput.c.
 * Same wire format; one connection per UIWindowScene, bound to a window id.
 */
#include "IoscInput.h"
#include "../../shared/XiosProtocol.h"
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <sys/un.h>

struct iosc_input {
    int      fd;
    uint8_t  rx[sizeof(xios_msg)];
    int      rx_have;
    int      hello_received;
};

static void send_bytes(iosc_input_t *h, const void *buf, size_t n)
{
    if (!h || h->fd < 0) return;
    const char *p = buf; size_t put = 0;
    while (put < n) {
        ssize_t w = write(h->fd, p + put, n - put);
        if (w > 0) { put += (size_t)w; continue; }
        if (w < 0 && errno == EINTR) continue;
        close(h->fd); h->fd = -1;   /* caller reconnects on its next poll */
        return;
    }
}

static void send_msg(iosc_input_t *h, const xios_msg *m)
{
    send_bytes(h, m, sizeof(*m));
}

iosc_input_t *iosc_input_open(const char *sock_path, unsigned window)
{
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return NULL;
    int on = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));
    struct sockaddr_un a;
    memset(&a, 0, sizeof(a));
    a.sun_family = AF_UNIX;
    strncpy(a.sun_path, sock_path, sizeof(a.sun_path) - 1);
    if (connect(fd, (struct sockaddr *)&a, sizeof(a)) < 0) { close(fd); return NULL; }

    iosc_input_t *h = calloc(1, sizeof(*h));
    if (!h) { close(fd); return NULL; }
    h->fd = fd;

    /* HELLO and BIND go out before non-blocking mode so the compositor can
     * authenticate and pin this connection before any event arrives. */
    xios_msg hello = xios_protocol_hello();
    send_msg(h, &hello);
    if (h->fd < 0) { free(h); return NULL; }
    /* Bind BEFORE going non-blocking so the compositor pins the connection to
     * this window before any event arrives. */
    xios_msg bind = xios_input_message(XIOS_IN_BIND, 0, 0, window, 0, 0);
    send_msg(h, &bind);
    if (h->fd < 0) { free(h); return NULL; }

    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK);
    return h;
}

void iosc_input_close(iosc_input_t *h)
{
    if (!h) return;
    if (h->fd >= 0) close(h->fd);
    free(h);
}

bool iosc_input_is_open(iosc_input_t *h) { return h && h->fd >= 0; }

void iosc_input_motion(iosc_input_t *h, int x, int y)
{
    xios_msg m = xios_input_message(XIOS_IN_MOTION, x, y, 0, 0, 0);
    send_msg(h, &m);
}

void iosc_input_button(iosc_input_t *h, int button, bool down, int x, int y)
{
    xios_msg m = xios_input_message(XIOS_IN_BUTTON, x, y, (uint32_t)button,
                                    down ? 1u : 0u, 0);
    send_msg(h, &m);
}

void iosc_input_key(iosc_input_t *h, unsigned keysym, bool down, unsigned mods)
{
    xios_msg m = xios_input_message(XIOS_IN_KEY, 0, 0, keysym,
                                    down ? 1u : 0u, mods);
    send_msg(h, &m);
}

void iosc_input_text(iosc_input_t *h, const char *utf8)
{
    if (!utf8) return;
    size_t len = strlen(utf8);
    if (len == 0) return;
    if (len > 4096) len = 4096;
    xios_msg m = xios_input_message(XIOS_IN_TEXT, 0, 0, (uint32_t)len, 0, 0);
    m.length = (uint32_t)len;
    send_msg(h, &m);
    send_bytes(h, utf8, len);
}

void iosc_input_touch(iosc_input_t *h, int slot, int phase, int x, int y)
{
    xios_msg m = xios_input_message(XIOS_IN_TOUCH, x, y, (uint32_t)slot,
                                    (uint32_t)phase, 0);
    send_msg(h, &m);
}

void iosc_input_tablet(iosc_input_t *h, int phase, int x, int y, unsigned pressure16,
                       int tilt_x_deg, int tilt_y_deg)
{
    if (tilt_x_deg < -90) tilt_x_deg = -90; if (tilt_x_deg > 90) tilt_x_deg = 90;
    if (tilt_y_deg < -90) tilt_y_deg = -90; if (tilt_y_deg > 90) tilt_y_deg = 90;
    xios_msg m = xios_input_message(
        XIOS_IN_TABLET, x, y,
        pressure16 > 65535u ? 65535u : pressure16, (uint32_t)phase,
        (uint32_t)(tilt_x_deg + 90) | ((uint32_t)(tilt_y_deg + 90) << 8));
    send_msg(h, &m);
}

void iosc_input_axis(iosc_input_t *h, int dx256, int dy256, unsigned source,
                     unsigned mods, bool stop)
{
    xios_msg m = xios_input_message(XIOS_IN_AXIS, dx256, dy256, source,
                                    stop ? 1u : 0u, mods);
    send_msg(h, &m);
}

void iosc_input_gesture(iosc_input_t *h, unsigned kind, unsigned phase, unsigned fingers,
                        int dx256, int dy256, unsigned scale256, int rot256)
{
    xios_msg m = xios_input_message(
        XIOS_IN_GESTURE, dx256, dy256,
        (kind & 0xffu) | ((phase & 0xffu) << 8) | ((fingers & 0xffu) << 16),
        scale256, (unsigned)rot256);
    send_msg(h, &m);
}

int iosc_input_poll_traits(iosc_input_t *h, unsigned *hint, unsigned *purpose, unsigned *enabled)
{
    if (!h || h->fd < 0) return -1;
    for (;;) {
        ssize_t r = read(h->fd, h->rx + h->rx_have, sizeof(h->rx) - (size_t)h->rx_have);
        if (r > 0) {
            h->rx_have += (int)r;
            if (h->rx_have == (int)sizeof(h->rx)) {
                xios_msg m;
                memcpy(&m, h->rx, sizeof(m));
                h->rx_have = 0;
                if (!h->hello_received) {
                    if (!xios_protocol_is_exact_hello(&m)) goto malformed;
                    h->hello_received = 1;
                    continue;
                }
                if (m.magic != XIOS_MSG_MAGIC || m.type == XIOS_MSG_HELLO ||
                    m.length != 0 ||
                    (m.type != XIOS_IN_TRAITS && m.type != XIOS_IN_HAPTIC))
                    goto malformed;
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
        if (r == 0) { close(h->fd); h->fd = -1; return -1; }
        if (errno == EINTR) continue;
        if (errno == EAGAIN || errno == EWOULDBLOCK) return 0;
        close(h->fd); h->fd = -1;
        return -1;
    }
malformed:
    close(h->fd); h->fd = -1;
    return -1;
}

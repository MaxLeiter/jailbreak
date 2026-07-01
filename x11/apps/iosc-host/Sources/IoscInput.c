/*
 * IoscInput.c — host (handle-based) copy of apps/Xios/Sources/IoscInput.c.
 * Same wire format; one connection per UIWindowScene, bound to a window id.
 */
#include "IoscInput.h"
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <sys/un.h>

#define XIOS_IN_MOTION 1u
#define XIOS_IN_BUTTON 2u
#define XIOS_IN_KEY    3u
#define XIOS_IN_TEXT   4u
#define XIOS_IN_TRAITS 5u
#define XIOS_IN_TOUCH  6u
#define XIOS_IN_TABLET 7u
/* PROPOSED: scope this connection to one window (code = window id). Add to
 * x11/wayland/xios_input_socket.h + iosc's reader before it does anything. */
#define XIOS_IN_BIND   8u

struct xios_in_msg {
    uint32_t type;
    int32_t  x, y;
    uint32_t code;
    uint32_t state;
    uint32_t mods;
};

struct iosc_input {
    int      fd;
    uint8_t  rx[sizeof(struct xios_in_msg)];
    int      rx_have;
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

static void send_msg(iosc_input_t *h, const struct xios_in_msg *m)
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

    /* Bind BEFORE going non-blocking so the compositor pins the connection to
     * this window before any event arrives. */
    struct xios_in_msg bind = { .type = XIOS_IN_BIND, .code = window };
    send_msg(h, &bind);

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
    struct xios_in_msg m = { .type = XIOS_IN_MOTION, .x = x, .y = y };
    send_msg(h, &m);
}

void iosc_input_button(iosc_input_t *h, int button, bool down, int x, int y)
{
    struct xios_in_msg m = { .type = XIOS_IN_BUTTON, .x = x, .y = y,
                             .code = (uint32_t)button, .state = down ? 1u : 0u };
    send_msg(h, &m);
}

void iosc_input_key(iosc_input_t *h, unsigned keysym, unsigned mods)
{
    struct xios_in_msg m = { .type = XIOS_IN_KEY, .code = keysym, .state = 1, .mods = mods };
    send_msg(h, &m);
}

void iosc_input_text(iosc_input_t *h, const char *utf8)
{
    if (!utf8) return;
    size_t len = strlen(utf8);
    if (len == 0) return;
    if (len > 4096) len = 4096;
    struct xios_in_msg m = { .type = XIOS_IN_TEXT, .code = (uint32_t)len };
    send_msg(h, &m);
    send_bytes(h, utf8, len);
}

void iosc_input_touch(iosc_input_t *h, int slot, int phase, int x, int y)
{
    struct xios_in_msg m = { .type = XIOS_IN_TOUCH, .x = x, .y = y,
                             .code = (uint32_t)slot, .state = (uint32_t)phase };
    send_msg(h, &m);
}

void iosc_input_tablet(iosc_input_t *h, int phase, int x, int y, unsigned pressure16,
                       int tilt_x_deg, int tilt_y_deg)
{
    if (tilt_x_deg < -90) tilt_x_deg = -90; if (tilt_x_deg > 90) tilt_x_deg = 90;
    if (tilt_y_deg < -90) tilt_y_deg = -90; if (tilt_y_deg > 90) tilt_y_deg = 90;
    struct xios_in_msg m = { .type = XIOS_IN_TABLET, .x = x, .y = y,
                             .code = pressure16 > 65535u ? 65535u : pressure16,
                             .state = (uint32_t)phase,
                             .mods = (uint32_t)(tilt_x_deg + 90) |
                                     ((uint32_t)(tilt_y_deg + 90) << 8) };
    send_msg(h, &m);
}

int iosc_input_poll_traits(iosc_input_t *h, unsigned *hint, unsigned *purpose, unsigned *enabled)
{
    if (!h || h->fd < 0) return -1;
    int got = 0;
    for (;;) {
        ssize_t r = read(h->fd, h->rx + h->rx_have, sizeof(h->rx) - (size_t)h->rx_have);
        if (r > 0) {
            h->rx_have += (int)r;
            if (h->rx_have == (int)sizeof(h->rx)) {
                struct xios_in_msg m;
                memcpy(&m, h->rx, sizeof(m));
                h->rx_have = 0;
                if (m.type == XIOS_IN_TRAITS) {
                    if (hint) *hint = m.code;
                    if (purpose) *purpose = m.state;
                    if (enabled) *enabled = m.mods;
                    got = 1;
                }
            }
            continue;
        }
        if (r == 0) { close(h->fd); h->fd = -1; return -1; }
        if (errno == EINTR) continue;
        if (errno == EAGAIN || errno == EWOULDBLOCK) return got;
        close(h->fd); h->fd = -1;
        return -1;
    }
}

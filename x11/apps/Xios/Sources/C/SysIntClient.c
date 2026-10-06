#include "SysIntClient.h"
#include "../../../shared/XiosProtocol.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <time.h>
#include <sys/socket.h>
#include <sys/un.h>

// Two independent links; each reconnects lazily, at most once per second, so a
// missing daemon costs one connect() a second, not one per send.
struct si_link {
    char        path[sizeof(((struct sockaddr_un *)0)->sun_path)];
    int         fd;
    int         hello_received;
    time_t      last_try;
    uint8_t     rx[sizeof(xios_msg)];
    int         rx_have;
};

// One handle per presented desktop. The caller serializes every call on one
// queue: nothing in here is thread-safe.
struct sysint_link {
    struct si_link sysint;
    struct si_link iosc;
    // Last state per record type, replayed on reconnect (compositor/daemon
    // restart must converge to the iPad's actual orientation/volume/appearance).
    xios_msg last_output, last_volume, last_appearance;
    int have_output, have_volume, have_appearance;
    // Brightness and volume requests ride the same link, so one drain would
    // starve the other: each poll stashes a record it is not looking for.
    unsigned pending_brightness;
    int      have_pending_brightness;
    unsigned pending_volume_set;
    int      have_pending_volume_set;
};

static void link_init(struct si_link *l, const char *path)
{
    memset(l, 0, sizeof(*l));
    l->fd = -1;
    snprintf(l->path, sizeof(l->path), "%s", path ? path : "");
}

sysint_link_t *sysint_link_open(const char *sysint_path, const char *iosc_path)
{
    sysint_link_t *h = calloc(1, sizeof(*h));
    if (!h) return NULL;
    link_init(&h->sysint, sysint_path);
    link_init(&h->iosc, iosc_path);
    return h;
}

void sysint_link_close(sysint_link_t *h)
{
    if (!h) return;
    if (h->sysint.fd >= 0) close(h->sysint.fd);
    if (h->iosc.fd >= 0) close(h->iosc.fd);
    free(h);
}

static int link_send_raw(struct si_link *l, const xios_msg *m)
{
    if (l->fd < 0) return -1;
    const char *p = (const char *)m;
    size_t put = 0;
    while (put < sizeof(*m)) {
        ssize_t w = write(l->fd, p + put, sizeof(*m) - put);
        if (w > 0) { put += (size_t)w; continue; }
        if (w < 0 && errno == EINTR) continue;
        close(l->fd);
        l->fd = -1;
        return -1;
    }
    return 0;
}

static void link_replay(sysint_link_t *h, struct si_link *l)
{
    if (l == &h->iosc) {
        if (h->have_output) link_send_raw(l, &h->last_output);
    } else {
        if (h->have_appearance) link_send_raw(l, &h->last_appearance);
        if (h->have_volume) link_send_raw(l, &h->last_volume);
    }
}

static int link_ensure(sysint_link_t *h, struct si_link *l)
{
    if (l->fd >= 0) return 0;
    if (!l->path[0]) return -1;
    time_t now = time(NULL);
    if (now == l->last_try) return -1;   // throttle: one attempt per second
    l->last_try = now;

    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    int on = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));
    struct sockaddr_un a;
    memset(&a, 0, sizeof(a));
    a.sun_family = AF_UNIX;
    strncpy(a.sun_path, l->path, sizeof(a.sun_path) - 1);
    if (connect(fd, (struct sockaddr *)&a, sizeof(a)) < 0) {
        close(fd);
        return -1;
    }
    xios_msg hello = xios_protocol_hello();
    const char *hp = (const char *)&hello;
    size_t left = sizeof(hello);
    while (left) {
        ssize_t w = write(fd, hp, left);
        if (w > 0) { hp += w; left -= (size_t)w; continue; }
        if (w < 0 && errno == EINTR) continue;
        close(fd);
        return -1;
    }
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK);
    l->fd = fd;
    l->hello_received = 0;
    link_replay(h, l);
    return 0;
}

static void link_send(sysint_link_t *h, struct si_link *l, const xios_msg *m,
                      xios_msg *last, int *have)
{
    *last = *m;
    *have = 1;
    if (link_ensure(h, l) != 0) return;  // stored; replayed when the link is back
    if (link_send_raw(l, m) != 0) {
        l->last_try = 0;
        if (link_ensure(h, l) == 0)
            (void)link_send_raw(l, m);
    }
}

void sysint_send_volume(sysint_link_t *h, unsigned v16)
{
    if (!h) return;
    xios_msg m = xios_input_message(XIOS_IN_VOLUME, 0, 0,
                                    v16 > 65535u ? 65535u : v16, 0, 0);
    link_send(h, &h->sysint, &m, &h->last_volume, &h->have_volume);
}

void sysint_send_appearance(sysint_link_t *h, int dark)
{
    if (!h) return;
    xios_msg m = xios_input_message(XIOS_IN_APPEARANCE, 0, 0,
                                    dark ? 1u : 0u, 0, 0);
    link_send(h, &h->sysint, &m, &h->last_appearance, &h->have_appearance);
}

void sysint_send_output(sysint_link_t *h, int transform, int logical_w, int logical_h)
{
    if (!h) return;
    xios_msg m = xios_input_message(XIOS_IN_OUTPUT, logical_w, logical_h,
                                    (uint32_t)(transform & 3), 0, 0);
    link_send(h, &h->iosc, &m, &h->last_output, &h->have_output);
}

// Aux-link reader: iosc broadcasts 32-byte xios_msg records to every input client
// (TRAITS for the keyboard bridge, HAPTIC for us). Only HAPTIC is surfaced;
// everything else is discarded — IoscInput.c's own connection handles traits.
static int link_poll_msg(sysint_link_t *h, struct si_link *l, xios_msg *out)
{
    uint8_t *rx = l->rx;
    int *rx_have = &l->rx_have;
    if (link_ensure(h, l) != 0) return 0;
    for (;;) {
        ssize_t r = read(l->fd, rx + *rx_have, sizeof(xios_msg) - (size_t)*rx_have);
        if (r > 0) {
            *rx_have += (int)r;
            if (*rx_have < (int)sizeof(xios_msg)) continue;
            memcpy(out, rx, sizeof(*out));
            *rx_have = 0;
            if (!l->hello_received) {
                if (!xios_protocol_is_exact_hello(out)) break;
                l->hello_received = 1;
                continue;
            }
            if (out->magic != XIOS_MSG_MAGIC || out->type == XIOS_MSG_HELLO ||
                out->length != 0 ||
                (l == &h->iosc
                    ? (out->type != XIOS_IN_HAPTIC && out->type != XIOS_IN_TRAITS)
                    : (out->type != XIOS_IN_VOLUME &&
                       out->type != XIOS_IN_BRIGHTNESS)))
                break;
            return 1;
        }
        if (r == 0) break;               // server closed
        if (errno == EINTR) continue;
        if (errno == EAGAIN || errno == EWOULDBLOCK) return 0;
        break;
    }
    close(l->fd);
    l->fd = -1;
    l->hello_received = 0;
    *rx_have = 0;
    return 0;
}

int sysint_poll_haptic(sysint_link_t *h, unsigned *style)
{
    if (!h) return 0;
    xios_msg m;
    if (link_ensure(h, &h->iosc) != 0) return 0;
    while (link_poll_msg(h, &h->iosc, &m) == 1) {
        if (m.type == XIOS_IN_HAPTIC) {
            if (style) *style = XIOS_INPUT_CODE(&m);
            return 1;                    // one per call; caller loops to drain
        }
    }
    return 0;
}

int sysint_poll_brightness_set(sysint_link_t *h, unsigned *v16)
{
    if (!h) return 0;
    if (h->have_pending_brightness) {
        h->have_pending_brightness = 0;
        if (v16) *v16 = h->pending_brightness;
        return 1;
    }
    xios_msg m;
    if (link_ensure(h, &h->sysint) != 0) return 0;
    while (link_poll_msg(h, &h->sysint, &m) == 1) {
        if (m.type == XIOS_IN_BRIGHTNESS &&
            (XIOS_INPUT_STATE(&m) & XIOS_BRIGHTNESS_STATE_TO_DEVICE)) {
            uint32_t code = XIOS_INPUT_CODE(&m);
            if (v16) *v16 = code > 65535u ? 65535u : code;
            return 1;
        }
        if (m.type == XIOS_IN_VOLUME &&
            (XIOS_INPUT_STATE(&m) & XIOS_VOLUME_STATE_TO_DEVICE)) {
            uint32_t code = XIOS_INPUT_CODE(&m);
            h->pending_volume_set = code > 65535u ? 65535u : code;
            h->have_pending_volume_set = 1;
        }
    }
    return 0;
}

int sysint_poll_volume_set(sysint_link_t *h, unsigned *v16)
{
    if (!h) return 0;
    if (h->have_pending_volume_set) {
        h->have_pending_volume_set = 0;
        if (v16) *v16 = h->pending_volume_set;
        return 1;
    }
    xios_msg m;
    if (link_ensure(h, &h->sysint) != 0) return 0;
    while (link_poll_msg(h, &h->sysint, &m) == 1) {
        if (m.type == XIOS_IN_VOLUME &&
            (XIOS_INPUT_STATE(&m) & XIOS_VOLUME_STATE_TO_DEVICE)) {
            uint32_t code = XIOS_INPUT_CODE(&m);
            if (v16) *v16 = code > 65535u ? 65535u : code;
            return 1;
        }
        if (m.type == XIOS_IN_BRIGHTNESS &&
            (XIOS_INPUT_STATE(&m) & XIOS_BRIGHTNESS_STATE_TO_DEVICE)) {
            uint32_t code = XIOS_INPUT_CODE(&m);
            h->pending_brightness = code > 65535u ? 65535u : code;
            h->have_pending_brightness = 1;
        }
    }
    return 0;
}

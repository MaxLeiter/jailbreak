#include "SysIntClient.h"
#include "../../shared/XiosProtocol.h"

#include <stdint.h>
#include <stdio.h>
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
};
static struct si_link s_sysint = { .path = "", .fd = -1 };
static struct si_link s_iosc   = { .path = "", .fd = -1 };

// Last state per record type, replayed on reconnect (compositor/daemon restart
// must converge to the iPad's actual orientation/volume/appearance).
static xios_msg s_last_output, s_last_volume, s_last_appearance;
static int s_have_output, s_have_volume, s_have_appearance;
static uint8_t s_iosc_rx[sizeof(xios_msg)];
static int s_iosc_rx_have;
static uint8_t s_sysint_rx[sizeof(xios_msg)];
static int s_sysint_rx_have;

static void link_set_path(struct si_link *l, const char *path, int *rx_have)
{
    const char *next = path ? path : "";
    if (strncmp(l->path, next, sizeof(l->path)) == 0) return;
    if (l->fd >= 0) close(l->fd);
    l->fd = -1;
    l->hello_received = 0;
    l->last_try = 0;
    if (rx_have) *rx_have = 0;
    snprintf(l->path, sizeof(l->path), "%s", next);
}

void sysint_set_iosc_socket(const char *path)
{
    link_set_path(&s_iosc, path, &s_iosc_rx_have);
}

void sysint_set_sysint_socket(const char *path)
{
    link_set_path(&s_sysint, path, &s_sysint_rx_have);
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

static void link_replay(struct si_link *l)
{
    if (l == &s_iosc) {
        if (s_have_output) link_send_raw(l, &s_last_output);
    } else {
        if (s_have_appearance) link_send_raw(l, &s_last_appearance);
        if (s_have_volume) link_send_raw(l, &s_last_volume);
    }
}

static int link_ensure(struct si_link *l)
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
    link_replay(l);
    return 0;
}

static void link_send(struct si_link *l, const xios_msg *m,
                      xios_msg *last, int *have)
{
    *last = *m;
    *have = 1;
    if (link_ensure(l) != 0) return;     // stored; replayed when the link is back
    if (link_send_raw(l, m) != 0) {
        l->last_try = 0;
        if (link_ensure(l) == 0)
            (void)link_send_raw(l, m);
    }
}

void sysint_send_volume(unsigned v16)
{
    xios_msg m = xios_input_message(XIOS_IN_VOLUME, 0, 0,
                                    v16 > 65535u ? 65535u : v16, 0, 0);
    link_send(&s_sysint, &m, &s_last_volume, &s_have_volume);
}

void sysint_send_appearance(int dark)
{
    xios_msg m = xios_input_message(XIOS_IN_APPEARANCE, 0, 0,
                                    dark ? 1u : 0u, 0, 0);
    link_send(&s_sysint, &m, &s_last_appearance, &s_have_appearance);
}

void sysint_send_output(int transform, int logical_w, int logical_h)
{
    xios_msg m = xios_input_message(XIOS_IN_OUTPUT, logical_w, logical_h,
                                    (uint32_t)(transform & 3), 0, 0);
    link_send(&s_iosc, &m, &s_last_output, &s_have_output);
}

// Aux-link reader: iosc broadcasts fixed 24-byte records to every input client
// (TRAITS for the keyboard bridge, HAPTIC for us). Only HAPTIC is surfaced;
// everything else is discarded — IoscInput.c's own connection handles traits.
static int link_poll_msg(struct si_link *l, uint8_t *rx, int *rx_have,
                         xios_msg *out)
{
    if (link_ensure(l) != 0) return 0;
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
                (l == &s_iosc
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

int sysint_poll_haptic(unsigned *style)
{
    xios_msg m;
    if (link_ensure(&s_iosc) != 0) return 0;
    while (link_poll_msg(&s_iosc, s_iosc_rx, &s_iosc_rx_have, &m) == 1) {
        if (m.type == XIOS_IN_HAPTIC) {
            if (style) *style = XIOS_INPUT_CODE(&m);
            return 1;                    // one per call; caller loops to drain
        }
    }
    return 0;
}

// Brightness requests ride the same link as volume, so one drain would starve the
// other: whichever poll ran first would consume and discard the other's records.
// Each poll therefore stashes a record it is not looking for instead of dropping it.
static unsigned s_pending_brightness;
static int      s_have_pending_brightness;
static unsigned s_pending_volume_set;
static int      s_have_pending_volume_set;

int sysint_poll_brightness_set(unsigned *v16)
{
    if (s_have_pending_brightness) {
        s_have_pending_brightness = 0;
        if (v16) *v16 = s_pending_brightness;
        return 1;
    }
    xios_msg m;
    if (link_ensure(&s_sysint) != 0) return 0;
    while (link_poll_msg(&s_sysint, s_sysint_rx, &s_sysint_rx_have, &m) == 1) {
        if (m.type == XIOS_IN_BRIGHTNESS &&
            (XIOS_INPUT_STATE(&m) & XIOS_BRIGHTNESS_STATE_TO_DEVICE)) {
            uint32_t code = XIOS_INPUT_CODE(&m);
            if (v16) *v16 = code > 65535u ? 65535u : code;
            return 1;
        }
        if (m.type == XIOS_IN_VOLUME &&
            (XIOS_INPUT_STATE(&m) & XIOS_VOLUME_STATE_TO_DEVICE)) {
            uint32_t code = XIOS_INPUT_CODE(&m);
            s_pending_volume_set = code > 65535u ? 65535u : code;
            s_have_pending_volume_set = 1;
        }
    }
    return 0;
}

int sysint_poll_volume_set(unsigned *v16)
{
    if (s_have_pending_volume_set) {
        s_have_pending_volume_set = 0;
        if (v16) *v16 = s_pending_volume_set;
        return 1;
    }
    xios_msg m;
    if (link_ensure(&s_sysint) != 0) return 0;
    while (link_poll_msg(&s_sysint, s_sysint_rx, &s_sysint_rx_have, &m) == 1) {
        if (m.type == XIOS_IN_VOLUME &&
            (XIOS_INPUT_STATE(&m) & XIOS_VOLUME_STATE_TO_DEVICE)) {
            uint32_t code = XIOS_INPUT_CODE(&m);
            if (v16) *v16 = code > 65535u ? 65535u : code;
            return 1;
        }
        if (m.type == XIOS_IN_BRIGHTNESS &&
            (XIOS_INPUT_STATE(&m) & XIOS_BRIGHTNESS_STATE_TO_DEVICE)) {
            uint32_t code = XIOS_INPUT_CODE(&m);
            s_pending_brightness = code > 65535u ? 65535u : code;
            s_have_pending_brightness = 1;
        }
    }
    return 0;
}

#include "SysIntClient.h"

#include <stdint.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <time.h>
#include <sys/socket.h>
#include <sys/un.h>

// Wire registry twin: x11/wayland/xios_input_socket.h (keep identical).
#define SI_OUTPUT     10u
#define SI_HAPTIC     11u
#define SI_VOLUME     12u
#define SI_APPEARANCE 13u
#define SI_VOLUME_TO_DEVICE 1u

struct si_msg {
    uint32_t type;
    int32_t  x, y;
    uint32_t code;
    uint32_t state;
    uint32_t mods;
};

#define SYSINT_SOCK  "/var/jb/tmp/xios-sysint.sock"
#define IOSC_IN_SOCK "/var/jb/tmp/iosc-input.sock"

// Two independent links; each reconnects lazily, at most once per second, so a
// missing daemon costs one connect() a second, not one per send.
struct si_link {
    const char *path;
    int         fd;
    time_t      last_try;
};
static struct si_link s_sysint = { SYSINT_SOCK, -1, 0 };
static struct si_link s_iosc   = { IOSC_IN_SOCK, -1, 0 };

// Last state per record type, replayed on reconnect (compositor/daemon restart
// must converge to the iPad's actual orientation/volume/appearance).
static struct si_msg s_last_output, s_last_volume, s_last_appearance;
static int s_have_output, s_have_volume, s_have_appearance;

static int link_send_raw(struct si_link *l, const struct si_msg *m)
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
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK);
    l->fd = fd;
    link_replay(l);
    return 0;
}

static void link_send(struct si_link *l, const struct si_msg *m,
                      struct si_msg *last, int *have)
{
    *last = *m;
    *have = 1;
    if (link_ensure(l) != 0) return;     // stored; replayed when the link is back
    link_send_raw(l, m);
}

void sysint_send_volume(unsigned v16)
{
    struct si_msg m = { .type = SI_VOLUME, .code = v16 > 65535u ? 65535u : v16 };
    link_send(&s_sysint, &m, &s_last_volume, &s_have_volume);
}

void sysint_send_appearance(int dark)
{
    struct si_msg m = { .type = SI_APPEARANCE, .code = dark ? 1u : 0u };
    link_send(&s_sysint, &m, &s_last_appearance, &s_have_appearance);
}

void sysint_send_output(int transform, int logical_w, int logical_h)
{
    struct si_msg m = { .type = SI_OUTPUT, .x = logical_w, .y = logical_h,
                        .code = (uint32_t)(transform & 3) };
    link_send(&s_iosc, &m, &s_last_output, &s_have_output);
}

// Aux-link reader: iosc broadcasts fixed 24-byte records to every input client
// (TRAITS for the keyboard bridge, HAPTIC for us). Only HAPTIC is surfaced;
// everything else is discarded — IoscInput.c's own connection handles traits.
static uint8_t s_iosc_rx[sizeof(struct si_msg)];
static int s_iosc_rx_have;
static uint8_t s_sysint_rx[sizeof(struct si_msg)];
static int s_sysint_rx_have;

static int link_poll_msg(struct si_link *l, uint8_t *rx, int *rx_have,
                         struct si_msg *out)
{
    if (link_ensure(l) != 0) return 0;
    for (;;) {
        ssize_t r = read(l->fd, rx + *rx_have, sizeof(struct si_msg) - (size_t)*rx_have);
        if (r > 0) {
            *rx_have += (int)r;
            if (*rx_have < (int)sizeof(struct si_msg)) continue;
            memcpy(out, rx, sizeof(*out));
            *rx_have = 0;
            return 1;
        }
        if (r == 0) break;               // server closed
        if (errno == EINTR) continue;
        if (errno == EAGAIN || errno == EWOULDBLOCK) return 0;
        break;
    }
    close(l->fd);
    l->fd = -1;
    *rx_have = 0;
    return 0;
}

int sysint_poll_haptic(unsigned *style)
{
    struct si_msg m;
    if (link_ensure(&s_iosc) != 0) return 0;
    while (link_poll_msg(&s_iosc, s_iosc_rx, &s_iosc_rx_have, &m) == 1) {
        if (m.type == SI_HAPTIC) {
            if (style) *style = m.code;
            return 1;                    // one per call; caller loops to drain
        }
    }
    return 0;
}

int sysint_poll_volume_set(unsigned *v16)
{
    struct si_msg m;
    if (link_ensure(&s_sysint) != 0) return 0;
    while (link_poll_msg(&s_sysint, s_sysint_rx, &s_sysint_rx_have, &m) == 1) {
        if (m.type == SI_VOLUME && (m.state & SI_VOLUME_TO_DEVICE)) {
            if (v16) *v16 = m.code > 65535u ? 65535u : m.code;
            return 1;
        }
    }
    return 0;
}

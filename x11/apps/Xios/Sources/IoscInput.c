#include "IoscInput.h"
#include <stdint.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <sys/socket.h>
#include <sys/un.h>

// One persistent AF_UNIX stream to iosc. A failed write (the compositor went away)
// marks the connection dead so the app's poll loop reconnects, mirroring how XInput.c
// recovers from a dropped X server.
static int s_fd = -1;

#define IOSC_IN_MOTION 1
#define IOSC_IN_BUTTON 2
#define IOSC_IN_KEY    3
#define IOSC_IN_TEXT   4

struct iosc_in_msg {
    uint32_t type;
    int32_t  x, y;
    uint32_t code;     // button 1/2/3 ; key: X keysym
    uint32_t state;    // button 1=down 0=up
    uint32_t mods;     // bit0 shift, bit1 ctrl, bit2 alt
};

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
    s_fd = fd;
    return true;
}

void iosc_input_close(void) {
    if (s_fd >= 0) { close(s_fd); s_fd = -1; }
}

bool iosc_input_is_open(void) { return s_fd >= 0; }

static void send_bytes(const void *buf, size_t n) {
    if (s_fd < 0) return;
    const char *p = (const char *)buf;
    size_t put = 0;
    while (put < n) {
        ssize_t w = write(s_fd, p + put, n - put);
        if (w > 0) { put += (size_t)w; continue; }
        if (w < 0 && errno == EINTR) continue;
        // EPIPE/EAGAIN/etc: drop the connection; the app reconnects on its next poll.
        iosc_input_close();
        return;
    }
}

static void send_msg(const struct iosc_in_msg *m) {
    send_bytes(m, sizeof(*m));
}

void iosc_input_motion(int x, int y) {
    struct iosc_in_msg m = { .type = IOSC_IN_MOTION, .x = x, .y = y };
    send_msg(&m);
}

void iosc_input_button(int button, bool down, int x, int y) {
    struct iosc_in_msg m = { .type = IOSC_IN_BUTTON, .x = x, .y = y,
                             .code = (uint32_t)button, .state = down ? 1u : 0u };
    send_msg(&m);
}

void iosc_input_key(unsigned keysym, unsigned mods) {
    struct iosc_in_msg m = { .type = IOSC_IN_KEY, .code = keysym, .state = 1, .mods = mods };
    send_msg(&m);
}

void iosc_input_text(const char *utf8) {
    if (!utf8) return;
    size_t len = strlen(utf8);
    if (len == 0) return;
    if (len > 4096) len = 4096;
    struct iosc_in_msg m = { .type = IOSC_IN_TEXT, .code = (uint32_t)len };
    send_msg(&m);
    send_bytes(utf8, len);
}

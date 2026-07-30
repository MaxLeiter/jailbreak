/*
 * NativeClient.c — client half of iosc-native.sock v1 (see NativeClient.h +
 * iosc_native_proto.h). Modeled on apps/Xios/Sources/XSurface.c's mach-port
 * rendezvous, generalized from one surface to per-window canvases.
 *
 * Canvas delivery: for WINDOW_NEW and WINDOW_GEOM, iosc writes the socket record
 * and then immediately mach_msg's that window's IOSurface send-right to the
 * receive port we named in BIND. We recv it (bounded) right after reading the
 * record, so the two stay correlated by arrival order on one connection.
 *
 * The iosc server half lives in wayland/xios_canvas.c + wayland/iosc.c; this is
 * the host-side reference client for the same wire contract.
 */
#include "NativeClient.h"
#include "iosc_native_proto.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <mach/mach.h>

struct iosc_native_client {
    int          fd;
    mach_port_t  rx;          /* receive port iosc delivers canvas send-rights to */
};

static void destroy_receive_port(mach_port_t rx)
{
    if (rx == MACH_PORT_NULL) return;
    mach_port_t self = mach_task_self();
    /* BIND gave iosc a name for this receive right, but we also inserted a local
     * send right so task_for_pid + mach_port_extract_right can copy it. Release
     * both refs; otherwise every reconnect leaks one send right. */
    mach_port_deallocate(self, rx);
    mach_port_mod_refs(self, rx, MACH_PORT_RIGHT_RECEIVE, -1);
}

/* ---- small IO helpers (same shape as XSurface.c) ------------------------- */

static int read_full(int fd, void *buf, size_t n)
{
    char *p = buf; size_t got = 0;
    while (got < n) {
        ssize_t r = read(fd, p + got, n - got);
        if (r > 0) { got += (size_t)r; continue; }
        if (r < 0 && errno == EINTR) continue;
        return -1;
    }
    return 0;
}

static int write_full(int fd, const void *buf, size_t n)
{
    const char *p = buf; size_t put = 0;
    while (put < n) {
        ssize_t w = write(fd, p + put, n - put);
        if (w > 0) { put += (size_t)w; continue; }
        if (w < 0 && errno == EINTR) continue;
        return -1;
    }
    return 0;
}

/* Send a header-only record (BIND payload handled separately). */
static int send_hdr(int fd, uint32_t type, uint32_t window,
                    int32_t a, int32_t b, int32_t c, int32_t d,
                    uint32_t payload_len)
{
    xios_msg h;
    memset(&h, 0, sizeof(h));
    h.magic = XIOS_MSG_MAGIC;
    h.type = type; h.window_id = window;
    h.length = payload_len;
    h.a = a; h.b = b; h.c = c; h.d = d;
    return write_full(fd, &h, sizeof(h));
}

/* Receive one canvas IOSurface send-right that follows a WINDOW_NEW/GEOM. */
static IOSurfaceRef recv_canvas(mach_port_t rx)
{
    typedef struct {
        mach_msg_header_t          header;
        mach_msg_body_t            body;
        mach_msg_port_descriptor_t port;
        mach_msg_trailer_t         trailer;
    } canvas_msg;

    canvas_msg msg;
    memset(&msg, 0, sizeof(msg));
    /* MACH_RCV_TIMEOUT must be in the option mask or the timeout is ignored. */
    kern_return_t kr = mach_msg(&msg.header, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0,
                                sizeof(msg), rx, 3000 /*ms*/, MACH_PORT_NULL);
    if (kr != KERN_SUCCESS ||
        !(msg.header.msgh_bits & MACH_MSGH_BITS_COMPLEX) ||
        msg.body.msgh_descriptor_count != 1 ||
        msg.port.type != MACH_MSG_PORT_DESCRIPTOR ||
        msg.port.name == MACH_PORT_NULL) {
        return NULL;
    }
    IOSurfaceRef s = IOSurfaceLookupFromMachPort(msg.port.name);
    mach_port_deallocate(mach_task_self(), msg.port.name);
    return s;   /* +1; caller releases */
}

/* ---- lifecycle ----------------------------------------------------------- */

iosc_native_client *iosc_native_connect(const char *sock_path, const char *app_id,
                                        int scene_w, int scene_h, int scale)
{
    const char *path = sock_path && *sock_path ? sock_path : IOSC_NATIVE_SOCK;
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return NULL;
    int on = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));

    struct sockaddr_un a;
    memset(&a, 0, sizeof(a));
    a.sun_family = AF_UNIX;
    strncpy(a.sun_path, path, sizeof(a.sun_path) - 1);
    if (connect(fd, (struct sockaddr *)&a, sizeof(a)) < 0) { close(fd); return NULL; }

    mach_port_t self = mach_task_self();
    mach_port_t rx = MACH_PORT_NULL;
    if (mach_port_allocate(self, MACH_PORT_RIGHT_RECEIVE, &rx) != KERN_SUCCESS) {
        close(fd); return NULL;
    }
    if (mach_port_insert_right(self, rx, rx, MACH_MSG_TYPE_MAKE_SEND) != KERN_SUCCESS) {
        mach_port_mod_refs(self, rx, MACH_PORT_RIGHT_RECEIVE, -1);
        close(fd); return NULL;
    }

    /* BIND: params carry scene geometry + scale + the receive-port name; the
     * app_id is the UTF-8 payload. */
    size_t idlen = app_id ? strlen(app_id) : 0;
    if (idlen > 200) idlen = 200;
    if (send_hdr(fd, XIOS_MSG_BIND, XIOS_PROTOCOL_VERSION,
                 (int32_t)scene_w, (int32_t)scene_h, (int32_t)scale,
                 (int32_t)rx, (uint32_t)idlen) != 0 ||
        (idlen && write_full(fd, app_id, idlen) != 0)) {
        destroy_receive_port(rx);
        close(fd); return NULL;
    }

    /* Require the server's exact version before returning a live client. */
    struct pollfd hello_poll = { .fd = fd, .events = POLLIN };
    xios_msg hello;
    if (poll(&hello_poll, 1, 3000) <= 0 ||
        read_full(fd, &hello, sizeof(hello)) != 0 ||
        hello.magic != XIOS_MSG_MAGIC ||
        hello.type != XIOS_MSG_HELLO ||
        hello.window_id != XIOS_PROTOCOL_VERSION ||
        hello.length != 0 ||
        hello.a != 0 || hello.b != 0 || hello.c != 0 || hello.d != 0) {
        fprintf(stderr,
                "iosc-native: protocol v%u HELLO missing/mismatched\n",
                XIOS_PROTOCOL_VERSION);
        destroy_receive_port(rx);
        close(fd);
        return NULL;
    }

    iosc_native_client *c = calloc(1, sizeof(*c));
    if (!c) { destroy_receive_port(rx); close(fd); return NULL; }
    c->fd = fd;
    c->rx = rx;
    /* Keep the fd blocking. iosc_native_next polls before each record, then
     * read_full drains the whole record/payload. A non-blocking fd can return
     * EAGAIN mid-record and look like a compositor disconnect. */
    return c;
}

int iosc_native_fd(iosc_native_client *c) { return c ? c->fd : -1; }

int iosc_native_next(iosc_native_client *c, int timeout_ms, iosc_native_event *ev)
{
    if (!c || !ev) return -1;
    memset(ev, 0, sizeof(*ev));

    struct pollfd p = { .fd = c->fd, .events = POLLIN };
    int pr = poll(&p, 1, timeout_ms);
    if (pr == 0) { ev->type = IOSC_NEV_NONE; return 0; }
    if (pr < 0) { if (errno == EINTR) { ev->type = IOSC_NEV_NONE; return 0; } goto dead; }

    xios_msg h;
    /* One full record (blocking read is fine: poll said data is ready and iosc
     * writes whole records; short reads loop in read_full). */
    if (read_full(c->fd, &h, sizeof(h)) != 0 || h.magic != XIOS_MSG_MAGIC) goto dead;

    /* Read the trailing payload if any. Titles fit in 255 bytes; anything larger
     * (e.g. a CURSOR bitmap we don't render) is drained past the buffer. */
    char payload[256];
    uint32_t plen = h.length;
    if (plen > sizeof(payload) - 1) plen = sizeof(payload) - 1;
    if (h.length) {
        char scratch[512];
        uint32_t left = h.length;
        uint32_t keep = plen;
        if (read_full(c->fd, payload, keep) != 0) goto dead;
        payload[keep] = 0;
        left -= keep;
        while (left) {                         /* drain any overflow past 255 */
            uint32_t chunk = left > sizeof(scratch) ? (uint32_t)sizeof(scratch) : left;
            if (read_full(c->fd, scratch, chunk) != 0) goto dead;
            left -= chunk;
        }
    } else {
        payload[0] = 0;
    }

    ev->window = h.window_id;
    ev->width  = (int)h.a;
    ev->height = (int)h.b;
    ev->flags  = (uint32_t)h.d;

    switch (h.type) {
    case XIOS_MSG_WINDOW_NEW:
    case XIOS_MSG_WINDOW_GEOM: {
        IOSurfaceRef s = recv_canvas(c->rx);
        if (!s) goto dead;
        ev->surface = s;
        if (h.type == XIOS_MSG_WINDOW_NEW) {
            ev->type = IOSC_NEV_WINDOW_NEW;
            memcpy(ev->title, payload, plen + 1);
        } else {
            ev->type = IOSC_NEV_WINDOW_GEOM;
        }
        return 1;
    }
    case XIOS_MSG_NATIVE_FRAME: {
        uint64_t value =
            ((uint64_t)(uint32_t)h.b << 32) | (uint32_t)h.a;
        if (h.length != XIOS_GPU_FENCE_TOKEN_SIZE ||
            value == 0 || h.c != 0 || h.d != 0) {
            fprintf(stderr, "iosc-native: invalid fenced frame record\n");
            goto dead;
        }
        ev->fence_value = value;
        memcpy(ev->fence_token, payload, XIOS_GPU_FENCE_TOKEN_SIZE);
        ev->type = IOSC_NEV_DIRTY;
        return 1;
    }
    case XIOS_MSG_WINDOW_GONE: ev->type = IOSC_NEV_WINDOW_GONE; return 1;
    case XIOS_MSG_WINDOW_TITLE:
        ev->type = IOSC_NEV_TITLE;
        memcpy(ev->title, payload, plen + 1);
        return 1;
    case XIOS_MSG_CURSOR:
        /* Shape rides in c (cursor-shape-v1 id); a,b = pointer pos; bitmap
         * payload (if any) was drained above — we map shape ids only. */
        ev->type = IOSC_NEV_CURSOR;
        ev->cursor_id = (uint32_t)h.c;
        return 1;
    case XIOS_MSG_HELLO:
        fprintf(stderr, "iosc-native: duplicate HELLO; disconnecting\n");
        goto dead;
    default:
        fprintf(stderr, "iosc-native: unknown compositor record type=0x%x; disconnecting\n",
                h.type);
        goto dead;
    }

dead:
    ev->type = IOSC_NEV_DISCONNECT;
    return -1;
}

void iosc_native_resize(iosc_native_client *c, uint32_t window, int w, int h)
{
    if (c && c->fd >= 0) send_hdr(c->fd, XIOS_MSG_RESIZE, window, w, h, 0, 0, 0);
}

void iosc_native_activate(iosc_native_client *c, uint32_t window, int active)
{
    if (c && c->fd >= 0) send_hdr(c->fd, XIOS_MSG_ACTIVATE, window, active ? 1 : 0, 0, 0, 0, 0);
}

void iosc_native_closed(iosc_native_client *c, uint32_t window)
{
    if (c && c->fd >= 0) send_hdr(c->fd, XIOS_MSG_CLOSED, window, 0, 0, 0, 0, 0);
}

void iosc_native_close(iosc_native_client *c)
{
    if (!c) return;
    destroy_receive_port(c->rx);
    if (c->fd >= 0) close(c->fd);
    free(c);
}

#include "XSurface.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/time.h>
#include <mach/mach.h>
#include <stdarg.h>

/* Diagnostic log (app stderr isn't easily captured on iOS). */
static void xlog(const char *fmt, ...)
{
    FILE *f = fopen("/var/jb/tmp/xsurface.log", "a");
    if (!f) return;
    va_list ap; va_start(ap, fmt); vfprintf(f, fmt, ap); va_end(ap);
    fputc('\n', f); fclose(f);
}

/* wire protocol — must match the server (linux-build/patches/xios/xios_surface.c).
 * Classic clients (hello.reserved == 0) get a stream of single "dirty" bytes.
 * We negotiate the TYPED stream (reserved == XIOS_HELLO_TYPED): after the same
 * handshake the server sends 32-byte records (an in-band HELLO on connect, then
 * DIRTY + CURSOR interleaved), so the cursor overlay and the geometry come over
 * the socket itself. See xios_surface.h for the shared definitions. */
#define XIOS_MAGIC      0x58494F31u   /* 'XIO1' */

typedef struct { uint32_t magic, pid, portname, reserved; } xios_hello;
typedef struct { uint32_t magic, width, height, stride, format, status; } xios_reply;

#define XIOS_HELLO_TYPED 0x54595031u  /* 'TYP1' in hello.reserved => typed stream */
#define XIOS_MSG_MAGIC   0x584D5331u  /* 'XMS1' per-record frame sync */
enum { XIOS_MSG_HELLO = 0x01, XIOS_MSG_DIRTY = 0x02, XIOS_MSG_CURSOR = 0x03 };
typedef struct {
    uint32_t magic, type, window_id, length;
    int32_t  a, b, c, d;
} xios_msg;                            /* 32 bytes, LE; optional length-byte payload */

typedef struct {
    mach_msg_header_t header;
    mach_msg_body_t body;
    mach_msg_port_descriptor_t port;
    mach_msg_trailer_t trailer;
} xios_port_msg;

struct XSurfaceConn {
    int fd;
    IOSurfaceRef surface;
    int width, height, stride;
    int typed;                 /* negotiated the typed record stream */
    char comp_id[32];          /* compositor id from the in-band HELLO ("iosc"/...) */
    /* typed-stream parser state (records span multiple non-blocking reads) */
    unsigned char rxbuf[sizeof(xios_msg)];
    int rxlen;                 /* header bytes buffered so far */
    int skip;                  /* payload bytes still to discard after a header */
    /* latest cursor state (from CURSOR records) */
    int cur_x, cur_y, cur_vis, cur_shape;
    uint32_t cur_seq;          /* bumped per CURSOR record; 0 = none seen */
};

static int read_full(int fd, void *buf, size_t n)
{
    char *p = buf;
    size_t got = 0;
    while (got < n) {
        ssize_t r = read(fd, p + got, n - got);
        if (r > 0) { got += (size_t) r; continue; }
        if (r < 0 && errno == EINTR) continue;
        return -1;
    }
    return 0;
}

static int write_full(int fd, const void *buf, size_t n)
{
    const char *p = buf;
    size_t put = 0;
    while (put < n) {
        ssize_t w = write(fd, p + put, n - put);
        if (w > 0) { put += (size_t) w; continue; }
        if (w < 0 && errno == EINTR) continue;
        return -1;
    }
    return 0;
}

static void destroy_reply_port(mach_port_t task, mach_port_t port)
{
    if (port == MACH_PORT_NULL)
        return;
    mach_port_mod_refs(task, port, MACH_PORT_RIGHT_SEND, -1);
    mach_port_mod_refs(task, port, MACH_PORT_RIGHT_RECEIVE, -1);
}

XSurfaceConn *xsurface_connect(const char *sock_path)
{
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) { xlog("socket() failed errno=%d", errno); return NULL; }
    if (strlen(sock_path) >= sizeof(((struct sockaddr_un *) 0)->sun_path)) {
        xlog("socket path too long: %s", sock_path);
        close(fd);
        return NULL;
    }

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, sock_path, sizeof(addr.sun_path) - 1);
    if (connect(fd, (struct sockaddr *) &addr, sizeof(addr)) < 0) {
        /* expected while the server isn't up yet; caller retries silently */
        close(fd);
        return NULL;
    }
    struct timeval tv;
    tv.tv_sec = 5;
    tv.tv_usec = 0;
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    mach_port_t self = mach_task_self();
    mach_port_t r = MACH_PORT_NULL;
    if (mach_port_allocate(self, MACH_PORT_RIGHT_RECEIVE, &r) != KERN_SUCCESS) {
        close(fd); return NULL;
    }
    if (mach_port_insert_right(self, r, r, MACH_MSG_TYPE_MAKE_SEND) != KERN_SUCCESS) {
        destroy_reply_port(self, r); close(fd); return NULL;
    }

    xios_hello hello;
    hello.magic = XIOS_MAGIC;
    hello.pid = (uint32_t) getpid();
    hello.portname = (uint32_t) r;
    hello.reserved = XIOS_HELLO_TYPED;   /* opt into the typed stream (cursor + in-band hello) */
    if (write_full(fd, &hello, sizeof(hello)) != 0) {
        destroy_reply_port(self, r); close(fd); return NULL;
    }

    /* Receive the IOSurface mach port the server delivers. */
    xios_port_msg msg;
    memset(&msg, 0, sizeof(msg));
    /* MACH_RCV_TIMEOUT must be in the option mask or the timeout arg is ignored and
     * this blocks forever (a server that never delivers would hang this thread). */
    kern_return_t kr = mach_msg(&msg.header, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0,
                                sizeof(msg), r, 5000 /*ms*/, MACH_PORT_NULL);
    if (kr != KERN_SUCCESS ||
        !(msg.header.msgh_bits & MACH_MSGH_BITS_COMPLEX) ||
        msg.body.msgh_descriptor_count != 1 ||
        msg.port.type != MACH_MSG_PORT_DESCRIPTOR ||
        msg.port.name == MACH_PORT_NULL) {
        xlog("mach_msg recv failed kr=0x%x complex=%d descriptors=%u type=%u port=%u",
             kr, (int) !!(msg.header.msgh_bits & MACH_MSGH_BITS_COMPLEX),
             msg.body.msgh_descriptor_count, msg.port.type, msg.port.name);
        destroy_reply_port(self, r); close(fd); return NULL;
    }
    IOSurfaceRef surface = IOSurfaceLookupFromMachPort(msg.port.name);
    /* The receive port has done its job; drop it. */
    mach_port_deallocate(self, msg.port.name);
    destroy_reply_port(self, r);
    if (!surface) {
        xlog("IOSurfaceLookupFromMachPort returned NULL");
        close(fd); return NULL;
    }

    /* Drain the geometry reply so the socket stream is aligned for damage msgs. */
    xios_reply reply;
    if (read_full(fd, &reply, sizeof(reply)) != 0 || reply.magic != XIOS_MAGIC ||
        reply.status != 0) {
        xlog("reply read failed magic=0x%x status=%u", reply.magic, reply.status);
        CFRelease(surface); close(fd); return NULL;
    }

    XSurfaceConn *c = calloc(1, sizeof(*c));
    if (!c) { CFRelease(surface); close(fd); return NULL; }
    c->fd = fd;
    c->surface = surface;
    /* Trust the surface itself for geometry (single source of truth). */
    c->width = (int) IOSurfaceGetWidth(surface);
    c->height = (int) IOSurfaceGetHeight(surface);
    c->stride = (int) IOSurfaceGetBytesPerRow(surface);

    /* We negotiated the typed stream: a typed-capable server sends an in-band
     * HELLO record (magic XMS1, type HELLO) as the first bytes after the reply,
     * still blocking here (the server sends it before flipping the socket to
     * non-blocking). Read it to learn the compositor id. If it doesn't arrive or
     * doesn't parse (an older server that ignored hello.reserved and just streams
     * bare DIRTY bytes), fall back to the classic path — the surface is already
     * adopted, so nothing is lost but the overlay. */
    xios_msg h;
    if (read_full(fd, &h, sizeof(h)) == 0 && h.magic == XIOS_MSG_MAGIC &&
        h.type == XIOS_MSG_HELLO) {
        c->typed = 1;
        uint32_t idlen = h.length;
        if (idlen > sizeof(c->comp_id) - 1) idlen = sizeof(c->comp_id) - 1;
        if (idlen && read_full(fd, c->comp_id, idlen) != 0) {
            CFRelease(surface); free(c); close(fd); return NULL;
        }
        c->comp_id[idlen] = '\0';
        xlog("typed stream negotiated (compositor=%s)", c->comp_id);
    } else {
        xlog("classic stream (no in-band HELLO); cursor overlay disabled");
    }

    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK);
    return c;
}

IOSurfaceRef xsurface_get(XSurfaceConn *c) { return c ? c->surface : NULL; }
int xsurface_width(XSurfaceConn *c)  { return c ? c->width : 0; }
int xsurface_height(XSurfaceConn *c) { return c ? c->height : 0; }
int xsurface_stride(XSurfaceConn *c) { return c ? c->stride : 0; }
int xsurface_fd(XSurfaceConn *c)     { return c ? c->fd : -1; }

/* Classic stream: any bytes = the surface changed (bare DIRTY signals). */
static int drain_classic(XSurfaceConn *c)
{
    unsigned char tmp[64];
    int dirty = 0;
    for (;;) {
        ssize_t r = recv(c->fd, tmp, sizeof(tmp), MSG_DONTWAIT);
        if (r > 0) { dirty = 1; continue; }
        if (r == 0) return -1;                 /* server closed */
        if (errno == EAGAIN || errno == EWOULDBLOCK) break;
        if (errno == EINTR) continue;
        return -1;
    }
    return dirty;
}

/* Typed stream: parse 32-byte records (DIRTY + CURSOR, plus any HELLO/native
 * records whose payload we skip). Records span multiple non-blocking reads, so the
 * partial-header + payload-skip state lives in the conn. A magic mismatch means the
 * stream desynced — return -1 so the caller reconnects. */
static int drain_typed(XSurfaceConn *c)
{
    int dirty = 0;
    for (;;) {
        if (c->skip > 0) {                     /* discard a record's payload */
            unsigned char scratch[64];
            int want = c->skip < (int) sizeof scratch ? c->skip : (int) sizeof scratch;
            ssize_t r = recv(c->fd, scratch, want, MSG_DONTWAIT);
            if (r > 0) { c->skip -= (int) r; continue; }
            if (r == 0) return -1;
            if (errno == EAGAIN || errno == EWOULDBLOCK) break;
            if (errno == EINTR) continue;
            return -1;
        }
        ssize_t r = recv(c->fd, c->rxbuf + c->rxlen,
                         (int) sizeof(xios_msg) - c->rxlen, MSG_DONTWAIT);
        if (r > 0) {
            c->rxlen += (int) r;
            if (c->rxlen < (int) sizeof(xios_msg)) continue;   /* partial header */
            xios_msg m;
            memcpy(&m, c->rxbuf, sizeof m);
            c->rxlen = 0;
            if (m.magic != XIOS_MSG_MAGIC) { xlog("typed desync magic=0x%x", m.magic); return -1; }
            switch (m.type) {
            case XIOS_MSG_DIRTY:
                dirty = 1;
                break;
            case XIOS_MSG_CURSOR:
                c->cur_x = m.a; c->cur_y = m.b;
                c->cur_shape = m.c; c->cur_vis = (m.d & 1);
                c->cur_seq++;
                break;
            case XIOS_MSG_HELLO:               /* rare post-connect geometry refresh */
                if (m.a > 0) c->width = m.a;
                if (m.b > 0) c->height = m.b;
                if (m.c > 0) c->stride = m.c;
                break;
            default:                           /* unknown core/native type: ignore */
                break;
            }
            if (m.length > 0) c->skip = (int) m.length;
            continue;
        }
        if (r == 0) return -1;
        if (errno == EAGAIN || errno == EWOULDBLOCK) break;
        if (errno == EINTR) continue;
        return -1;
    }
    return dirty;
}

int xsurface_drain(XSurfaceConn *c)
{
    if (!c) return -1;
    return c->typed ? drain_typed(c) : drain_classic(c);
}

uint32_t xsurface_cursor(XSurfaceConn *c, int *x, int *y, int *visible, int *shape_id)
{
    if (!c) return 0;
    if (x) *x = c->cur_x;
    if (y) *y = c->cur_y;
    if (visible) *visible = c->cur_vis;
    if (shape_id) *shape_id = c->cur_shape;
    return c->cur_seq;
}

const char *xsurface_compositor_id(XSurfaceConn *c) { return c ? c->comp_id : ""; }

void xsurface_close(XSurfaceConn *c)
{
    if (!c) return;
    if (c->surface) CFRelease(c->surface);
    if (c->fd >= 0) close(c->fd);
    free(c);
}

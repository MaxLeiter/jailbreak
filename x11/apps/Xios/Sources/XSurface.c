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
 * Damage is a stream of single "dirty" bytes (xsurface_drain just counts them). */
#define XIOS_MAGIC      0x58494F31u   /* 'XIO1' */

typedef struct { uint32_t magic, pid, portname, reserved; } xios_hello;
typedef struct { uint32_t magic, width, height, stride, format, status; } xios_reply;

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
    hello.reserved = 0;
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

    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK);
    return c;
}

IOSurfaceRef xsurface_get(XSurfaceConn *c) { return c ? c->surface : NULL; }
int xsurface_width(XSurfaceConn *c)  { return c ? c->width : 0; }
int xsurface_height(XSurfaceConn *c) { return c ? c->height : 0; }
int xsurface_stride(XSurfaceConn *c) { return c ? c->stride : 0; }
int xsurface_fd(XSurfaceConn *c)     { return c ? c->fd : -1; }

int xsurface_drain(XSurfaceConn *c)
{
    if (!c) return -1;
    unsigned char tmp[64];
    int dirty = 0;

    for (;;) {
        ssize_t r = recv(c->fd, tmp, sizeof(tmp), MSG_DONTWAIT);
        if (r > 0) { dirty = 1; continue; }    /* any bytes => surface changed */
        if (r == 0) return -1;                 /* server closed */
        if (errno == EAGAIN || errno == EWOULDBLOCK) break;
        if (errno == EINTR) continue;
        return -1;
    }
    return dirty;
}

void xsurface_close(XSurfaceConn *c)
{
    if (!c) return;
    if (c->surface) CFRelease(c->surface);
    if (c->fd >= 0) close(c->fd);
    free(c);
}

#include "XSurface.h"
#include "../../shared/XiosProtocol.h"

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
#include <stdint.h>

/* Diagnostic log (app stderr isn't easily captured on iOS). */
static void xlog(const char *fmt, ...)
{
    const char *tmp = getenv("XIOS_RUNTIME_TMP");
    if (!tmp || !*tmp) tmp = access("/var/jb/usr", X_OK) == 0 ? "/var/jb/tmp" : "/var/tmp";
    char path[1024];
    snprintf(path, sizeof(path), "%s/xsurface.log", tmp);
    FILE *f = fopen(path, "a");
    if (!f) return;
    va_list ap; va_start(ap, fmt); vfprintf(f, fmt, ap); va_end(ap);
    fputc('\n', f); fclose(f);
}

/* Wire protocol is the canonical xios_msg stream from XiosProtocol.h. Both
 * directions start with an exact-version HELLO; there is no legacy preamble.
 * That header is also where XIOS_MSG_PACING and PRESENTED's present-time fields
 * are defined — this file only sends them. */

typedef struct {
    mach_msg_header_t header;
    mach_msg_body_t body;
    mach_msg_port_descriptor_t port;
    mach_msg_trailer_t trailer;
} xios_port_msg;

#define XSURFACE_MAX_SURFACES 128

struct xsurface_item {
    IOSurfaceRef surface;
    uint32_t id;
    uint32_t flags;
    int width, height, stride;
    int retired;
};

struct XSurfaceConn {
    int fd;
    mach_port_t reply_port;
    struct xsurface_item surfaces[XSURFACE_MAX_SURFACES];
    int surface_count;
    uint32_t current_surface_id;
    int width, height, stride;
    char comp_id[32];          /* compositor id from the in-band HELLO ("iosc"/...) */
    unsigned char release_token[XIOS_GPU_FENCE_TOKEN_SIZE];
    uint32_t release_token_size;
    /* typed-stream parser state (records span multiple non-blocking reads) */
    unsigned char rxbuf[sizeof(xios_msg)];
    int rxlen;                 /* header bytes buffered so far */
    int skip;                  /* payload bytes still to discard after a header */
    uint32_t fence_rx_expected;
    uint32_t fence_rx_got;
    uint32_t fence_rx_surface_id;
    uint64_t fence_rx_dirty_seq;
    uint64_t fence_rx_value;
    unsigned char fence_token[XIOS_GPU_FENCE_TOKEN_SIZE];
    uint32_t fence_token_size;
    uint64_t fence_dirty_seq;
    uint64_t fence_value;
    /* latest cursor state (from CURSOR records) */
    int cur_x, cur_y, cur_vis, cur_shape;
    uint32_t cur_seq;          /* bumped per CURSOR record; 0 = none seen */
    uint64_t dirty_seq;        /* latest DIRTY present sequence from the compositor */
    xios_msg pending_surface;
    int has_pending_surface;
};

static struct xsurface_item *find_surface(XSurfaceConn *c, uint32_t id)
{
    if (!c) return NULL;
    for (int i = 0; i < c->surface_count; i++)
        if (c->surfaces[i].surface && c->surfaces[i].id == id)
            return &c->surfaces[i];
    return NULL;
}

static void remove_surface(XSurfaceConn *c, uint32_t id)
{
    struct xsurface_item *item = find_surface(c, id);
    if (!item) return;
    CFRelease(item->surface);
    int index = (int)(item - c->surfaces);
    c->surfaces[index] = c->surfaces[--c->surface_count];
    memset(&c->surfaces[c->surface_count], 0,
           sizeof(c->surfaces[c->surface_count]));
}

static int receive_surface_port(mach_port_t reply_port, uint32_t timeout_ms,
                                IOSurfaceRef *surface_out)
{
    if (surface_out) *surface_out = NULL;
    xios_port_msg msg;
    memset(&msg, 0, sizeof(msg));
    kern_return_t kr = mach_msg(&msg.header,
                                MACH_RCV_MSG | MACH_RCV_TIMEOUT,
                                0, sizeof(msg), reply_port,
                                timeout_ms, MACH_PORT_NULL);
    if (kr == MACH_RCV_TIMED_OUT)
        return 0;
    if (kr != KERN_SUCCESS ||
        !(msg.header.msgh_bits & MACH_MSGH_BITS_COMPLEX) ||
        msg.body.msgh_descriptor_count != 1 ||
        msg.port.type != MACH_MSG_PORT_DESCRIPTOR ||
        msg.port.name == MACH_PORT_NULL) {
        xlog("mach_msg recv failed kr=0x%x complex=%d descriptors=%u type=%u port=%u",
             kr, (int)!!(msg.header.msgh_bits & MACH_MSGH_BITS_COMPLEX),
             msg.body.msgh_descriptor_count, msg.port.type, msg.port.name);
        return -1;
    }
    IOSurfaceRef surface = IOSurfaceLookupFromMachPort(msg.port.name);
    mach_port_deallocate(mach_task_self(), msg.port.name);
    if (!surface) {
        xlog("IOSurfaceLookupFromMachPort returned NULL");
        return -1;
    }
    if (surface_out) *surface_out = surface;
    else CFRelease(surface);
    return 1;
}

static int add_surface(XSurfaceConn *c, uint32_t id, uint32_t flags,
                       int width, int height, int stride, IOSurfaceRef surface)
{
    if (!c || !surface || id == 0 ||
        (flags & ~XIOS_SURFACE_FLAG_FLIP_Y))
        return -1;
    struct xsurface_item *old = find_surface(c, id);
    if (old) {
        CFRelease(old->surface);
        old->surface = surface;
        old->flags = flags;
        old->width = width;
        old->height = height;
        old->stride = stride;
        old->retired = 0;
        return 0;
    }
    if (c->surface_count >= XSURFACE_MAX_SURFACES)
        return -1;
    struct xsurface_item *item = &c->surfaces[c->surface_count++];
    item->surface = surface;
    item->id = id;
    item->flags = flags;
    item->width = width;
    item->height = height;
    item->stride = stride;
    return 0;
}

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

static XSurfaceConn *xsurface_connect_caps(const char *sock_path, uint32_t caps)
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

    xios_msg hello;
    memset(&hello, 0, sizeof(hello));
    hello.magic = XIOS_MSG_MAGIC;
    hello.type = XIOS_MSG_HELLO;
    hello.window_id = XIOS_PROTOCOL_VERSION;
    hello.a = (int32_t) getpid();       /* diagnostic only; server trusts peer pid */
    hello.b = (int32_t) r;
    hello.c = (int32_t)caps;
    if (write_full(fd, &hello, sizeof(hello)) != 0) {
        destroy_reply_port(self, r); close(fd); return NULL;
    }

    /* Receive the IOSurface mach port the server delivers. */
    IOSurfaceRef primary = NULL;
    if (receive_surface_port(r, caps ? 1500 : 5000, &primary) != 1) {
        destroy_reply_port(self, r); close(fd); return NULL;
    }

    /* The server's HELLO is the first socket reply. The IOSurface itself remains
     * the geometry source of truth; HELLO must describe that exact allocation. */
    xios_msg h;
    memset(&h, 0, sizeof(h));
    if (read_full(fd, &h, sizeof(h)) != 0 || h.magic != XIOS_MSG_MAGIC ||
        h.type != XIOS_MSG_HELLO ||
        h.window_id != XIOS_PROTOCOL_VERSION ||
        h.length >= sizeof(((XSurfaceConn *)0)->comp_id)) {
        xlog("v%u HELLO missing/malformed (magic=0x%x type=%u version=%u)",
             XIOS_PROTOCOL_VERSION, h.magic, h.type, h.window_id);
        CFRelease(primary); destroy_reply_port(self, r); close(fd); return NULL;
    }
    XSurfaceConn *c = calloc(1, sizeof(*c));
    if (!c) {
        CFRelease(primary); destroy_reply_port(self, r); close(fd); return NULL;
    }
    c->fd = fd;
    c->reply_port = r;
    c->width = (int) IOSurfaceGetWidth(primary);
    c->height = (int) IOSurfaceGetHeight(primary);
    c->stride = (int) IOSurfaceGetBytesPerRow(primary);
    if (h.a != c->width || h.b != c->height || h.c != c->stride ||
        (uint32_t)h.d != 0x42475241u) {
        xlog("HELLO geometry mismatch surface=%dx%d/%d wire=%dx%d/%d",
             c->width, c->height, c->stride, h.a, h.b, h.c);
        CFRelease(primary); destroy_reply_port(self, r); free(c); close(fd); return NULL;
    }
    if (add_surface(c, XIOS_PRIMARY_SURFACE_ID, 0,
                    c->width, c->height, c->stride, primary) != 0) {
        CFRelease(primary); destroy_reply_port(self, r); free(c); close(fd); return NULL;
    }
    c->current_surface_id = XIOS_PRIMARY_SURFACE_ID;
    uint32_t idlen = h.length;
    if (idlen && read_full(fd, c->comp_id, idlen) != 0) {
        xsurface_close(c); return NULL;
    }
    c->comp_id[idlen] = '\0';

    if (caps & XIOS_HELLO_CAP_STREAM_V2) {
        xios_msg info;
        memset(&info, 0, sizeof(info));
        if (read_full(fd, &info, sizeof(info)) != 0 ||
            info.magic != XIOS_MSG_MAGIC ||
            info.type != XIOS_MSG_STREAM_INFO ||
            info.window_id != 0 ||
            (info.length != XIOS_GPU_FENCE_TOKEN_SIZE &&
             !(info.a == 1 && info.length == 0)) ||
            info.a < 1 || info.a > 3 ||
            (info.length &&
             read_full(fd, c->release_token, info.length) != 0)) {
            xlog("stream-v2 info missing/malformed");
            xsurface_close(c);
            return NULL;
        }
        c->release_token_size = info.length;

        for (int i = 1; i < info.a; i++) {
            IOSurfaceRef surface = NULL;
            xios_msg surface_msg;
            memset(&surface_msg, 0, sizeof(surface_msg));
            if (receive_surface_port(r, 5000, &surface) != 1 ||
                read_full(fd, &surface_msg, sizeof(surface_msg)) != 0 ||
                surface_msg.magic != XIOS_MSG_MAGIC ||
                surface_msg.type != XIOS_MSG_SURFACE ||
                surface_msg.length != 0 ||
                surface_msg.window_id != XIOS_PRIMARY_SURFACE_ID + (uint32_t)i ||
                surface_msg.a != (int32_t)IOSurfaceGetWidth(surface) ||
                surface_msg.b != (int32_t)IOSurfaceGetHeight(surface) ||
                surface_msg.c != (int32_t)IOSurfaceGetBytesPerRow(surface) ||
                add_surface(c, surface_msg.window_id, (uint32_t)surface_msg.d,
                            surface_msg.a, surface_msg.b, surface_msg.c,
                            surface) != 0) {
                if (surface) CFRelease(surface);
                xlog("stream-v2 output surface %d missing/malformed", i);
                xsurface_close(c);
                return NULL;
            }
        }
        xlog("typed stream-v2 connected (compositor=%s outputs=%d)",
             c->comp_id, info.a);
    } else {
        destroy_reply_port(self, c->reply_port);
        c->reply_port = MACH_PORT_NULL;
        xlog("typed legacy stream connected (compositor=%s)", c->comp_id);
    }

    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK);
    return c;
}

XSurfaceConn *xsurface_connect(const char *sock_path)
{
    XSurfaceConn *c =
        xsurface_connect_caps(sock_path, XIOS_HELLO_CAP_STREAM_V2);
    return c ? c : xsurface_connect_caps(sock_path, 0);
}

IOSurfaceRef xsurface_get(XSurfaceConn *c)
{
    struct xsurface_item *item = find_surface(c, c ? c->current_surface_id : 0);
    return item ? item->surface : NULL;
}
uint32_t xsurface_surface_id(XSurfaceConn *c)
{
    return c ? c->current_surface_id : 0;
}
uint32_t xsurface_surface_flags(XSurfaceConn *c)
{
    struct xsurface_item *item = find_surface(c, c ? c->current_surface_id : 0);
    return item ? item->flags : 0;
}
int xsurface_surface_width(XSurfaceConn *c)
{
    struct xsurface_item *item = find_surface(c, c ? c->current_surface_id : 0);
    return item ? item->width : 0;
}
int xsurface_surface_height(XSurfaceConn *c)
{
    struct xsurface_item *item = find_surface(c, c ? c->current_surface_id : 0);
    return item ? item->height : 0;
}
int xsurface_width(XSurfaceConn *c)  { return c ? c->width : 0; }
int xsurface_height(XSurfaceConn *c) { return c ? c->height : 0; }
int xsurface_stride(XSurfaceConn *c) { return c ? c->stride : 0; }
int xsurface_fd(XSurfaceConn *c)     { return c ? c->fd : -1; }

/* Parse 32-byte records (DIRTY + CURSOR, plus any HELLO/native records whose
 * payload we skip). Records span multiple non-blocking reads, so the partial-
 * header + payload-skip state lives in the conn. A magic mismatch means the
 * stream desynced — return -1 so the caller reconnects. */
int xsurface_drain(XSurfaceConn *c)
{
    if (!c) return -1;
    int dirty = 0;
    for (;;) {
        if (c->has_pending_surface) {
            IOSurfaceRef surface = NULL;
            int rr = receive_surface_port(c->reply_port, 0, &surface);
            if (rr == 0)
                break;
            if (rr < 0)
                return -1;
            xios_msg *m = &c->pending_surface;
            if (m->a != (int32_t)IOSurfaceGetWidth(surface) ||
                m->b != (int32_t)IOSurfaceGetHeight(surface) ||
                m->c != (int32_t)IOSurfaceGetBytesPerRow(surface) ||
                add_surface(c, m->window_id, (uint32_t)m->d,
                            m->a, m->b, m->c, surface) != 0) {
                CFRelease(surface);
                xlog("dynamic SURFACE %u malformed", m->window_id);
                return -1;
            }
            c->has_pending_surface = 0;
            continue;
        }
        if (c->fence_rx_expected > 0) {
            ssize_t r = recv(c->fd,
                             c->fence_token + c->fence_rx_got,
                             c->fence_rx_expected - c->fence_rx_got,
                             MSG_DONTWAIT);
            if (r > 0) {
                c->fence_rx_got += (uint32_t)r;
                if (c->fence_rx_got < c->fence_rx_expected)
                    continue;
                c->fence_token_size = c->fence_rx_expected;
                c->fence_dirty_seq = c->fence_rx_dirty_seq;
                c->fence_value = c->fence_rx_value;
                c->dirty_seq = c->fence_rx_dirty_seq;
                uint32_t previous_surface_id = c->current_surface_id;
                c->current_surface_id = c->fence_rx_surface_id;
                if (previous_surface_id != c->current_surface_id) {
                    struct xsurface_item *previous =
                        find_surface(c, previous_surface_id);
                    if (previous && previous->retired)
                        remove_surface(c, previous_surface_id);
                }
                c->fence_rx_expected = 0;
                c->fence_rx_got = 0;
                /* A swapchain DIRTY is an ownership transfer, not a coalescible
                 * hint: every delivered buffer needs its own release submission.
                 * Stop after one complete frame and leave later records queued for
                 * subsequent display-link ticks. */
                return 1;
            }
            if (r == 0) return -1;
            if (errno == EAGAIN || errno == EWOULDBLOCK) break;
            if (errno == EINTR) continue;
            return -1;
        }
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
            {
                uint64_t seq = ((uint64_t)(uint32_t)m.b << 32) | (uint32_t)m.a;
                uint64_t event_value =
                    ((uint64_t)(uint32_t)m.d << 32) | (uint32_t)m.c;
                if (!find_surface(c, m.window_id) ||
                    m.length != XIOS_GPU_FENCE_TOKEN_SIZE ||
                    event_value == 0) {
                    xlog("invalid broker fence surface=%u length=%u value=%llu",
                         m.window_id, m.length,
                         (unsigned long long)event_value);
                    return -1;
                }
                c->fence_rx_expected = m.length;
                c->fence_rx_got = 0;
                c->fence_rx_surface_id = m.window_id;
                c->fence_rx_dirty_seq = seq;
                c->fence_rx_value = event_value;
                break;
            }
            case XIOS_MSG_SURFACE:
                if (m.window_id < XIOS_DYNAMIC_SURFACE_ID_BASE ||
                    m.length != 0 || m.a <= 0 || m.b <= 0 || m.c <= 0 ||
                    ((uint32_t)m.d & ~XIOS_SURFACE_FLAG_FLIP_Y) != 0 ||
                    find_surface(c, m.window_id)) {
                    xlog("invalid dynamic SURFACE id=%u", m.window_id);
                    return -1;
                }
                c->pending_surface = m;
                c->has_pending_surface = 1;
                break;
            case XIOS_MSG_SURFACE_DROP:
            {
                if (m.length != 0) return -1;
                struct xsurface_item *item = find_surface(c, m.window_id);
                if (!item || m.window_id < XIOS_DYNAMIC_SURFACE_ID_BASE)
                    return -1;
                /* Keep the currently displayed allocation until a later DIRTY
                 * switches away; Metal may still retain it for the last drawable. */
                if (m.window_id == c->current_surface_id) {
                    item->retired = 1;
                } else {
                    remove_surface(c, m.window_id);
                }
                break;
            }
            case XIOS_MSG_CURSOR:
                c->cur_x = m.a; c->cur_y = m.b;
                c->cur_shape = m.c; c->cur_vis = (m.d & 1);
                c->cur_seq++;
                break;
            case XIOS_MSG_HELLO:
                xlog("duplicate HELLO; reconnect");
                return -1;
            default:
                xlog("typed unknown record type=0x%x; reconnect", m.type);
                return -1;
            }
            if (m.length > 0 && m.type != XIOS_MSG_DIRTY)
                c->skip = (int) m.length;
            continue;
        }
        if (r == 0) return -1;
        if (errno == EAGAIN || errno == EWOULDBLOCK) break;
        if (errno == EINTR) continue;
        return -1;
    }
    return dirty;
}

uint64_t xsurface_dirty_sequence(XSurfaceConn *c)
{
    return c ? c->dirty_seq : 0;
}

int xsurface_gpu_fence_token(XSurfaceConn *c, const void **token,
                             size_t *token_size, uint64_t *value)
{
    if (token) *token = NULL;
    if (token_size) *token_size = 0;
    if (value) *value = 0;
    if (!c || c->fence_token_size != XIOS_GPU_FENCE_TOKEN_SIZE ||
        c->fence_value == 0 ||
        c->fence_dirty_seq != c->dirty_seq)
        return 0;
    if (token) *token = c->fence_token;
    if (token_size) *token_size = c->fence_token_size;
    if (value) *value = c->fence_value;
    return 1;
}

int xsurface_release_fence_token(XSurfaceConn *c, const void **token,
                                 size_t *token_size)
{
    if (token) *token = NULL;
    if (token_size) *token_size = 0;
    if (!c || c->release_token_size != XIOS_GPU_FENCE_TOKEN_SIZE)
        return 0;
    if (token) *token = c->release_token;
    if (token_size) *token_size = c->release_token_size;
    return 1;
}

/* One non-blocking 32-byte record on the app socket. MSG_DONTWAIT keeps the
 * never-stall posture of this stream: a backed-up compositor drops our ack rather
 * than parking the app's main thread mid-tick. */
static int send_msg(XSurfaceConn *c, const xios_msg *m)
{
    ssize_t r;
    do {
        r = send(c->fd, m, sizeof(*m), MSG_DONTWAIT);
    } while (r < 0 && errno == EINTR);
    return r == (ssize_t)sizeof(*m) ? 0 : -1;
}

static int presented_common(XSurfaceConn *c, uint64_t seq,
                            uint32_t present_age_us, int have_age)
{
    if (!c || c->fd < 0 || seq == 0) return -1;
    xios_msg m;
    memset(&m, 0, sizeof(m));
    m.magic = XIOS_MSG_MAGIC;
    m.type = XIOS_MSG_PRESENTED;
    m.a = (int32_t)(uint32_t)(seq & 0xffffffffu);
    m.b = (int32_t)(uint32_t)(seq >> 32);
    if (have_age) {
        /* c is int32; an age past ~35 minutes is nonsense anyway, and clamping
         * keeps the compositor from reading a negative as a future present. */
        m.c = present_age_us > (uint32_t)INT32_MAX
            ? INT32_MAX : (int32_t)present_age_us;
        m.d = 1;                 /* bit0: c carries a measured presentedTime */
    }
    return send_msg(c, &m);
}

int xsurface_presented(XSurfaceConn *c, uint64_t seq)
{
    return presented_common(c, seq, 0, 0);
}

int xsurface_presented_at(XSurfaceConn *c, uint64_t seq, uint32_t present_age_us)
{
    return presented_common(c, seq, present_age_us, 1);
}

int xsurface_pacing(XSurfaceConn *c, int32_t until_deadline_us,
                    uint32_t interval_us, int32_t min_mfps, int32_t max_mfps)
{
    if (!c || c->fd < 0 || interval_us == 0) return -1;
    xios_msg m;
    memset(&m, 0, sizeof(m));
    m.magic = XIOS_MSG_MAGIC;
    m.type = XIOS_MSG_PACING;
    m.a = until_deadline_us;
    m.b = interval_us > (uint32_t)INT32_MAX ? INT32_MAX : (int32_t)interval_us;
    m.c = min_mfps;
    m.d = max_mfps;
    return send_msg(c, &m);
}

int xsurface_released(XSurfaceConn *c, uint32_t surface_id, uint64_t seq)
{
    if (!c || c->fd < 0 || surface_id == 0 || seq == 0)
        return -1;
    xios_msg m;
    memset(&m, 0, sizeof(m));
    m.magic = XIOS_MSG_MAGIC;
    m.type = XIOS_MSG_RELEASED;
    m.window_id = surface_id;
    m.a = (int32_t)(uint32_t)(seq & 0xffffffffu);
    m.b = (int32_t)(uint32_t)(seq >> 32);
    return send_msg(c, &m);
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
    for (int i = 0; i < c->surface_count; i++)
        if (c->surfaces[i].surface)
            CFRelease(c->surfaces[i].surface);
    destroy_reply_port(mach_task_self(), c->reply_port);
    if (c->fd >= 0) close(c->fd);
    free(c);
}

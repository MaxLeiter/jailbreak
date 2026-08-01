/*
 * xios_surface.c — IOSurface-backed compositor output + app rendezvous.
 *
 * Deliberately includes NO X server headers — only Apple frameworks + POSIX — so
 * CoreFoundation/IOSurface/mach declarations can't collide with dix macros.
 */
#include "xios_surface.h"
#include "xios_output_queue.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <limits.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <poll.h>
#include <pwd.h>
#include <time.h>
#include <mach/mach.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOSurface/IOSurfaceRef.h>

/* Cosmetic display-number string written into xios.json. Compositors provide it
 * without coupling this Apple-only translation unit to compositor headers. */
extern char *display;

/* ---- wire protocol (native LE; server + app are both arm64) ---------------- */

#define XIOS_FMT_BGRA   0x42475241u   /* 'BGRA' */

/* mach message carrying the IOSurface send right */
typedef struct {
    mach_msg_header_t header;
    mach_msg_body_t body;
    mach_msg_port_descriptor_t port;
} xios_port_msg;

/* ---- state ---------------------------------------------------------------- */

#define XIOS_MAX_CLIENTS 8
#define XIOS_MAX_OUTPUTS 3
#define XIOS_MAX_STREAM_SURFACES 128

struct app_client {
    int fd;
    mach_port_t dst;
    uint32_t caps;
    int active;
    uint64_t serial;
};

static IOSurfaceRef s_surface = NULL;
static int s_width, s_height, s_stride;

struct output_surface {
    IOSurfaceRef surface;
    uint32_t id;
    int stride;
    int alloc_size;
};

struct stream_surface {
    IOSurfaceRef surface;
    uint32_t id;
    uint32_t flags;
    int width, height, stride;
    uint32_t sent_clients;
    uint64_t last_seq;
    uint64_t released_seq;
};

static struct output_surface s_outputs[XIOS_MAX_OUTPUTS];
static unsigned s_output_count_requested = 1;
static unsigned s_output_count;
static struct xios_output_queue s_output_queue;
static unsigned char s_release_token[XIOS_GPU_FENCE_TOKEN_SIZE];
static size_t s_release_token_size;
static struct stream_surface s_stream_surfaces[XIOS_MAX_STREAM_SURFACES];
static uint32_t s_next_stream_surface_id = XIOS_DYNAMIC_SURFACE_ID_BASE;

static int s_listen_fd = -1;
static pthread_t s_thread;
static pthread_mutex_t s_lock = PTHREAD_MUTEX_INITIALIZER;
static struct app_client s_clients[XIOS_MAX_CLIENTS];
static int s_nclients = 0;
static uint64_t s_next_client_serial;
static uint64_t s_dirty_seq = 0;
static uint64_t s_presented_seq = 0;
static char s_compositor_id[32] = "";          /* "iosc"/"mutter-ios"; sent in the typed HELLO */
static char s_input_socket[108] = "";          /* app input socket; emitted in xios.json when set */
static char s_clipboard_socket[108] = "";      /* app clipboard socket; emitted when set */
static char s_upscale_hint[32] = "";           /* present-side upscale spec for the app */
static unsigned s_generation = 0;              /* bumped by resize; stale handshakes close */
static char s_sock_path_kept[256] = "";        /* for resize-time xios.json rewrite */
static char s_json_path_kept[256] = "";

static struct stream_surface *find_stream_surface_locked(uint32_t id);

/* ---- display pacing state (XIOS_MSG_PACING / XIOS_MSG_PRESENTED) ------------
 * Written on the per-client read thread, read from the compositor's event loop,
 * so everything here lives under s_lock like s_presented_seq. Timestamps are
 * translated into OUR CLOCK_MONOTONIC at arrival, because the wire carries deltas
 * relative to send time (see xios_surface.h). */
static uint64_t s_vblank_deadline_ms;   /* absolute: app's next frame deadline */
static uint32_t s_vblank_interval_us;   /* refresh interval */
static int      s_vblank_min_mfps;
static int      s_vblank_max_mfps;
static uint64_t s_vblank_rx_ms;         /* when the last PACING record arrived */
static uint32_t s_present_age_us;       /* real present time, as an age at ack */
static uint64_t s_present_ack_ms;       /* when that ack arrived */
static int      s_present_age_valid;

/* A display clock older than this is treated as dead rather than extrapolated: the
 * app backgrounded, was suspended by FrontBoard, or died. Several refresh intervals
 * so an ordinary scheduling hiccup does not flip the compositor back to event-loop
 * pacing and then forward again. */
#define XIOS_VBLANK_STALE_MS 250

void xios_set_compositor_id(const char *id)
{
    snprintf(s_compositor_id, sizeof(s_compositor_id), "%s", id ? id : "");
}

void xios_set_input_socket(const char *path)
{
    snprintf(s_input_socket, sizeof(s_input_socket), "%s", path ? path : "");
}

void xios_set_clipboard_socket(const char *path)
{
    snprintf(s_clipboard_socket, sizeof(s_clipboard_socket), "%s", path ? path : "");
}

void xios_set_upscale_hint(const char *spec)
{
    snprintf(s_upscale_hint, sizeof(s_upscale_hint), "%s", spec ? spec : "");
    /* Anything that could break the flat JSON we hand-write, or smuggle a second
     * field in, becomes nothing at all. */
    for (char *p = s_upscale_hint; *p; p++) {
        unsigned char c = (unsigned char)*p;
        if (c < 32 || c == '"' || c == '\\' || c == ',' || c == '{' || c == '}') {
            s_upscale_hint[0] = 0;
            break;
        }
    }
}

int xios_set_output_buffer_count(unsigned count)
{
    if (count < 1 || count > XIOS_MAX_OUTPUTS || s_output_count != 0)
        return -1;
    s_output_count_requested = count;
    return 0;
}

int xios_set_release_fence_token(const void *token, size_t token_size)
{
    if (!token || token_size != XIOS_GPU_FENCE_TOKEN_SIZE || s_listen_fd >= 0)
        return -1;
    memcpy(s_release_token, token, token_size);
    s_release_token_size = token_size;
    return 0;
}

static uint32_t stream_v2_client_mask_locked(void)
{
    uint32_t mask = 0;
    for (int i = 0; i < XIOS_MAX_CLIENTS; i++)
        if (s_clients[i].active &&
            (s_clients[i].caps & XIOS_HELLO_CAP_STREAM_V2))
            mask |= 1u << i;
    return mask;
}

/* ---- helpers -------------------------------------------------------------- */

/* Same clock iosc's now_ms() reads, in 64-bit ms so the pacing deadline maths
 * cannot straddle the 32-bit wrap iosc tolerates for Wayland event timestamps. */
static uint64_t mono_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000 + (uint64_t)ts.tv_nsec / 1000000;
}

static void set_cloexec(int fd)
{
    int f = fcntl(fd, F_GETFD, 0);
    if (f >= 0) fcntl(fd, F_SETFD, f | FD_CLOEXEC);
}

static void set_nosigpipe(int fd)
{
    int on = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));
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

static int setnum(CFMutableDictionaryRef d, CFStringRef k, int32_t v)
{
    CFNumberRef n = CFNumberCreate(NULL, kCFNumberSInt32Type, &v);
    if (!n)
        return -1;
    CFDictionarySetValue(d, k, n);
    CFRelease(n);
    return 0;
}

static void write_json(const char *json_path, int width, int height, int stride,
                       const char *sock_path)
{
    FILE *jf = fopen(json_path, "w");
    if (!jf)
        return;
    fprintf(jf,
            "{\"width\":%d,\"height\":%d,\"stride\":%d,"
            "\"format\":\"BGRA\",\"ddx\":\"iosurface\",\"socket\":\"%s\","
            "\"display\":\":%s\",\"protocol_version\":%u",
            width, height, stride, sock_path, display ? display : "0",
            XIOS_PROTOCOL_VERSION);
    /* Where the app should send keyboard/pointer. The app auto-infers this only
     * for an "iosc"-named ddx socket; any other compositor (mutter) must set it
     * or it gets no input. Omitted when unset so iosc keeps the app's inference. */
    if (s_input_socket[0])
        fprintf(jf, ",\"input_socket\":\"%s\"", s_input_socket);
    if (s_clipboard_socket[0])
        fprintf(jf, ",\"clipboard_socket\":\"%s\"", s_clipboard_socket);
    /* Present-side only; the app upscales its own drawable and nothing here or in
     * any Wayland client's view of the output changes. Omitted when unset so the
     * app keeps its default (off). */
    if (s_upscale_hint[0])
        fprintf(jf, ",\"upscale\":\"%s\"", s_upscale_hint);
    fprintf(jf, "}\n");
    fclose(jf);
    /* The app runs as mobile; make the handshake file world-readable so it can
     * read it regardless of the compositor's launch umask. */
    chmod(json_path, 0644);
}

/* ---- IOSurface ------------------------------------------------------------ */

static IOSurfaceRef make_surface(int width, int height, int *stride, int *alloc_size)
{
    const int bpe = 4;   /* BGRA8 */
    if (width <= 0 || height <= 0 || width > INT_MAX / bpe) {
        fprintf(stderr, "xios: invalid IOSurface geometry %dx%d\n", width, height);
        return NULL;
    }

    size_t bpr = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow,
                                        (size_t) width * (size_t) bpe);
    size_t alloc = IOSurfaceAlignProperty(kIOSurfaceAllocSize, bpr * (size_t) height);
    if (bpr > INT32_MAX || alloc > INT32_MAX) {
        fprintf(stderr, "xios: IOSurface geometry too large %dx%d stride=%zu alloc=%zu\n",
                width, height, bpr, alloc);
        return NULL;
    }

    CFMutableDictionaryRef d = CFDictionaryCreateMutable(
        NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    if (!d) return NULL;
    if (setnum(d, kIOSurfaceWidth, width) != 0 ||
        setnum(d, kIOSurfaceHeight, height) != 0 ||
        setnum(d, kIOSurfaceBytesPerElement, bpe) != 0 ||
        setnum(d, kIOSurfaceBytesPerRow, (int32_t) bpr) != 0 ||
        setnum(d, kIOSurfaceAllocSize, (int32_t) alloc) != 0 ||
        setnum(d, kIOSurfacePixelFormat, (int32_t) XIOS_FMT_BGRA) != 0) {
        CFRelease(d);
        return NULL;
    }

    IOSurfaceRef s = IOSurfaceCreate(d);
    CFRelease(d);
    if (!s) {
        fprintf(stderr, "xios: IOSurfaceCreate failed (%dx%d) — check the "
                        "iokit-user-client-class entitlement\n", width, height);
        return NULL;
    }

    int alloc_sz = (int) IOSurfaceGetAllocSize(s);

    /* Zero the buffer so the first frame isn't garbage. */
    if (IOSurfaceLock(s, 0, NULL) != KERN_SUCCESS) {
        fprintf(stderr, "xios: IOSurfaceLock failed during init\n");
        CFRelease(s);
        return NULL;
    }
    void *base = IOSurfaceGetBaseAddress(s);
    if (!base) {
        fprintf(stderr, "xios: IOSurfaceGetBaseAddress returned NULL\n");
        IOSurfaceUnlock(s, 0, NULL);
        CFRelease(s);
        return NULL;
    }
    memset(base, 0, (size_t) alloc_sz);
    IOSurfaceUnlock(s, 0, NULL);

    if (stride) *stride = (int) IOSurfaceGetBytesPerRow(s);
    if (alloc_size) *alloc_size = alloc_sz;
    fprintf(stderr, "xios: IOSurface %dx%d id=%u stride=%d alloc=%d base=%p\n",
            width, height, (unsigned) IOSurfaceGetID(s),
            (int) IOSurfaceGetBytesPerRow(s), alloc_sz, base);
    return s;
}

void *xios_surface_create(int width, int height, int *stride, int *alloc_size)
{
    struct output_surface made[XIOS_MAX_OUTPUTS];
    memset(made, 0, sizeof(made));
    unsigned count = s_output_count_requested;
    for (unsigned i = 0; i < count; i++) {
        int st = 0, alloc_sz = 0;
        made[i].surface = make_surface(width, height, &st, &alloc_sz);
        if (!made[i].surface) {
            for (unsigned j = 0; j < i; j++)
                CFRelease(made[j].surface);
            return NULL;
        }
        made[i].id = XIOS_PRIMARY_SURFACE_ID + i;
        made[i].stride = st;
        made[i].alloc_size = alloc_sz;
    }

    memcpy(s_outputs, made, sizeof(made));
    s_output_count = count;
    xios_output_queue_reset(&s_output_queue, count);
    s_surface = s_outputs[0].surface;
    s_width = width;
    s_height = height;
    s_stride = s_outputs[0].stride;
    if (stride) *stride = s_stride;
    if (alloc_size) *alloc_size = s_outputs[0].alloc_size;
    void *base = IOSurfaceGetBaseAddress(s_surface);
    fprintf(stderr, "xios: output stream allocated %u buffer%s\n",
            count, count == 1 ? "" : "s");
    return base;
}

void *xios_surface_resize(int width, int height, int *stride, int *alloc_size)
{
    struct output_surface made[XIOS_MAX_OUTPUTS];
    struct output_surface old[XIOS_MAX_OUTPUTS];
    memset(made, 0, sizeof(made));
    memset(old, 0, sizeof(old));
    unsigned count = s_output_count ? s_output_count : s_output_count_requested;
    for (unsigned i = 0; i < count; i++) {
        int st = 0, alloc_sz = 0;
        made[i].surface = make_surface(width, height, &st, &alloc_sz);
        if (!made[i].surface) {
            for (unsigned j = 0; j < i; j++)
                CFRelease(made[j].surface);
            return NULL;
        }
        made[i].id = XIOS_PRIMARY_SURFACE_ID + i;
        made[i].stride = st;
        made[i].alloc_size = alloc_sz;
    }
    void *base = IOSurfaceGetBaseAddress(made[0].surface);

    pthread_mutex_lock(&s_lock);
    memcpy(old, s_outputs, sizeof(old));
    memcpy(s_outputs, made, sizeof(made));
    s_output_count = count;
    xios_output_queue_reset(&s_output_queue, count);
    s_surface = s_outputs[0].surface;
    s_width = width;
    s_height = height;
    s_stride = s_outputs[0].stride;
    s_generation++;
    for (int i = 0; i < XIOS_MAX_CLIENTS; i++) {
        if (!s_clients[i].active)
            continue;
        shutdown(s_clients[i].fd, SHUT_RDWR);
        close(s_clients[i].fd);
        if (s_clients[i].dst != MACH_PORT_NULL)
            mach_port_deallocate(mach_task_self(), s_clients[i].dst);
        memset(&s_clients[i], 0, sizeof(s_clients[i]));
        s_clients[i].fd = -1;
    }
    s_nclients = 0;
    pthread_mutex_unlock(&s_lock);

    for (unsigned i = 0; i < count; i++)
        if (old[i].surface)
            CFRelease(old[i].surface);
    if (s_json_path_kept[0] && s_sock_path_kept[0])
        write_json(s_json_path_kept, width, height, s_stride, s_sock_path_kept);
    if (stride) *stride = s_stride;
    if (alloc_size) *alloc_size = s_outputs[0].alloc_size;
    fprintf(stderr,
            "xios: %u-buffer output resized to %dx%d stride=%d (clients dropped)\n",
            count, width, height, s_stride);
    return base;
}

/* ---- mach-port hand-off --------------------------------------------------- */

/* Resolve the app's receive-port name once. The retained send right stays with
 * the client so later swapchain/direct surfaces can be delivered without another
 * task_for_pid round-trip on the compositor hot path. */
static mach_port_t extract_reply_port(int pid, unsigned portname)
{
    task_t task = MACH_PORT_NULL;
    kern_return_t kr = task_for_pid(mach_task_self(), pid, &task);
    if (kr) {
        fprintf(stderr, "xios: task_for_pid(%d) failed: 0x%x (%s) — needs "
                        "task_for_pid-allow on Xios + get-task-allow on the app\n",
                pid, kr, mach_error_string(kr));
        return MACH_PORT_NULL;
    }

    mach_port_t dst = MACH_PORT_NULL;
    mach_msg_type_name_t acq;
    kr = mach_port_extract_right(task, (mach_port_name_t) portname,
                                 MACH_MSG_TYPE_COPY_SEND, &dst, &acq);
    /* done with the task port either way */
    mach_port_deallocate(mach_task_self(), task);
    if (kr) {
        fprintf(stderr, "xios: mach_port_extract_right failed: 0x%x (%s)\n",
                kr, mach_error_string(kr));
        return MACH_PORT_NULL;
    }
    return dst;
}

/* Send one IOSurface port to an already-resolved app receive port. */
static int deliver_surface_port(mach_port_t dst, IOSurfaceRef surf,
                                mach_msg_timeout_t timeout_ms)
{
    if (!surf || dst == MACH_PORT_NULL) {
        fprintf(stderr, "xios: no IOSurface/destination available for hand-off\n");
        return -1;
    }

    mach_port_t sp = IOSurfaceCreateMachPort(surf);
    if (sp == MACH_PORT_NULL) {
        fprintf(stderr, "xios: IOSurfaceCreateMachPort failed\n");
        return -1;
    }

    xios_port_msg msg;
    memset(&msg, 0, sizeof(msg));
    msg.header.msgh_bits =
        MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0) | MACH_MSGH_BITS_COMPLEX;
    msg.header.msgh_size = sizeof(msg);
    msg.header.msgh_remote_port = dst;
    msg.header.msgh_local_port = MACH_PORT_NULL;
    msg.body.msgh_descriptor_count = 1;
    msg.port.name = sp;
    msg.port.disposition = MACH_MSG_TYPE_COPY_SEND;
    msg.port.type = MACH_MSG_PORT_DESCRIPTOR;

    /* MACH_SEND_TIMEOUT must be in the option mask or the timeout arg is ignored;
     * a suspended/unresponsive app could otherwise block the accept thread forever
     * (and with it every future client). */
    kern_return_t kr = mach_msg(&msg.header,
                                MACH_SEND_MSG | MACH_SEND_TIMEOUT,
                                sizeof(msg), 0, MACH_PORT_NULL,
                                timeout_ms, MACH_PORT_NULL);

    /* Drop the per-surface send right. `dst` is retained by app_client. */
    mach_port_deallocate(mach_task_self(), sp);

    if (kr) {
        fprintf(stderr, "xios: mach_msg(send IOSurface port) failed: 0x%x (%s)\n",
                kr, mach_error_string(kr));
        return -1;
    }
    return 0;
}

static void clear_client_pending_locked(int slot)
{
    uint32_t bit = 1u << slot;
    xios_output_queue_drop_client(&s_output_queue, bit);
    for (int i = 0; i < XIOS_MAX_STREAM_SURFACES; i++)
        s_stream_surfaces[i].sent_clients &= ~bit;
}

/* A socket close is not proof that the app's Metal queue has stopped sampling.
 * Output slots therefore stay quarantined on drop. The next completed app
 * handshake is the recovery boundary: Xios tears down the old connection and
 * texture before reconnecting, while a killed process has already lost access.
 * Direct-present buffers use the same boundary via released_seq. */
static void recover_consumer_after_handshake_locked(void)
{
    xios_output_queue_recover_abandoned(&s_output_queue);
    for (int i = 0; i < XIOS_MAX_STREAM_SURFACES; i++) {
        struct stream_surface *stream = &s_stream_surfaces[i];
        if (stream->surface && stream->sent_clients == 0 &&
            stream->released_seq < stream->last_seq)
            stream->released_seq = stream->last_seq;
    }
}

static int add_client(int fd, mach_port_t dst, uint32_t caps,
                      unsigned generation, uint64_t *serial_out)
{
    int slot = -1;
    pthread_mutex_lock(&s_lock);
    if (generation != s_generation) {
        close(fd);
        mach_port_deallocate(mach_task_self(), dst);
        fprintf(stderr, "xios: stale app client fd=%d rejected after resize\n", fd);
    } else {
        uint32_t v2 = stream_v2_client_mask_locked();
        if (((caps & XIOS_HELLO_CAP_STREAM_V2) && s_nclients != 0) ||
            (!(caps & XIOS_HELLO_CAP_STREAM_V2) && v2 != 0)) {
            close(fd);
            mach_port_deallocate(mach_task_self(), dst);
            fprintf(stderr,
                    "xios: stream-v2 presentation is single-consumer; rejecting fd=%d\n",
                    fd);
        } else {
            for (int i = 0; i < XIOS_MAX_CLIENTS; i++)
                if (!s_clients[i].active) {
                    slot = i;
                    break;
                }
            if (slot >= 0) {
                if (s_nclients == 0)
                    recover_consumer_after_handshake_locked();
                s_clients[slot].fd = fd;
                s_clients[slot].dst = dst;
                s_clients[slot].caps = caps;
                s_clients[slot].active = 1;
                s_clients[slot].serial = ++s_next_client_serial;
                if (s_clients[slot].serial == 0)
                    s_clients[slot].serial = ++s_next_client_serial;
                if (serial_out)
                    *serial_out = s_clients[slot].serial;
                s_nclients++;
                fprintf(stderr,
                        "xios: app client attached (typed fd=%d slot=%d caps=0x%x total=%d)\n",
                        fd, slot, caps, s_nclients);
            } else {
                close(fd);
                mach_port_deallocate(mach_task_self(), dst);
                fprintf(stderr, "xios: too many clients, rejecting fd=%d\n", fd);
            }
        }
    }
    pthread_mutex_unlock(&s_lock);
    return slot;
}

static void drop_client_identity_locked(int slot, int fd, uint64_t serial)
{
    if (slot < 0 || slot >= XIOS_MAX_CLIENTS ||
        !s_clients[slot].active ||
        s_clients[slot].fd != fd ||
        s_clients[slot].serial != serial)
        return;
    fprintf(stderr, "xios: client fd=%d dropped\n", fd);
    shutdown(s_clients[slot].fd, SHUT_RDWR);
    close(s_clients[slot].fd);
    if (s_clients[slot].dst != MACH_PORT_NULL)
        mach_port_deallocate(mach_task_self(), s_clients[slot].dst);
    clear_client_pending_locked(slot);
    memset(&s_clients[slot], 0, sizeof(s_clients[slot]));
    s_clients[slot].fd = -1;
    s_nclients--;
    if (s_nclients == 0) {
        /* No app left to pace against. Drop the display clock now rather than
         * letting it go stale on its own: the compositor must fall back to
         * event-loop pacing immediately, not one stale-timeout later. */
        s_vblank_interval_us = 0;
        s_vblank_rx_ms = 0;
        s_vblank_deadline_ms = 0;
        s_present_age_valid = 0;
    }
}

/* XIOS_MSG_PACING: the app's display clock. `a` is microseconds from ITS send time
 * to the deadline, so we add it to OUR now and store an absolute local deadline —
 * the two processes never have to agree on a clock. */
static void handle_pacing_msg(const xios_msg *m)
{
    uint64_t now = mono_ms();
    uint32_t interval_us = (uint32_t)(m->b > 0 ? m->b : 0);
    /* A wild interval means a garbled or hostile record; ignore it rather than
     * pacing the whole compositor off it. 4 Hz..1 kHz covers every plausible panel
     * plus the low end CoreAnimation can throttle a link to. */
    if (interval_us < 1000 || interval_us > 250000)
        return;

    /* Round the sub-ms delta up: landing a hair after the deadline is a dropped
     * frame, landing a hair before it is free. */
    int64_t until_us = (int64_t)m->a;
    int64_t until_ms = (until_us + 999) / 1000;

    pthread_mutex_lock(&s_lock);
    s_vblank_interval_us = interval_us;
    s_vblank_deadline_ms = (until_ms > 0) ? now + (uint64_t)until_ms : now;
    s_vblank_min_mfps = m->c > 0 ? m->c : 0;
    s_vblank_max_mfps = m->d > 0 ? m->d : 0;
    s_vblank_rx_ms = now;
    pthread_mutex_unlock(&s_lock);
}

static void handle_client_msg(int slot, uint64_t serial, const xios_msg *m)
{
    pthread_mutex_lock(&s_lock);
    int live = slot >= 0 && slot < XIOS_MAX_CLIENTS &&
               s_clients[slot].active &&
               s_clients[slot].serial == serial;
    pthread_mutex_unlock(&s_lock);
    if (!live)
        return;
    if (m->type == XIOS_MSG_PACING) {
        handle_pacing_msg(m);
        return;
    }
    if (m->type == XIOS_MSG_RELEASED) {
        uint64_t seq = ((uint64_t)(uint32_t)m->b << 32) | (uint32_t)m->a;
        if (seq == 0 || m->length != 0)
            return;
        pthread_mutex_lock(&s_lock);
        if (slot >= 0 && slot < XIOS_MAX_CLIENTS &&
            s_clients[slot].active &&
            s_clients[slot].serial == serial) {
            uint32_t bit = 1u << slot;
            int handled = 0;
            for (unsigned i = 0; i < s_output_count; i++) {
                if (s_outputs[i].id != m->window_id)
                    continue;
                handled = xios_output_queue_release(
                    &s_output_queue, i, bit, seq);
                break;
            }
            if (!handled) {
                struct stream_surface *stream =
                    find_stream_surface_locked(m->window_id);
                if (stream && (stream->sent_clients & bit) &&
                    stream->last_seq == seq &&
                    seq > stream->released_seq)
                    stream->released_seq = seq;
            }
        }
        pthread_mutex_unlock(&s_lock);
        return;
    }
    if (m->type != XIOS_MSG_PRESENTED)
        return;
    uint64_t seq = ((uint64_t)(uint32_t)m->b << 32) | (uint32_t)m->a;
    uint64_t now = mono_ms();
    pthread_mutex_lock(&s_lock);
    if (seq > s_presented_seq)
        s_presented_seq = seq;
    /* bit0 of d distinguishes "the app measured a real presentedTime" from an app
     * built before pacing, which sends c=d=0 and must keep the old behaviour. */
    if ((m->d & 1) && m->c >= 0) {
        s_present_age_us = (uint32_t)m->c;
        s_present_ack_ms = now;
        s_present_age_valid = 1;
    }
    pthread_mutex_unlock(&s_lock);
}

int xios_display_clock(uint64_t *next_deadline_ms, uint32_t *interval_us,
                       int *min_mfps, int *max_mfps)
{
    uint64_t now = mono_ms();
    int live;

    pthread_mutex_lock(&s_lock);
    live = s_vblank_interval_us > 0 && s_vblank_rx_ms > 0 &&
           now - s_vblank_rx_ms <= XIOS_VBLANK_STALE_MS;
    if (live) {
        /* Walk the stored deadline forward in whole intervals until it is in the
         * future, so a caller that asks between ticks still gets the NEXT vblank
         * instead of one that has already passed. */
        uint64_t deadline = s_vblank_deadline_ms;
        uint64_t interval_ms = (s_vblank_interval_us + 999) / 1000;
        if (interval_ms == 0) interval_ms = 1;
        if (deadline <= now) {
            uint64_t behind = now - deadline;
            deadline += ((behind / interval_ms) + 1) * interval_ms;
        }
        if (next_deadline_ms) *next_deadline_ms = deadline;
        if (interval_us) *interval_us = s_vblank_interval_us;
        if (min_mfps) *min_mfps = s_vblank_min_mfps;
        if (max_mfps) *max_mfps = s_vblank_max_mfps;
    }
    pthread_mutex_unlock(&s_lock);
    return live;
}

int xios_last_present_time(uint32_t *age_us, uint64_t *ack_at_ms)
{
    int have;
    pthread_mutex_lock(&s_lock);
    have = s_present_age_valid;
    if (have) {
        if (age_us) *age_us = s_present_age_us;
        if (ack_at_ms) *ack_at_ms = s_present_ack_ms;
    }
    pthread_mutex_unlock(&s_lock);
    return have;
}

struct client_reader_arg {
    int read_fd;
    int client_fd;
    int slot;
    uint64_t serial;
};

static void *client_read_loop(void *arg)
{
    struct client_reader_arg reader = *(struct client_reader_arg *)arg;
    free(arg);
    int fd = reader.read_fd;

    unsigned char rxbuf[sizeof(xios_msg)];
    int rxlen = 0;
    int skip = 0;
    for (;;) {
        struct pollfd pfd = { fd, POLLIN | POLLHUP | POLLERR, 0 };
        int pr;
        do {
            pr = poll(&pfd, 1, -1);
        } while (pr < 0 && errno == EINTR);
        if (pr <= 0 || (pfd.revents & (POLLHUP | POLLERR | POLLNVAL)))
            break;

        for (;;) {
            if (skip > 0) {
                unsigned char scratch[128];
                int want = skip < (int)sizeof(scratch) ? skip : (int)sizeof(scratch);
                ssize_t r = recv(fd, scratch, want, MSG_DONTWAIT);
                if (r > 0) { skip -= (int)r; continue; }
                if (r == 0) goto out;
                if (errno == EAGAIN || errno == EWOULDBLOCK) break;
                if (errno == EINTR) continue;
                goto out;
            }
            ssize_t r = recv(fd, rxbuf + rxlen, (int)sizeof(xios_msg) - rxlen,
                             MSG_DONTWAIT);
            if (r > 0) {
                rxlen += (int)r;
                if (rxlen < (int)sizeof(xios_msg))
                    continue;
                xios_msg m;
                memcpy(&m, rxbuf, sizeof(m));
                rxlen = 0;
                if (m.magic != XIOS_MSG_MAGIC)
                    goto out;
                handle_client_msg(reader.slot, reader.serial, &m);
                if (m.length > 0)
                    skip = (int)m.length;
                continue;
            }
            if (r == 0) goto out;
            if (errno == EAGAIN || errno == EWOULDBLOCK) break;
            if (errno == EINTR) continue;
            goto out;
        }
    }
out:
    close(reader.read_fd);
    pthread_mutex_lock(&s_lock);
    drop_client_identity_locked(reader.slot, reader.client_fd, reader.serial);
    pthread_mutex_unlock(&s_lock);
    return NULL;
}

static void handle_client(int fd)
{
    set_cloexec(fd);
    set_nosigpipe(fd);

    /* bound the handshake so a stuck client can't hang the accept thread */
    struct timeval tv = { 3, 0 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

    xios_msg hello;
    if (read_full(fd, &hello, sizeof(hello)) != 0 ||
        hello.magic != XIOS_MSG_MAGIC ||
        hello.type != XIOS_MSG_HELLO ||
        hello.window_id != XIOS_PROTOCOL_VERSION ||
        hello.length != 0 ||
        hello.a <= 0 ||
        (uint32_t)hello.b == MACH_PORT_NULL ||
        ((uint32_t)hello.c & ~XIOS_HELLO_CAP_STREAM_V2) != 0 ||
        hello.d != 0) {
        fprintf(stderr, "xios: bad handshake from fd=%d\n", fd);
        close(fd);
        return;
    }

    /* Never trust or fall back to the client-supplied pid for task_for_pid. */
    pid_t peer_pid = 0;
    socklen_t plen = sizeof(peer_pid);
    if (getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &peer_pid, &plen) != 0 || peer_pid <= 0) {
        fprintf(stderr, "xios: cannot identify socket peer on fd=%d\n", fd);
        close(fd);
        return;
    } else if ((uint32_t) peer_pid != (uint32_t)hello.a) {
        fprintf(stderr, "xios: client claimed pid %u but socket peer is %d; "
                        "using the real peer\n", (uint32_t)hello.a, (int) peer_pid);
    }

    uint32_t caps = (uint32_t)hello.c;
    if ((caps & XIOS_HELLO_CAP_STREAM_V2) &&
        (s_output_count < 1 ||
         (s_output_count > 1 &&
          s_release_token_size != XIOS_GPU_FENCE_TOKEN_SIZE))) {
        fprintf(stderr,
                "xios: stream-v2 requested before swapchain/release timeline is ready\n");
        close(fd);
        return;
    }

    IOSurfaceRef outputs[XIOS_MAX_OUTPUTS] = { NULL };
    unsigned output_count = 0;
    pthread_mutex_lock(&s_lock);
    output_count = s_output_count;
    for (unsigned i = 0; i < output_count; i++)
        outputs[i] = s_outputs[i].surface
            ? (IOSurfaceRef)CFRetain(s_outputs[i].surface) : NULL;
    int w = s_width, hgt = s_height, st = s_stride;
    unsigned gen = s_generation;
    pthread_mutex_unlock(&s_lock);

    mach_port_t dst = extract_reply_port((int)peer_pid, (uint32_t)hello.b);
    if (dst == MACH_PORT_NULL ||
        deliver_surface_port(dst, outputs[0], 2000) != 0) {
        if (dst != MACH_PORT_NULL)
            mach_port_deallocate(mach_task_self(), dst);
        for (unsigned i = 0; i < output_count; i++)
            if (outputs[i]) CFRelease(outputs[i]);
        close(fd);
        return;
    }
    /* Reply with the same canonical exact-version HELLO before frames begin. */
    uint32_t idlen = (uint32_t) strlen(s_compositor_id);
    xios_msg h = { XIOS_MSG_MAGIC, XIOS_MSG_HELLO,
                   XIOS_PROTOCOL_VERSION, idlen,
                   w, hgt, st, (int32_t) XIOS_FMT_BGRA };
    if (write_full(fd, &h, sizeof(h)) != 0 ||
        (idlen && write_full(fd, s_compositor_id, idlen) != 0)) {
        mach_port_deallocate(mach_task_self(), dst);
        for (unsigned i = 0; i < output_count; i++)
            if (outputs[i]) CFRelease(outputs[i]);
        close(fd);
        return;
    }

    if (caps & XIOS_HELLO_CAP_STREAM_V2) {
        uint32_t release_length =
            s_release_token_size == XIOS_GPU_FENCE_TOKEN_SIZE
                ? XIOS_GPU_FENCE_TOKEN_SIZE : 0;
        xios_msg info = {
            XIOS_MSG_MAGIC, XIOS_MSG_STREAM_INFO, 0, release_length,
            (int32_t)output_count, 0, 0, 0
        };
        if (write_full(fd, &info, sizeof(info)) != 0 ||
            (release_length &&
             write_full(fd, s_release_token, release_length) != 0)) {
            mach_port_deallocate(mach_task_self(), dst);
            for (unsigned i = 0; i < output_count; i++)
                if (outputs[i]) CFRelease(outputs[i]);
            close(fd);
            return;
        }
        for (unsigned i = 1; i < output_count; i++) {
            xios_msg surface_msg = {
                XIOS_MSG_MAGIC, XIOS_MSG_SURFACE,
                XIOS_PRIMARY_SURFACE_ID + i, 0,
                w, hgt, s_outputs[i].stride, 0
            };
            if (deliver_surface_port(dst, outputs[i], 2000) != 0 ||
                write_full(fd, &surface_msg, sizeof(surface_msg)) != 0) {
                mach_port_deallocate(mach_task_self(), dst);
                for (unsigned j = 0; j < output_count; j++)
                    if (outputs[j]) CFRelease(outputs[j]);
                close(fd);
                return;
            }
        }
    }
    for (unsigned i = 0; i < output_count; i++)
        if (outputs[i]) CFRelease(outputs[i]);
    /* Damage notifications are non-blocking: a suspended/backed-up app must never
     * stall the X server's block handler. */
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK);
    uint64_t client_serial = 0;
    int client_slot = add_client(fd, dst, caps, gen, &client_serial);
    if (client_slot < 0)
        return;
    int read_fd = dup(fd);
    if (read_fd < 0) {
        pthread_mutex_lock(&s_lock);
        drop_client_identity_locked(client_slot, fd, client_serial);
        pthread_mutex_unlock(&s_lock);
        return;
    }
    set_cloexec(read_fd);
    struct client_reader_arg *reader_arg = malloc(sizeof(*reader_arg));
    if (reader_arg) {
        *reader_arg = (struct client_reader_arg) {
            read_fd, fd, client_slot, client_serial
        };
        pthread_t reader;
        if (pthread_create(&reader, NULL, client_read_loop, reader_arg) == 0)
            pthread_detach(reader);
        else {
            free(reader_arg);
            close(read_fd);
            pthread_mutex_lock(&s_lock);
            drop_client_identity_locked(client_slot, fd, client_serial);
            pthread_mutex_unlock(&s_lock);
        }
    } else {
        close(read_fd);
        pthread_mutex_lock(&s_lock);
        drop_client_identity_locked(client_slot, fd, client_serial);
        pthread_mutex_unlock(&s_lock);
    }
}

static void *accept_loop(void *arg)
{
    (void) arg;
    for (;;) {
        int fd = accept(s_listen_fd, NULL, NULL);
        if (fd < 0) {
            /* Per-connection / transient errors must NOT kill the accept thread.
             * A client that aborts mid-handshake — app crash, kill, or SpringBoard
             * relaunch churn — surfaces here as ECONNABORTED/ECONNRESET, and a
             * momentary fd shortage as EMFILE/ENFILE. Treating any of these as fatal
             * would stop the server accepting *all* future clients until it was
             * restarted (the app could never reattach). Keep looping; only a dead
             * listen socket (EBADF/EINVAL, i.e. server shutdown) ends the thread. */
            if (errno == EINTR || errno == ECONNABORTED || errno == ECONNRESET)
                continue;
            if (errno == EMFILE || errno == ENFILE) {
                usleep(10000);   /* out of fds: back off so we don't hot-spin */
                continue;
            }
            fprintf(stderr, "xios: accept fatal (%s) — accept thread exiting\n",
                    strerror(errno));
            break;
        }
        handle_client(fd);
    }
    return NULL;
}

/* ---- server lifecycle ----------------------------------------------------- */

int xios_server_start(const char *sock_path, const char *json_path,
                      int width, int height, int stride)
{
    if (s_listen_fd >= 0)
        return 0;               /* already serving (e.g. server regeneration) */

    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) { perror("xios: socket"); return -1; }
    set_cloexec(fd);
    if (strlen(sock_path) >= sizeof(((struct sockaddr_un *) 0)->sun_path)) {
        fprintf(stderr, "xios: socket path too long: %s\n", sock_path);
        close(fd);
        return -1;
    }

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, sock_path, sizeof(addr.sun_path) - 1);
    unlink(sock_path);
    if (bind(fd, (struct sockaddr *) &addr, sizeof(addr)) < 0) {
        perror("xios: bind");
        close(fd);
        return -1;
    }
    if (listen(fd, 4) < 0) {
        perror("xios: listen");
        close(fd);
        return -1;
    }
    /* The X server runs as root but the app runs as mobile, and connect() to a Unix
     * socket needs write permission on the socket file. Restrict it to mobile, with
     * numeric 501 as the stripped-image fallback. */
    {
        struct passwd *pw = getpwnam("mobile");
        uid_t uid = pw ? pw->pw_uid : 501;
        gid_t gid = pw ? pw->pw_gid : 501;
        if (chown(sock_path, uid, gid) == 0) {
            chmod(sock_path, 0660);
        } else {
            chmod(sock_path, 0600);
            fprintf(stderr, "xios_surface: keeping %s owner-only; chown mobile failed: %s\n",
                    sock_path, strerror(errno));
        }
    }
    s_listen_fd = fd;
    snprintf(s_sock_path_kept, sizeof(s_sock_path_kept), "%s", sock_path);
    snprintf(s_json_path_kept, sizeof(s_json_path_kept), "%s", json_path);

    /* Geometry handshake file: the app reads this to detect IOSurface mode and
     * find the socket before adopting the typed app stream. */
    write_json(json_path, width, height, stride, sock_path);

    if (pthread_create(&s_thread, NULL, accept_loop, NULL) != 0) {
        perror("xios: pthread_create");
        close(fd);
        s_listen_fd = -1;
        return -1;
    }
    pthread_detach(s_thread);
    fprintf(stderr, "xios: serving on %s\n", sock_path);
    return 0;
}

static void drop_client_locked(int i)
{
    if (i < 0 || i >= XIOS_MAX_CLIENTS || !s_clients[i].active)
        return;
    fprintf(stderr, "xios: client fd=%d dropped\n", s_clients[i].fd);
    shutdown(s_clients[i].fd, SHUT_RDWR);
    close(s_clients[i].fd);
    if (s_clients[i].dst != MACH_PORT_NULL)
        mach_port_deallocate(mach_task_self(), s_clients[i].dst);
    clear_client_pending_locked(i);
    memset(&s_clients[i], 0, sizeof(s_clients[i]));
    s_clients[i].fd = -1;
    s_nclients--;
    if (s_nclients == 0) {
        s_vblank_interval_us = 0;
        s_vblank_rx_ms = 0;
        s_vblank_deadline_ms = 0;
        s_present_age_valid = 0;
    }
}

/* Non-blocking send of a whole fixed record. Returns 1 = sent, 0 = would-block
 * (skip; DIRTY/CURSOR coalesce so a stale record is fine to drop), -1 = error or
 * PARTIAL write (a partial write desyncs the typed stream, so
 * the caller drops the client — matches the never-stall/drop-on-error posture). */
static int send_record(int fd, const void *buf, size_t len)
{
    ssize_t r = write(fd, buf, len);
    if (r == (ssize_t)len) return 1;
    if (r < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) return 0;
    if (r < 0 && errno == EINTR) return send_record(fd, buf, len);
    return -1;   /* error or partial (desync) */
}

static struct output_surface *find_output_locked(uint32_t id)
{
    for (unsigned i = 0; i < s_output_count; i++)
        if (s_outputs[i].id == id)
            return &s_outputs[i];
    return NULL;
}

static int find_output_index_locked(uint32_t id)
{
    for (unsigned i = 0; i < s_output_count; i++)
        if (s_outputs[i].id == id)
            return (int)i;
    return -1;
}

static struct stream_surface *find_stream_surface_locked(uint32_t id)
{
    for (int i = 0; i < XIOS_MAX_STREAM_SURFACES; i++)
        if (s_stream_surfaces[i].surface && s_stream_surfaces[i].id == id)
            return &s_stream_surfaces[i];
    return NULL;
}

static int send_stream_surface_locked(int slot, struct stream_surface *surface)
{
    if (!surface || slot < 0 || slot >= XIOS_MAX_CLIENTS ||
        !s_clients[slot].active ||
        !(s_clients[slot].caps & XIOS_HELLO_CAP_STREAM_V2))
        return -1;
    uint32_t bit = 1u << slot;
    if (surface->sent_clients & bit)
        return 0;

    xios_msg msg = {
        XIOS_MSG_MAGIC, XIOS_MSG_SURFACE, surface->id, 0,
        surface->width, surface->height, surface->stride,
        (int32_t)surface->flags
    };
    /* Control records cannot be dropped: a queued Mach port without its matching
     * SURFACE record would make the next import bind the wrong allocation. Drop
     * the connection on any backpressure and let a clean handshake recover. */
    if (deliver_surface_port(s_clients[slot].dst, surface->surface, 0) != 0 ||
        send_record(s_clients[slot].fd, &msg, sizeof(msg)) != 1)
        return -1;
    surface->sent_clients |= bit;
    return 0;
}

int xios_output_acquire(void **iosurface, uint32_t *surface_id,
                        unsigned *age, uint64_t *release_wait_value)
{
    if (iosurface) *iosurface = NULL;
    if (surface_id) *surface_id = 0;
    if (age) *age = 0;
    if (release_wait_value) *release_wait_value = 0;

    pthread_mutex_lock(&s_lock);
    uint32_t v2_clients = stream_v2_client_mask_locked();
    unsigned i = 0;
    int acquired = xios_output_queue_acquire(
        &s_output_queue, v2_clients != 0, &i, age, release_wait_value);
    if (acquired) {
        struct output_surface *out = &s_outputs[i];
        s_surface = out->surface;
        s_stride = out->stride;
        if (iosurface) *iosurface = out->surface;
        if (surface_id) *surface_id = out->id;
    }
    pthread_mutex_unlock(&s_lock);
    return acquired;
}

void xios_output_cancel(uint32_t surface_id)
{
    pthread_mutex_lock(&s_lock);
    int index = find_output_index_locked(surface_id);
    if (index >= 0)
        xios_output_queue_cancel(&s_output_queue, (unsigned)index);
    pthread_mutex_unlock(&s_lock);
}

uint32_t xios_stream_register_surface(void *iosurface, uint32_t flags)
{
    IOSurfaceRef surface = (IOSurfaceRef)iosurface;
    if (!surface || (flags & ~XIOS_SURFACE_FLAG_FLIP_Y))
        return 0;
    pthread_mutex_lock(&s_lock);
    for (int i = 0; i < XIOS_MAX_STREAM_SURFACES; i++) {
        if (s_stream_surfaces[i].surface == surface) {
            uint32_t id = s_stream_surfaces[i].id;
            pthread_mutex_unlock(&s_lock);
            return id;
        }
    }
    int slot = -1;
    for (int i = 0; i < XIOS_MAX_STREAM_SURFACES; i++)
        if (!s_stream_surfaces[i].surface) {
            slot = i;
            break;
        }
    if (slot < 0) {
        pthread_mutex_unlock(&s_lock);
        return 0;
    }
    struct stream_surface *entry = &s_stream_surfaces[slot];
    entry->surface = (IOSurfaceRef)CFRetain(surface);
    entry->id = s_next_stream_surface_id++;
    if (s_next_stream_surface_id < XIOS_DYNAMIC_SURFACE_ID_BASE)
        s_next_stream_surface_id = XIOS_DYNAMIC_SURFACE_ID_BASE;
    entry->flags = flags;
    entry->width = (int)IOSurfaceGetWidth(surface);
    entry->height = (int)IOSurfaceGetHeight(surface);
    entry->stride = (int)IOSurfaceGetBytesPerRow(surface);
    uint32_t id = entry->id;
    pthread_mutex_unlock(&s_lock);
    return id;
}

void xios_stream_unregister_surface(uint32_t surface_id)
{
    pthread_mutex_lock(&s_lock);
    struct stream_surface *entry = find_stream_surface_locked(surface_id);
    if (!entry) {
        pthread_mutex_unlock(&s_lock);
        return;
    }
    xios_msg msg = {
        XIOS_MSG_MAGIC, XIOS_MSG_SURFACE_DROP, surface_id, 0, 0, 0, 0, 0
    };
    for (int i = 0; i < XIOS_MAX_CLIENTS; i++) {
        uint32_t bit = 1u << i;
        if (!s_clients[i].active || !(entry->sent_clients & bit))
            continue;
        if (send_record(s_clients[i].fd, &msg, sizeof(msg)) != 1)
            drop_client_locked(i);
    }
    IOSurfaceRef surface = entry->surface;
    memset(entry, 0, sizeof(*entry));
    pthread_mutex_unlock(&s_lock);
    CFRelease(surface);
}

uint64_t xios_stream_released_generation(uint32_t surface_id)
{
    uint64_t seq = 0;
    pthread_mutex_lock(&s_lock);
    struct stream_surface *entry =
        find_stream_surface_locked(surface_id);
    if (entry)
        seq = entry->released_seq;
    pthread_mutex_unlock(&s_lock);
    return seq;
}

int xios_stream_v2_active(void)
{
    int active;
    pthread_mutex_lock(&s_lock);
    active = s_nclients == 1 && stream_v2_client_mask_locked() != 0;
    pthread_mutex_unlock(&s_lock);
    return active;
}

static int notify_dirty_internal(uint32_t surface_id,
                                 const void *shared_event_token,
                                 size_t token_size,
                                 uint64_t event_value,
                                 uint64_t *seq_out)
{
    if (!shared_event_token ||
        token_size != XIOS_GPU_FENCE_TOKEN_SIZE ||
        event_value == 0)
        return -1;

    unsigned char wire[sizeof(xios_msg) + XIOS_GPU_FENCE_TOKEN_SIZE];

    pthread_mutex_lock(&s_lock);
    struct output_surface *output = find_output_locked(surface_id);
    int output_index = output ? find_output_index_locked(surface_id) : -1;
    struct stream_surface *stream = output ? NULL
        : find_stream_surface_locked(surface_id);
    if (!output && !stream) {
        pthread_mutex_unlock(&s_lock);
        return -1;
    }
    uint64_t seq = ++s_dirty_seq;
    xios_msg rec = { XIOS_MSG_MAGIC, XIOS_MSG_DIRTY,
                     surface_id,
                     XIOS_GPU_FENCE_TOKEN_SIZE,
                     (int32_t)(uint32_t)(seq & 0xffffffffu),
                     (int32_t)(uint32_t)(seq >> 32),
                     (int32_t)(uint32_t)(event_value & 0xffffffffu),
                     (int32_t)(uint32_t)(event_value >> 32) };
    memcpy(wire, &rec, sizeof(rec));
    memcpy(wire + sizeof(rec), shared_event_token, XIOS_GPU_FENCE_TOKEN_SIZE);
    uint32_t delivered = 0;
    for (int i = 0; i < XIOS_MAX_CLIENTS; i++) {
        if (!s_clients[i].active)
            continue;
        int v2 = !!(s_clients[i].caps & XIOS_HELLO_CAP_STREAM_V2);
        if (!v2 && surface_id != XIOS_PRIMARY_SURFACE_ID)
            continue;
        if (stream && send_stream_surface_locked(i, stream) != 0) {
            drop_client_locked(i);
            continue;
        }
        int ok = send_record(s_clients[i].fd, wire,
                             sizeof(rec) + XIOS_GPU_FENCE_TOKEN_SIZE);
        if (ok > 0)
            delivered |= 1u << i;
        else if (ok < 0)
            drop_client_locked(i);
    }
    if (output) {
        /* A fixed one-buffer producer may negotiate stream-v2 only for the
         * surface-addressed framing while retaining the legacy no-release
         * contract (Mutter currently does this). Never park that sole output
         * behind a RELEASED message the handshake gave the app no event with
         * which to produce. Multi-buffer iosc always installs a release token
         * before the server starts, so its ownership path remains mandatory. */
        uint32_t pending_clients = s_release_token_size
            ? delivered & stream_v2_client_mask_locked() : 0;
        xios_output_queue_publish(
            &s_output_queue, (unsigned)output_index, pending_clients, seq);
    } else {
        stream->last_seq = seq;
    }
    if (seq_out) *seq_out = seq;
    pthread_mutex_unlock(&s_lock);
    return 0;
}

int xios_notify_dirty_with_fence(const void *shared_event_token,
                                 size_t token_size,
                                 uint64_t event_value)
{
    return notify_dirty_internal(XIOS_PRIMARY_SURFACE_ID,
                                 shared_event_token, token_size,
                                 event_value, NULL);
}

int xios_notify_surface_with_fence(uint32_t surface_id,
                                   const void *shared_event_token,
                                   size_t token_size,
                                   uint64_t event_value,
                                   uint64_t *seq_out)
{
    return notify_dirty_internal(surface_id, shared_event_token, token_size,
                                 event_value, seq_out);
}

uint64_t xios_dirty_generation(void)
{
    uint64_t seq;
    pthread_mutex_lock(&s_lock);
    seq = s_dirty_seq;
    pthread_mutex_unlock(&s_lock);
    return seq;
}

uint64_t xios_presented_generation(void)
{
    uint64_t seq;
    pthread_mutex_lock(&s_lock);
    seq = s_presented_seq;
    pthread_mutex_unlock(&s_lock);
    return seq;
}

void xios_notify_cursor(int x, int y, int visible, int shape_id)
{
    xios_msg rec = { XIOS_MSG_MAGIC, XIOS_MSG_CURSOR, 0, 0,
                     x, y, shape_id, visible ? 1 : 0 };
    pthread_mutex_lock(&s_lock);
    for (int i = 0; i < XIOS_MAX_CLIENTS; i++) {
        if (!s_clients[i].active)
            continue;
        if (send_record(s_clients[i].fd, &rec, sizeof(rec)) < 0)
            drop_client_locked(i);
    }
    pthread_mutex_unlock(&s_lock);
}

int xios_have_app_client(void)
{
    int any;
    pthread_mutex_lock(&s_lock);
    any = s_nclients > 0;
    pthread_mutex_unlock(&s_lock);
    return any;
}

/* ---- client→server IOSurface import (Wayland zero-copy GPU buffers) -------- */

/* The output IOSurface (the one the Xios app displays), as an opaque handle so a
 * GPU compositor can bind it as an ANGLE render target without this file pulling
 * in EGL. NULL until xios_surface_create(). */
void *xios_get_output_iosurface(void) { return (void *) s_surface; }

/* kIOSurfaceLockReadOnly without pulling the full IOSurface enum header. */
#define XIOS_LOCK_READONLY 0x00000001u

void *xios_import_client_iosurface(int pid, unsigned port_name, int *w, int *h)
{
    task_t task = MACH_PORT_NULL;
    kern_return_t kr = task_for_pid(mach_task_self(), pid, &task);
    if (kr) {
        fprintf(stderr, "xios: import task_for_pid(%d) failed: 0x%x (%s) — needs "
                        "task_for_pid-allow on iosc + get-task-allow on the client\n",
                pid, kr, mach_error_string(kr));
        return NULL;
    }

    /* Copy a send right to the client's IOSurface mach port out of its task. */
    mach_port_t sp = MACH_PORT_NULL;
    mach_msg_type_name_t acq;
    kr = mach_port_extract_right(task, (mach_port_name_t) port_name,
                                 MACH_MSG_TYPE_COPY_SEND, &sp, &acq);
    mach_port_deallocate(mach_task_self(), task);
    if (kr) {
        fprintf(stderr, "xios: import mach_port_extract_right failed: 0x%x (%s)\n",
                kr, mach_error_string(kr));
        return NULL;
    }

    IOSurfaceRef s = IOSurfaceLookupFromMachPort(sp);
    mach_port_deallocate(mach_task_self(), sp);   /* lookup retained the surface */
    if (!s) {
        fprintf(stderr, "xios: import IOSurfaceLookupFromMachPort returned NULL\n");
        return NULL;
    }
    if (w) *w = (int) IOSurfaceGetWidth(s);
    if (h) *h = (int) IOSurfaceGetHeight(s);
    fprintf(stderr, "xios: imported client IOSurface id=%u %zux%zu stride=%zu\n",
            (unsigned) IOSurfaceGetID(s), IOSurfaceGetWidth(s), IOSurfaceGetHeight(s),
            IOSurfaceGetBytesPerRow(s));
    return (void *) s;
}

void xios_release_client_iosurface(void *client_surface)
{
    if (client_surface) CFRelease((IOSurfaceRef) client_surface);
}

void xios_probe_client_iosurface(void *client_surface, const char *tag)
{
    if (!tag) tag = "?";
    IOSurfaceRef s = (IOSurfaceRef) client_surface;
    if (!s) {
        fprintf(stderr, "xios-probe[%s]: NULL surface\n", tag);
        return;
    }
    if (IOSurfaceLock(s, XIOS_LOCK_READONLY, NULL) != KERN_SUCCESS) {
        fprintf(stderr, "xios-probe[%s]: IOSurfaceLock failed\n", tag);
        return;
    }
    const uint8_t *base = (const uint8_t *) IOSurfaceGetBaseAddress(s);
    if (!base) {
        IOSurfaceUnlock(s, XIOS_LOCK_READONLY, NULL);
        fprintf(stderr, "xios-probe[%s]: no base address\n", tag);
        return;
    }
    size_t stride = IOSurfaceGetBytesPerRow(s);
    int w = (int) IOSurfaceGetWidth(s);
    int h = (int) IOSurfaceGetHeight(s);

    /* BGRA8: [0]=B [1]=G [2]=R [3]=A. Colour and alpha are counted separately
     * on purpose — see the header. */
    unsigned long colour_px = 0, alpha_px = 0, opaque_px = 0, total = 0;
    for (int y = 0; y < h; y++) {
        const uint8_t *row = base + (size_t) y * stride;
        for (int x = 0; x < w; x++) {
            const uint8_t *p = row + (size_t) x * 4;
            if (p[0] | p[1] | p[2]) colour_px++;
            if (p[3]) alpha_px++;
            if (p[3] == 0xff) opaque_px++;
            total++;
        }
    }
    const uint8_t *c = base + (size_t)(h / 2) * stride + (size_t)(w / 2) * 4;
    fprintf(stderr, "xios-probe[%s]: %dx%d stride=%zu colour=%lu/%lu alpha=%lu "
                    "opaque=%lu centre=B%02x G%02x R%02x A%02x\n",
            tag, w, h, stride, colour_px, total, alpha_px, opaque_px,
            c[0], c[1], c[2], c[3]);
    IOSurfaceUnlock(s, XIOS_LOCK_READONLY, NULL);
}

void xios_surface_geometry(int *width, int *height)
{
    if (width)  *width  = s_width;
    if (height) *height = s_height;
}

uint32_t xios_read_output_pixel(int x, int y)
{
    if (!s_surface || x < 0 || y < 0 || x >= s_width || y >= s_height) return 0;
    /* Read-only lock so a GPU compositor's writes into the output are flushed to the
     * CPU mapping before we sample it (same coherency reason as the source blit). */
    if (IOSurfaceLock(s_surface, XIOS_LOCK_READONLY, NULL) != KERN_SUCCESS)
        return 0;
    const uint8_t *base = (const uint8_t *) IOSurfaceGetBaseAddress(s_surface);
    if (!base) {
        IOSurfaceUnlock(s_surface, XIOS_LOCK_READONLY, NULL);
        return 0;
    }
    uint32_t px = *(const uint32_t *) (base + (size_t) y * s_stride + (size_t) x * 4);
    IOSurfaceUnlock(s_surface, XIOS_LOCK_READONLY, NULL);
    return px;
}

int xios_read_output_region(int x, int y, int w, int h, void *dst, int dst_stride)
{
    if (!s_surface || !dst || w <= 0 || h <= 0 || x < 0 || y < 0) return -1;
    int cw = w, ch = h;                       /* clamp the rect to the surface */
    if (x + cw > s_width)  cw = s_width  - x;
    if (y + ch > s_height) ch = s_height - y;
    if (cw <= 0 || ch <= 0) return -1;
    if (dst_stride < cw * 4) return -1;
    /* One read-only lock for the whole region (coherency: same as the pixel read). */
    if (IOSurfaceLock(s_surface, XIOS_LOCK_READONLY, NULL) != KERN_SUCCESS)
        return -1;
    const uint8_t *base = (const uint8_t *) IOSurfaceGetBaseAddress(s_surface);
    if (!base) {
        IOSurfaceUnlock(s_surface, XIOS_LOCK_READONLY, NULL);
        return -1;
    }
    for (int row = 0; row < ch; row++) {
        const uint8_t *src = base + (size_t) (y + row) * s_stride + (size_t) x * 4;
        uint8_t *d = (uint8_t *) dst + (size_t) row * dst_stride;
        memcpy(d, src, (size_t) cw * 4);
    }
    IOSurfaceUnlock(s_surface, XIOS_LOCK_READONLY, NULL);
    return 0;
}

void xios_server_stop(void)
{
    pthread_mutex_lock(&s_lock);
    for (int i = 0; i < XIOS_MAX_CLIENTS; i++) {
        if (!s_clients[i].active)
            continue;
        shutdown(s_clients[i].fd, SHUT_RDWR);
        close(s_clients[i].fd);
        if (s_clients[i].dst != MACH_PORT_NULL)
            mach_port_deallocate(mach_task_self(), s_clients[i].dst);
        memset(&s_clients[i], 0, sizeof(s_clients[i]));
        s_clients[i].fd = -1;
    }
    s_nclients = 0;
    pthread_mutex_unlock(&s_lock);

    if (s_listen_fd >= 0) { close(s_listen_fd); s_listen_fd = -1; }
    for (unsigned i = 0; i < s_output_count; i++) {
        if (s_outputs[i].surface)
            CFRelease(s_outputs[i].surface);
        memset(&s_outputs[i], 0, sizeof(s_outputs[i]));
    }
    for (int i = 0; i < XIOS_MAX_STREAM_SURFACES; i++) {
        if (s_stream_surfaces[i].surface)
            CFRelease(s_stream_surfaces[i].surface);
        memset(&s_stream_surfaces[i], 0, sizeof(s_stream_surfaces[i]));
    }
    s_output_count = 0;
    xios_output_queue_reset(&s_output_queue, 0);
    s_surface = NULL;
}

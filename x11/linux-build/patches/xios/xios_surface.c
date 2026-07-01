/*
 * xios_surface.c — IOSurface-backed shared framebuffer + mach-port rendezvous for
 * the native iOS X server ("Xios", an Xvfb-derived DDX). See xios_surface.h.
 *
 * Deliberately includes NO X server headers — only Apple frameworks + POSIX — so
 * CoreFoundation/IOSurface/mach declarations can't collide with dix macros.
 */
#include "xios_surface.h"

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
#include <pwd.h>
#include <mach/mach.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOSurface/IOSurfaceRef.h>

/* X server display-number string (e.g. "3" for `Xios :3`). Declared extern rather
 * than pulled from a dix header so this file stays free of X server includes. */
extern char *display;

/* ---- wire protocol (native LE; server + app are both arm64) ---------------- */

#define XIOS_MAGIC      0x58494F31u   /* 'XIO1' */
#define XIOS_FMT_BGRA   0x42475241u   /* 'BGRA' */
#define XIOS_DIRTY      0x01          /* one-byte "framebuffer changed" signal */

/* app -> server, sent once on connect */
typedef struct {
    uint32_t magic;
    uint32_t pid;
    uint32_t portname;     /* mach receive-port name in the app's IPC space */
    uint32_t reserved;
} xios_hello;

/* server -> app, sent once after the mach port is delivered */
typedef struct {
    uint32_t magic;
    uint32_t width;
    uint32_t height;
    uint32_t stride;       /* bytes per row */
    uint32_t format;       /* XIOS_FMT_BGRA */
    uint32_t status;       /* 0 = ok */
} xios_reply;

/* mach message carrying the IOSurface send right */
typedef struct {
    mach_msg_header_t header;
    mach_msg_body_t body;
    mach_msg_port_descriptor_t port;
} xios_port_msg;

/* ---- state ---------------------------------------------------------------- */

#define XIOS_MAX_CLIENTS 8

static IOSurfaceRef s_surface = NULL;
static int s_width, s_height, s_stride;

static int s_listen_fd = -1;
static pthread_t s_thread;
static pthread_mutex_t s_lock = PTHREAD_MUTEX_INITIALIZER;
static int s_clients[XIOS_MAX_CLIENTS];
static int s_client_typed[XIOS_MAX_CLIENTS];   /* parallel: client speaks the typed stream */
static int s_nclients = 0;
static char s_compositor_id[32] = "";          /* "iosc"/"mutter-ios"; sent in the typed HELLO */

void xios_set_compositor_id(const char *id)
{
    snprintf(s_compositor_id, sizeof(s_compositor_id), "%s", id ? id : "");
}

/* ---- helpers -------------------------------------------------------------- */

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

/* ---- IOSurface ------------------------------------------------------------ */

void *xios_surface_create(int width, int height, int *stride, int *alloc_size)
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

    s_surface = s;
    s_width = width;
    s_height = height;
    s_stride = (int) IOSurfaceGetBytesPerRow(s);
    int alloc_sz = (int) IOSurfaceGetAllocSize(s);

    /* Zero the buffer so the first frame isn't garbage. */
    if (IOSurfaceLock(s, 0, NULL) != KERN_SUCCESS) {
        fprintf(stderr, "xios: IOSurfaceLock failed during init\n");
        CFRelease(s);
        s_surface = NULL;
        return NULL;
    }
    void *base = IOSurfaceGetBaseAddress(s);
    if (!base) {
        fprintf(stderr, "xios: IOSurfaceGetBaseAddress returned NULL\n");
        IOSurfaceUnlock(s, 0, NULL);
        CFRelease(s);
        s_surface = NULL;
        return NULL;
    }
    memset(base, 0, (size_t) alloc_sz);
    IOSurfaceUnlock(s, 0, NULL);

    if (stride) *stride = s_stride;
    if (alloc_size) *alloc_size = alloc_sz;
    fprintf(stderr, "xios: IOSurface %dx%d id=%u stride=%d alloc=%d base=%p\n",
            width, height, (unsigned) IOSurfaceGetID(s), s_stride, alloc_sz, base);
    return base;
}

/* ---- mach-port hand-off --------------------------------------------------- */

/* task_for_pid the app, extract a send right to its receive port, and mach_msg
 * the IOSurface's mach port across. Returns 0 on success. */
static int deliver_surface_port(int pid, unsigned portname)
{
    task_t task = MACH_PORT_NULL;
    kern_return_t kr = task_for_pid(mach_task_self(), pid, &task);
    if (kr) {
        fprintf(stderr, "xios: task_for_pid(%d) failed: 0x%x (%s) — needs "
                        "task_for_pid-allow on Xios + get-task-allow on the app\n",
                pid, kr, mach_error_string(kr));
        return -1;
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
        return -1;
    }

    mach_port_t sp = IOSurfaceCreateMachPort(s_surface);
    if (sp == MACH_PORT_NULL) {
        fprintf(stderr, "xios: IOSurfaceCreateMachPort failed\n");
        mach_port_deallocate(mach_task_self(), dst);
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
    kr = mach_msg(&msg.header, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof(msg), 0,
                  MACH_PORT_NULL, 2000 /*ms*/, MACH_PORT_NULL);

    /* Drop our local refs; the kernel copied what it needed into the message. */
    mach_port_deallocate(mach_task_self(), sp);
    mach_port_deallocate(mach_task_self(), dst);

    if (kr) {
        fprintf(stderr, "xios: mach_msg(send IOSurface port) failed: 0x%x (%s)\n",
                kr, mach_error_string(kr));
        return -1;
    }
    return 0;
}

static void add_client(int fd, int typed)
{
    pthread_mutex_lock(&s_lock);
    if (s_nclients < XIOS_MAX_CLIENTS) {
        s_client_typed[s_nclients] = typed;
        s_clients[s_nclients++] = fd;
        fprintf(stderr, "xios: client attached (fd=%d, typed=%d, total=%d)\n",
                fd, typed, s_nclients);
    } else {
        close(fd);
        fprintf(stderr, "xios: too many clients, rejecting fd=%d\n", fd);
    }
    pthread_mutex_unlock(&s_lock);
}

static void handle_client(int fd)
{
    set_cloexec(fd);
    set_nosigpipe(fd);

    /* bound the handshake so a stuck client can't hang the accept thread */
    struct timeval tv = { 3, 0 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

    xios_hello hello;
    if (read_full(fd, &hello, sizeof(hello)) != 0 || hello.magic != XIOS_MAGIC) {
        fprintf(stderr, "xios: bad handshake from fd=%d\n", fd);
        close(fd);
        return;
    }

    /* Don't trust the client-supplied pid for task_for_pid — a malicious client
     * could name another process and have us hand it the surface port. Use the
     * kernel-reported peer pid of the socket; fall back to the claim only if the
     * lookup fails (it shouldn't for an AF_UNIX peer). */
    pid_t peer_pid = 0;
    socklen_t plen = sizeof(peer_pid);
    if (getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &peer_pid, &plen) != 0 || peer_pid <= 0) {
        peer_pid = (pid_t) hello.pid;
    } else if ((uint32_t) peer_pid != hello.pid) {
        fprintf(stderr, "xios: client claimed pid %u but socket peer is %d; "
                        "using the real peer\n", hello.pid, (int) peer_pid);
    }

    int status = deliver_surface_port((int) peer_pid, hello.portname);

    xios_reply reply;
    reply.magic = XIOS_MAGIC;
    reply.width = (uint32_t) s_width;
    reply.height = (uint32_t) s_height;
    reply.stride = (uint32_t) s_stride;
    reply.format = XIOS_FMT_BGRA;
    reply.status = (uint32_t) (status != 0);
    if (write_full(fd, &reply, sizeof(reply)) != 0 || status != 0) {
        close(fd);
        return;
    }
    /* Typed clients also get an in-band HELLO (geometry + which compositor is
     * driving) right after the classic reply — the socket-native replacement for
     * the app reading xios.json. Sent while still blocking (pre-O_NONBLOCK) so the
     * app reliably has it before the DIRTY/CURSOR stream begins. */
    int typed = (hello.reserved == XIOS_HELLO_TYPED);
    if (typed) {
        uint32_t idlen = (uint32_t) strlen(s_compositor_id);
        xios_msg h = { XIOS_MSG_MAGIC, XIOS_MSG_HELLO, 0, idlen,
                       s_width, s_height, s_stride, (int32_t) XIOS_FMT_BGRA };
        if (write_full(fd, &h, sizeof(h)) != 0 ||
            (idlen && write_full(fd, s_compositor_id, idlen) != 0)) {
            close(fd);
            return;
        }
    }
    /* Damage notifications are non-blocking: a suspended/backed-up app must never
     * stall the X server's block handler. */
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK);
    add_client(fd, typed);
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
     * socket needs write permission on the socket file. Rather than 0777 (any local
     * uid can connect), restrict it to mobile: chown to mobile + 0660. Fall back to
     * 0777 only if that user can't be resolved, so the app is never locked out. */
    {
        struct passwd *pw = getpwnam("mobile");
        if (pw && chown(sock_path, pw->pw_uid, pw->pw_gid) == 0)
            chmod(sock_path, 0660);
        else
            chmod(sock_path, 0777);
    }
    s_listen_fd = fd;

    /* Geometry handshake file: the app reads this to detect IOSurface mode and
     * find the socket. Presence of "ddx":"iosurface" gates zero-copy vs the old
     * Xvfb file-mmap fallback. */
    FILE *jf = fopen(json_path, "w");
    if (jf) {
        fprintf(jf,
                "{\"width\":%d,\"height\":%d,\"stride\":%d,"
                "\"format\":\"BGRA\",\"ddx\":\"iosurface\",\"socket\":\"%s\","
                "\"display\":\":%s\"}\n",
                width, height, stride, sock_path, display ? display : "0");
        fclose(jf);
    }

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

/* Swap-remove client index i (caller holds s_lock). */
static void drop_client_locked(int i)
{
    fprintf(stderr, "xios: client fd=%d dropped\n", s_clients[i]);
    close(s_clients[i]);
    s_clients[i] = s_clients[s_nclients - 1];
    s_client_typed[i] = s_client_typed[s_nclients - 1];
    s_nclients--;
}

/* Non-blocking send of a whole fixed record (typed clients). Returns 1 = sent,
 * 0 = would-block (skip; DIRTY/CURSOR coalesce so a stale record is fine to
 * drop), -1 = error or PARTIAL write (a partial write desyncs a typed stream, so
 * the caller drops the client — matches the never-stall/drop-on-error posture). */
static int send_record(int fd, const void *buf, size_t len)
{
    ssize_t r = write(fd, buf, len);
    if (r == (ssize_t)len) return 1;
    if (r < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) return 0;
    if (r < 0 && errno == EINTR) return send_record(fd, buf, len);
    return -1;   /* error or partial (desync) */
}

void xios_notify_dirty(void)
{
    const unsigned char b = XIOS_DIRTY;
    xios_msg rec = { XIOS_MSG_MAGIC, XIOS_MSG_DIRTY, 0, 0, 0, 0, 0, 0 };  /* whole-surface */

    pthread_mutex_lock(&s_lock);
    int i = 0;
    while (i < s_nclients) {
        int ok;
        if (s_client_typed[i]) {
            ok = send_record(s_clients[i], &rec, sizeof(rec));
        } else {
            ssize_t r = write(s_clients[i], &b, 1);
            /* classic 1-byte DIRTY: delivered, or behind (coalesces) => keep */
            ok = (r == 1) ? 1 : (r < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) ? 0
               : (r < 0 && errno == EINTR) ? 0 : -1;
        }
        if (ok >= 0) { i++; continue; }
        drop_client_locked(i);
    }
    pthread_mutex_unlock(&s_lock);
}

void xios_notify_cursor(int x, int y, int visible, int shape_id)
{
    xios_msg rec = { XIOS_MSG_MAGIC, XIOS_MSG_CURSOR, 0, 0,
                     x, y, shape_id, visible ? 1 : 0 };
    pthread_mutex_lock(&s_lock);
    int i = 0;
    while (i < s_nclients) {
        if (!s_client_typed[i]) { i++; continue; }   /* classic clients can't parse it */
        if (send_record(s_clients[i], &rec, sizeof(rec)) >= 0) { i++; continue; }
        drop_client_locked(i);
    }
    pthread_mutex_unlock(&s_lock);
}

int xios_have_typed_client(void)
{
    int any = 0;
    pthread_mutex_lock(&s_lock);
    for (int i = 0; i < s_nclients; i++)
        if (s_client_typed[i]) { any = 1; break; }
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

void xios_blit_client_iosurface(void *client_surface)
{
    IOSurfaceRef src = (IOSurfaceRef) client_surface;
    if (!src || !s_surface) return;

    /* Lock the source read-only so the GPU's writes are made coherent to the CPU
     * (the client glFinish()es before signalling, so the frame is complete). */
    if (IOSurfaceLock(src, XIOS_LOCK_READONLY, NULL) != KERN_SUCCESS)
        return;
    const uint8_t *sbase = (const uint8_t *) IOSurfaceGetBaseAddress(src);
    if (!sbase) {
        IOSurfaceUnlock(src, XIOS_LOCK_READONLY, NULL);
        return;
    }
    size_t sstride = IOSurfaceGetBytesPerRow(src);
    int sw = (int) IOSurfaceGetWidth(src);
    int sh = (int) IOSurfaceGetHeight(src);

    uint8_t *dbase = (uint8_t *) IOSurfaceGetBaseAddress(s_surface);
    if (!dbase) {
        IOSurfaceUnlock(src, XIOS_LOCK_READONLY, NULL);
        return;
    }
    int rows = sh < s_height ? sh : s_height;
    int cols = sw < s_width  ? sw : s_width;
    size_t row_bytes = (size_t) cols * 4;   /* BGRA8 both sides */
    for (int y = 0; y < rows; y++)
        memcpy(dbase + (size_t) y * s_stride, sbase + (size_t) y * sstride, row_bytes);

    IOSurfaceUnlock(src, XIOS_LOCK_READONLY, NULL);
}

void xios_release_client_iosurface(void *client_surface)
{
    if (client_surface) CFRelease((IOSurfaceRef) client_surface);
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
    for (int i = 0; i < s_nclients; i++)
        close(s_clients[i]);
    s_nclients = 0;
    pthread_mutex_unlock(&s_lock);

    if (s_listen_fd >= 0) { close(s_listen_fd); s_listen_fd = -1; }
    if (s_surface) { CFRelease(s_surface); s_surface = NULL; }
}

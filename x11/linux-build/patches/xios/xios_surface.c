/*
 * xios_surface.c — IOSurface-backed compositor output + app rendezvous.
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
#include <poll.h>
#include <pwd.h>
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

struct app_client {
    int fd;
};

static IOSurfaceRef s_surface = NULL;
static int s_width, s_height, s_stride;

static int s_listen_fd = -1;
static pthread_t s_thread;
static pthread_mutex_t s_lock = PTHREAD_MUTEX_INITIALIZER;
static struct app_client s_clients[XIOS_MAX_CLIENTS];
static int s_nclients = 0;
static uint64_t s_dirty_seq = 0;
static uint64_t s_presented_seq = 0;
static char s_compositor_id[32] = "";          /* "iosc"/"mutter-ios"; sent in the typed HELLO */
static char s_input_socket[108] = "";          /* app input socket; emitted in xios.json when set */
static char s_clipboard_socket[108] = "";      /* app clipboard socket; emitted when set */
static unsigned s_generation = 0;              /* bumped by resize; stale handshakes close */
static char s_sock_path_kept[256] = "";        /* for resize-time xios.json rewrite */
static char s_json_path_kept[256] = "";

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
    int st = 0, alloc_sz = 0;
    IOSurfaceRef s = make_surface(width, height, &st, &alloc_sz);
    if (!s)
        return NULL;

    s_surface = s;
    s_width = width;
    s_height = height;
    s_stride = st;
    if (stride) *stride = st;
    if (alloc_size) *alloc_size = alloc_sz;
    void *base = IOSurfaceGetBaseAddress(s);
    return base;
}

void *xios_surface_resize(int width, int height, int *stride, int *alloc_size)
{
    int st = 0, alloc_sz = 0;
    IOSurfaceRef ns = make_surface(width, height, &st, &alloc_sz);
    if (!ns)
        return NULL;
    void *base = IOSurfaceGetBaseAddress(ns);
    if (!base) {
        CFRelease(ns);
        return NULL;
    }

    pthread_mutex_lock(&s_lock);
    IOSurfaceRef old = s_surface;
    s_surface = ns;
    s_width = width;
    s_height = height;
    s_stride = st;
    s_generation++;
    for (int i = 0; i < s_nclients; i++)
        close(s_clients[i].fd);
    s_nclients = 0;
    pthread_mutex_unlock(&s_lock);

    if (old)
        CFRelease(old);
    if (s_json_path_kept[0] && s_sock_path_kept[0])
        write_json(s_json_path_kept, width, height, st, s_sock_path_kept);
    if (stride) *stride = st;
    if (alloc_size) *alloc_size = alloc_sz;
    fprintf(stderr, "xios: output resized to %dx%d stride=%d (clients dropped)\n",
            width, height, st);
    return base;
}

/* ---- mach-port hand-off --------------------------------------------------- */

/* task_for_pid the app, extract a send right to its receive port, and mach_msg
 * the IOSurface's mach port across. Returns 0 on success. */
static int deliver_surface_port(int pid, unsigned portname, IOSurfaceRef surf)
{
    if (!surf) {
        fprintf(stderr, "xios: no IOSurface available for hand-off\n");
        return -1;
    }

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

    mach_port_t sp = IOSurfaceCreateMachPort(surf);
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

static int add_client(int fd, unsigned generation)
{
    int ok = 0;
    pthread_mutex_lock(&s_lock);
    if (generation != s_generation) {
        close(fd);
        fprintf(stderr, "xios: stale app client fd=%d rejected after resize\n", fd);
    } else if (s_nclients < XIOS_MAX_CLIENTS) {
        s_clients[s_nclients++].fd = fd;
        ok = 1;
        fprintf(stderr, "xios: app client attached (typed fd=%d, total=%d)\n",
                fd, s_nclients);
    } else {
        close(fd);
        fprintf(stderr, "xios: too many clients, rejecting fd=%d\n", fd);
    }
    pthread_mutex_unlock(&s_lock);
    return ok;
}

static void drop_client_fd_locked(int fd)
{
    for (int i = 0; i < s_nclients; i++) {
        if (s_clients[i].fd != fd)
            continue;
        fprintf(stderr, "xios: client fd=%d dropped\n", fd);
        close(s_clients[i].fd);
        s_clients[i] = s_clients[s_nclients - 1];
        s_nclients--;
        return;
    }
}

static void handle_client_msg(const xios_msg *m)
{
    if (m->type != XIOS_MSG_PRESENTED)
        return;
    uint64_t seq = ((uint64_t)(uint32_t)m->b << 32) | (uint32_t)m->a;
    pthread_mutex_lock(&s_lock);
    if (seq > s_presented_seq)
        s_presented_seq = seq;
    pthread_mutex_unlock(&s_lock);
}

static void *client_read_loop(void *arg)
{
    int fd = *(int *)arg;
    free(arg);

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
                handle_client_msg(&m);
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
    pthread_mutex_lock(&s_lock);
    drop_client_fd_locked(fd);
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
        hello.c != 0 ||
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

    pthread_mutex_lock(&s_lock);
    IOSurfaceRef surf = s_surface ? (IOSurfaceRef) CFRetain(s_surface) : NULL;
    int w = s_width, hgt = s_height, st = s_stride;
    unsigned gen = s_generation;
    pthread_mutex_unlock(&s_lock);

    int status = deliver_surface_port((int) peer_pid, (uint32_t)hello.b, surf);
    if (status != 0) {
        if (surf) CFRelease(surf);
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
        if (surf) CFRelease(surf);
        close(fd);
        return;
    }
    if (surf) CFRelease(surf);
    /* Damage notifications are non-blocking: a suspended/backed-up app must never
     * stall the X server's block handler. */
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK);
    if (!add_client(fd, gen))
        return;
    int *rfd = malloc(sizeof(*rfd));
    if (rfd) {
        *rfd = fd;
        pthread_t reader;
        if (pthread_create(&reader, NULL, client_read_loop, rfd) == 0)
            pthread_detach(reader);
        else
            free(rfd);
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

/* Swap-remove client index i (caller holds s_lock). */
static void drop_client_locked(int i)
{
    fprintf(stderr, "xios: client fd=%d dropped\n", s_clients[i].fd);
    close(s_clients[i].fd);
    s_clients[i] = s_clients[s_nclients - 1];
    s_nclients--;
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

static int notify_dirty_internal(const void *shared_event_token,
                                 size_t token_size,
                                 uint64_t event_value)
{
    if (!shared_event_token ||
        token_size != XIOS_GPU_FENCE_TOKEN_SIZE ||
        event_value == 0)
        return -1;

    uint64_t seq;
    unsigned char wire[sizeof(xios_msg) + XIOS_GPU_FENCE_TOKEN_SIZE];

    pthread_mutex_lock(&s_lock);
    seq = ++s_dirty_seq;
    xios_msg rec = { XIOS_MSG_MAGIC, XIOS_MSG_DIRTY,
                     XIOS_DIRTY_FENCE_BROKER_TOKEN,
                     XIOS_GPU_FENCE_TOKEN_SIZE,
                     (int32_t)(uint32_t)(seq & 0xffffffffu),
                     (int32_t)(uint32_t)(seq >> 32),
                     (int32_t)(uint32_t)(event_value & 0xffffffffu),
                     (int32_t)(uint32_t)(event_value >> 32) };
    memcpy(wire, &rec, sizeof(rec));
    memcpy(wire + sizeof(rec), shared_event_token, XIOS_GPU_FENCE_TOKEN_SIZE);
    int i = 0;
    while (i < s_nclients) {
        int ok = send_record(s_clients[i].fd, wire,
                             sizeof(rec) + XIOS_GPU_FENCE_TOKEN_SIZE);
        if (ok >= 0) { i++; continue; }
        drop_client_locked(i);
    }
    pthread_mutex_unlock(&s_lock);
    return 0;
}

int xios_notify_dirty_with_fence(const void *shared_event_token,
                                 size_t token_size,
                                 uint64_t event_value)
{
    return notify_dirty_internal(shared_event_token, token_size, event_value);
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
    int i = 0;
    while (i < s_nclients) {
        if (send_record(s_clients[i].fd, &rec, sizeof(rec)) >= 0) { i++; continue; }
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
    for (int i = 0; i < s_nclients; i++)
        close(s_clients[i].fd);
    s_nclients = 0;
    pthread_mutex_unlock(&s_lock);

    if (s_listen_fd >= 0) { close(s_listen_fd); s_listen_fd = -1; }
    if (s_surface) { CFRelease(s_surface); s_surface = NULL; }
}

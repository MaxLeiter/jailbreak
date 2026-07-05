/*
 * xios_canvas.c — per-window presentation for the native-iPadOS flavor. See
 * xios_canvas.h. Mirrors xios_surface.c's proven patterns (bounded handshake,
 * peer-pid trust, non-blocking never-stall sends, resilient accept) and reuses
 * the SAME mach primitives; the only real generalization is 1 surface -> N
 * canvases and a reply port that comes from BIND (per host) instead of a
 * per-delivery hello.
 *
 * Threading: ONE background thread runs a poll() over the listen fd + every host
 * connection. Listen readable => accept + BIND handshake; a host fd readable =>
 * read fixed 32-byte control records (RESIZE/ACTIVATE/CLOSED) and dispatch the
 * handlers. Writes (announce/dirty/geom/title/gone) come from iosc's event-loop
 * thread and take s_lock. Control handlers fire ON the reader thread; iosc.c
 * marshals them onto its wl loop (frozen half).
 *
 * Standalone TU: NO Wayland/GL headers, so it can be written + compile-checked
 * ahead of the iosc.c freeze lifting.
 */
#include "xios_canvas.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <limits.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <pwd.h>
#include <mach/mach.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOSurface/IOSurfaceRef.h>

#define XIOS_FMT_BGRA 0x42475241u   /* 'BGRA' (matches xios_surface.c) */

/* ---- state ---------------------------------------------------------------- */

#define XIOS_CANVAS_MAX_CLIENTS 16
#define XIOS_CANVAS_MAX_WINDOWS 64

/* A connected per-app host: one BIND, one reply port shared by its canvases. */
struct canvas_client {
    int              fd;
    pid_t            pid;                 /* kernel-reported socket peer pid */
    mach_port_name_t reply_port;          /* name in the host's IPC space (BIND.d) */
    char             app_id[256];
    uint8_t          inbuf[sizeof(xios_msg)];
    size_t           infill;              /* bytes accumulated toward one record */
};

/* Pending async delivery. The blocking mach-port hand-off (task_for_pid +
 * mach_msg, which a suspended host can stall for the full send timeout) must NEVER
 * run on iosc's wl event-loop thread. So the wl thread only flags a window here +
 * nudges the reader thread; the reader drains the flag and does the actual
 * WINDOW_NEW/GEOM record + port hand-off (process_pending_deliveries). */
#define CANVAS_DELIVER_NONE 0
#define CANVAS_DELIVER_NEW  1             /* WINDOW_NEW + first canvas port */
#define CANVAS_DELIVER_GEOM 2             /* WINDOW_GEOM + fresh port (post-resize) */

/* A per-window canvas. app_id is copied at announce; senders resolve the host by
 * matching it, so client swap-remove / host reconnect never dangle a pointer. */
struct canvas_entry {
    uint32_t     window_id;               /* 0 = free slot */
    IOSurfaceRef surface;
    int          w, h, stride;
    char         app_id[256];
    char         title[256];
    uint32_t     flags;
    int          announced;               /* WINDOW_NEW delivered (so DIRTY may flow) */
    int          deliver_pending;         /* CANVAS_DELIVER_* queued for the reader */
};

static int s_listen_fd = -1;
static pthread_t s_thread;
static int s_thread_running = 0;
static int s_wake_pipe[2] = { -1, -1 };   /* nudges poll() when a client is added */
static pthread_mutex_t s_lock = PTHREAD_MUTEX_INITIALIZER;

static struct canvas_client s_clients[XIOS_CANVAS_MAX_CLIENTS];
static int s_nclients = 0;
static struct canvas_entry s_windows[XIOS_CANVAS_MAX_WINDOWS];

/* Scene size (physical px) of the most recently bound host. iosc reads this to
 * size a toplevel's initial configure so its first mapped frame fits the tapped
 * scene exactly (the app_id isn't reliably set at initial-configure time, so we
 * key on "the host that just launched" instead). Guarded by s_lock. */
static int s_last_scene_w = 0, s_last_scene_h = 0;

static struct xios_canvas_handlers s_handlers;

/* ---- small IO + fd helpers (same shape as xios_surface.c) ----------------- */

static void set_cloexec(int fd)
{
    int f = fcntl(fd, F_GETFD, 0);
    if (f >= 0) fcntl(fd, F_SETFD, f | FD_CLOEXEC);
}
static void set_nonblock(int fd)
{
    int f = fcntl(fd, F_GETFL, 0);
    if (f >= 0) fcntl(fd, F_SETFL, f | O_NONBLOCK);
}
static void set_nosigpipe(int fd)
{
    int on = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));
}

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
/* Non-blocking send of a whole record (matches xios_surface.c's send_record):
 * 1 = sent, 0 = would-block (drop; DIRTY coalesces), -1 = error/partial. */
static int send_record(int fd, const void *buf, size_t len)
{
    ssize_t r = write(fd, buf, len);
    if (r == (ssize_t)len) return 1;
    if (r < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) return 0;
    if (r < 0 && errno == EINTR) return send_record(fd, buf, len);
    return -1;
}

/* Nudge the reader thread out of poll() so it drains queued canvas deliveries.
 * One byte is enough (the reader processes ALL pending entries per wake), and the
 * pipe is non-blocking so a full pipe (many coalesced nudges) is harmlessly
 * dropped — the reader still scans everything. */
static void wake_reader(void)
{
    if (s_wake_pipe[1] >= 0) { char b = 1; (void)write(s_wake_pipe[1], &b, 1); }
}

/* ---- IOSurface allocation (BGRA8, aligned — same as xios_surface_create) --- */

static int cf_setnum(CFMutableDictionaryRef d, const void *key, int32_t v)
{
    CFNumberRef n = CFNumberCreate(NULL, kCFNumberSInt32Type, &v);
    if (!n) return -1;
    CFDictionarySetValue(d, key, n);
    CFRelease(n);
    return 0;
}

static IOSurfaceRef canvas_alloc(int w, int h, int *stride_out)
{
    const int bpe = 4;
    if (w <= 0 || h <= 0 || w > INT_MAX / bpe) return NULL;
    size_t bpr   = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, (size_t)w * bpe);
    size_t alloc = IOSurfaceAlignProperty(kIOSurfaceAllocSize, bpr * (size_t)h);
    if (bpr > INT32_MAX || alloc > INT32_MAX) return NULL;

    CFMutableDictionaryRef d = CFDictionaryCreateMutable(
        NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    if (!d) return NULL;
    if (cf_setnum(d, kIOSurfaceWidth, w) != 0 ||
        cf_setnum(d, kIOSurfaceHeight, h) != 0 ||
        cf_setnum(d, kIOSurfaceBytesPerElement, bpe) != 0 ||
        cf_setnum(d, kIOSurfaceBytesPerRow, (int32_t)bpr) != 0 ||
        cf_setnum(d, kIOSurfaceAllocSize, (int32_t)alloc) != 0 ||
        cf_setnum(d, kIOSurfacePixelFormat, (int32_t)XIOS_FMT_BGRA) != 0) {
        CFRelease(d); return NULL;
    }
    IOSurfaceRef s = IOSurfaceCreate(d);
    CFRelease(d);
    if (!s) {
        fprintf(stderr, "xios-canvas: IOSurfaceCreate failed (%dx%d) — check the "
                        "iokit-user-client-class entitlement\n", w, h);
        return NULL;
    }
    /* Zero it so the first frame isn't garbage. */
    if (IOSurfaceLock(s, 0, NULL) == KERN_SUCCESS) {
        void *base = IOSurfaceGetBaseAddress(s);
        if (base) memset(base, 0, (size_t)IOSurfaceGetAllocSize(s));
        IOSurfaceUnlock(s, 0, NULL);
    }
    if (stride_out) *stride_out = (int)IOSurfaceGetBytesPerRow(s);
    return s;
}

/* ---- registry (caller holds s_lock unless noted) -------------------------- */

static struct canvas_entry *window_find(uint32_t id)
{
    if (!id) return NULL;
    for (int i = 0; i < XIOS_CANVAS_MAX_WINDOWS; i++)
        if (s_windows[i].window_id == id) return &s_windows[i];
    return NULL;
}
static struct canvas_entry *window_alloc(uint32_t id)
{
    struct canvas_entry *e = window_find(id);
    if (e) return e;
    for (int i = 0; i < XIOS_CANVAS_MAX_WINDOWS; i++)
        if (s_windows[i].window_id == 0) { s_windows[i].window_id = id; return &s_windows[i]; }
    return NULL;
}
static struct canvas_client *client_for_app(const char *app_id)
{
    if (!app_id || !*app_id) return NULL;
    for (int i = 0; i < s_nclients; i++)
        if (strcmp(s_clients[i].app_id, app_id) == 0) return &s_clients[i];
    return NULL;
}

static int deliver_canvas_port(pid_t pid, mach_port_name_t reply_port, IOSurfaceRef canvas);
static void drop_client_locked(int i);

static void drop_client_fd_locked(int fd)
{
    for (int i = 0; i < s_nclients; i++) {
        if (s_clients[i].fd == fd) {
            drop_client_locked(i);
            return;
        }
    }
}

static int send_buffer_locked(struct canvas_client *c, const void *buf, size_t len)
{
    if (!c) return -1;
    int fd = c->fd;
    int r = send_record(fd, buf, len);
    if (r < 0)
        drop_client_fd_locked(fd);        /* partial stream write: reconnect cleanly */
    return r;
}

static int send_msg_locked(struct canvas_client *c, const xios_msg *h,
                           const void *payload, size_t payload_len)
{
    if (payload_len > 255) payload_len = 255;
    uint8_t buf[sizeof(*h) + 255];
    memcpy(buf, h, sizeof(*h));
    if (payload_len)
        memcpy(buf + sizeof(*h), payload, payload_len);
    return send_buffer_locked(c, buf, sizeof(*h) + payload_len);
}

static xios_msg make_msg(uint32_t type, uint32_t window_id)
{
    xios_msg m;
    memset(&m, 0, sizeof(m));
    m.magic = XIOS_MSG_MAGIC;
    m.type = type;
    m.window_id = window_id;
    return m;
}

static void chmod_mobile_socket(const char *path, const char *warn_suffix)
{
    struct passwd *pw = getpwnam("mobile");
    uid_t uid = pw ? pw->pw_uid : 501;   /* mobile is uid 501 on iOS */
    gid_t gid = pw ? pw->pw_gid : 501;
    if (chown(path, uid, gid) == 0) {
        chmod(path, 0660);
        return;
    }
    chmod(path, 0600);
    fprintf(stderr, "xios-canvas: WARNING could not chown %s to mobile (%s); %s\n",
            path, strerror(errno), warn_suffix);
}

/* Queue every live window for this app_id for (re)delivery — a host binding for
 * the first time, or rebinding after a jetsam kill, gets WINDOW_NEW + the live
 * canvas port for each. Runs on the reader thread under s_lock; the delivery
 * itself happens in process_pending_deliveries at the bottom of the same loop
 * iteration, so it never blocks here. */
static void replay_windows_for_client_locked(struct canvas_client *c)
{
    if (!c || !c->app_id[0]) return;
    for (int i = 0; i < XIOS_CANVAS_MAX_WINDOWS; i++) {
        struct canvas_entry *e = &s_windows[i];
        if (!e->window_id || !e->surface) continue;
        if (strcmp(e->app_id, c->app_id) != 0) continue;
        e->deliver_pending = CANVAS_DELIVER_NEW;
    }
}

/* ---- generalized mach-port hand-off --------------------------------------- */

/* task_for_pid the host, extract a send right to its BIND reply port, and
 * mach_msg the canvas IOSurface's port across. Generalization of
 * deliver_surface_port: the surface is a per-window canvas and the destination
 * port name comes from BIND (per host) rather than a per-connection hello. */
static int deliver_canvas_port(pid_t pid, mach_port_name_t reply_port, IOSurfaceRef canvas)
{
    if (canvas == NULL || reply_port == MACH_PORT_NULL) {
        fprintf(stderr, "xios-canvas: cannot deliver canvas port pid=%d reply_port=0x%x canvas=%p\n",
                (int)pid, reply_port, (void *)canvas);
        return -1;
    }

    task_t task = MACH_PORT_NULL;
    kern_return_t kr = task_for_pid(mach_task_self(), (int)pid, &task);
    if (kr) {
        fprintf(stderr, "xios-canvas: task_for_pid(%d) failed: 0x%x (%s) — needs "
                        "task_for_pid-allow on iosc + get-task-allow on the host\n",
                (int)pid, kr, mach_error_string(kr));
        return -1;
    }

    mach_port_t dst = MACH_PORT_NULL;
    mach_msg_type_name_t acq;
    kr = mach_port_extract_right(task, reply_port, MACH_MSG_TYPE_COPY_SEND, &dst, &acq);
    mach_port_deallocate(mach_task_self(), task);
    if (kr) {
        fprintf(stderr, "xios-canvas: mach_port_extract_right failed: 0x%x (%s)\n",
                kr, mach_error_string(kr));
        return -1;
    }

    mach_port_t sp = IOSurfaceCreateMachPort(canvas);
    if (sp == MACH_PORT_NULL) {
        fprintf(stderr, "xios-canvas: IOSurfaceCreateMachPort failed\n");
        mach_port_deallocate(mach_task_self(), dst);
        return -1;
    }

    struct {
        mach_msg_header_t          header;
        mach_msg_body_t            body;
        mach_msg_port_descriptor_t port;
    } msg;
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

    /* MACH_SEND_TIMEOUT must be in the option mask or the timeout is ignored; a
     * suspended host must never block the reader thread (and every other host). */
    kr = mach_msg(&msg.header, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof(msg), 0,
                  MACH_PORT_NULL, 2000 /*ms*/, MACH_PORT_NULL);

    mach_port_deallocate(mach_task_self(), sp);
    mach_port_deallocate(mach_task_self(), dst);
    if (kr) {
        fprintf(stderr, "xios-canvas: mach_msg(send canvas port) failed: 0x%x (%s)\n",
                kr, mach_error_string(kr));
        return -1;
    }
    return 0;
}

/* ---- public: registry + announce ------------------------------------------ */

void *xios_canvas_create(uint32_t window_id, int w, int h, int *stride)
{
    if (!window_id) return NULL;
    pthread_mutex_lock(&s_lock);
    struct canvas_entry *e = window_alloc(window_id);
    if (!e) { pthread_mutex_unlock(&s_lock); return NULL; }
    if (e->surface) { CFRelease(e->surface); e->surface = NULL; }  /* resize realloc */
    int st = 0;
    IOSurfaceRef s = canvas_alloc(w, h, &st);
    if (!s) {
        /* Keep the slot (announced state) so a caller can retry; report failure. */
        pthread_mutex_unlock(&s_lock);
        return NULL;
    }
    e->surface = s; e->w = w; e->h = h; e->stride = st;
    if (stride) *stride = st;
    pthread_mutex_unlock(&s_lock);
    return s;   /* opaque IOSurfaceRef; iosc owns the registry ref */
}

int xios_canvas_default_scene(int *w_px, int *h_px)
{
    pthread_mutex_lock(&s_lock);
    int w = s_last_scene_w, h = s_last_scene_h;
    pthread_mutex_unlock(&s_lock);
    if (w <= 0 || h <= 0) return -1;
    if (w_px) *w_px = w;
    if (h_px) *h_px = h;
    return 0;
}

void *xios_canvas_surface(uint32_t window_id)
{
    pthread_mutex_lock(&s_lock);
    struct canvas_entry *e = window_find(window_id);
    void *s = e ? (void *)e->surface : NULL;
    pthread_mutex_unlock(&s_lock);
    return s;
}

int xios_canvas_announce(uint32_t window_id, const char *app_id,
                         const char *title, uint32_t flags)
{
    pthread_mutex_lock(&s_lock);
    struct canvas_entry *e = window_find(window_id);
    if (!e || !e->surface) { pthread_mutex_unlock(&s_lock); return -1; }
    snprintf(e->app_id, sizeof(e->app_id), "%s", app_id ? app_id : "");
    snprintf(e->title, sizeof(e->title), "%s", title ? title : "");
    e->flags = flags;

    struct canvas_client *c = client_for_app(e->app_id);
    if (!c) { pthread_mutex_unlock(&s_lock); return 0; }   /* no host: catch-all */

    /* Queue the WINDOW_NEW + canvas hand-off for the reader thread (never block the
     * compositor on a slow/suspended host). `announced` stays 0 until the reader
     * actually delivers, which gates DIRTY so it can't precede WINDOW_NEW. */
    e->deliver_pending = CANVAS_DELIVER_NEW;
    wake_reader();
    pthread_mutex_unlock(&s_lock);
    return 1;   /* a host is bound; delivery queued */
}

void xios_canvas_geom(uint32_t window_id)
{
    pthread_mutex_lock(&s_lock);
    struct canvas_entry *e = window_find(window_id);
    if (!e || !e->surface) { pthread_mutex_unlock(&s_lock); return; }
    struct canvas_client *c = client_for_app(e->app_id);
    if (!c) { pthread_mutex_unlock(&s_lock); return; }
    /* A pending WINDOW_NEW already carries the latest geometry (read at delivery
     * time), so don't downgrade it to GEOM — that would send WINDOW_GEOM for a
     * window the host never saw a WINDOW_NEW for. */
    if (e->deliver_pending != CANVAS_DELIVER_NEW)
        e->deliver_pending = e->announced ? CANVAS_DELIVER_GEOM : CANVAS_DELIVER_NEW;
    wake_reader();
    pthread_mutex_unlock(&s_lock);
}

void xios_canvas_notify_dirty(uint32_t window_id, int x, int y, int w, int h)
{
    pthread_mutex_lock(&s_lock);
    struct canvas_entry *e = window_find(window_id);
    if (!e || !e->announced) { pthread_mutex_unlock(&s_lock); return; }
    struct canvas_client *c = client_for_app(e->app_id);
    if (c) {
        xios_msg rec = make_msg(XIOS_MSG_DIRTY, window_id);
        rec.a = x; rec.b = y; rec.c = w; rec.d = h;
        (void)send_msg_locked(c, &rec, NULL, 0);   /* drop-on-backpressure */
    }
    pthread_mutex_unlock(&s_lock);
}

void xios_canvas_title(uint32_t window_id, const char *title)
{
    pthread_mutex_lock(&s_lock);
    struct canvas_entry *e = window_find(window_id);
    if (!e) { pthread_mutex_unlock(&s_lock); return; }
    snprintf(e->title, sizeof(e->title), "%s", title ? title : "");
    if (!e->announced) { pthread_mutex_unlock(&s_lock); return; }
    struct canvas_client *c = client_for_app(e->app_id);
    if (c) {
        xios_msg h = make_msg(XIOS_MSG_WINDOW_TITLE, window_id);
        size_t tlen = title ? strlen(title) : 0;
        if (tlen > 255) tlen = 255;
        h.length = (uint32_t)tlen;
        (void)send_msg_locked(c, &h, title, tlen);
    }
    pthread_mutex_unlock(&s_lock);
}

void xios_canvas_gone(uint32_t window_id)
{
    pthread_mutex_lock(&s_lock);
    struct canvas_entry *e = window_find(window_id);
    if (e) {
        /* Send WINDOW_GONE even if `announced` is still 0: a WINDOW_NEW may be
         * in-flight on the reader thread right now, and gating on `announced`
         * would drop the GONE and orphan a scene the host is about to create. A
         * GONE for a window the host never saw is a harmless no-op there. */
        struct canvas_client *c = client_for_app(e->app_id);
        if (c) {
            xios_msg h = make_msg(XIOS_MSG_WINDOW_GONE, window_id);
            if (send_msg_locked(c, &h, NULL, 0) == 0)
                drop_client_fd_locked(c->fd);      /* avoid orphaning a host that is not reading */
        }
        if (e->surface) CFRelease(e->surface);
        memset(e, 0, sizeof(*e));   /* frees the slot (window_id back to 0) */
    }
    pthread_mutex_unlock(&s_lock);
}

/* ---- BIND handshake + host control reader --------------------------------- */

/* Bounded blocking read of one BIND record + app_id payload on a fresh fd. On
 * success records the client (fd, peer pid, reply port, app_id) and returns 0. */
static int handle_bind(int fd)
{
    set_cloexec(fd);
    set_nosigpipe(fd);
    struct timeval tv = { 3, 0 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

    xios_msg h;
    if (read_full(fd, &h, sizeof(h)) != 0 ||
        h.magic != XIOS_MSG_MAGIC || h.type != XIOS_MSG_BIND) {
        fprintf(stderr, "xios-canvas: bad BIND handshake on fd=%d\n", fd);
        close(fd);
        return -1;
    }
    char app_id[256];
    uint32_t idlen = h.length;
    if (idlen > sizeof(app_id) - 1) idlen = sizeof(app_id) - 1;
    if (idlen && read_full(fd, app_id, idlen) != 0) { close(fd); return -1; }
    app_id[idlen] = 0;
    /* Drain any app_id overflow past 255. */
    for (uint32_t left = h.length - idlen; left; ) {
        char scratch[256];
        uint32_t chunk = left > sizeof(scratch) ? (uint32_t)sizeof(scratch) : left;
        if (read_full(fd, scratch, chunk) != 0) { close(fd); return -1; }
        left -= chunk;
    }

    /* Trust the kernel peer pid, not the client claim (same as xios_surface.c). */
    pid_t peer_pid = 0;
    socklen_t plen = sizeof(peer_pid);
    if (getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &peer_pid, &plen) != 0 || peer_pid <= 0)
        peer_pid = 0;

    pthread_mutex_lock(&s_lock);
    if (s_nclients >= XIOS_CANVAS_MAX_CLIENTS) {
        pthread_mutex_unlock(&s_lock);
        fprintf(stderr, "xios-canvas: too many hosts, rejecting fd=%d\n", fd);
        close(fd);
        return -1;
    }
    struct canvas_client *c = &s_clients[s_nclients++];
    memset(c, 0, sizeof(*c));
    c->fd = fd;
    c->pid = peer_pid;
    c->reply_port = (mach_port_name_t)(uint32_t)h.d;
    snprintf(c->app_id, sizeof(c->app_id), "%s", app_id);
    /* Remember this host's scene size so iosc can size a freshly-launched app's
     * initial configure to the tapped scene (xios_canvas_default_scene). */
    if (h.a > 0 && h.b > 0) { s_last_scene_w = h.a; s_last_scene_h = h.b; }
    fprintf(stderr, "xios-canvas: BIND app_id=\"%s\" pid=%d fd=%d scene=%dx%d scale=%d reply_port=0x%x\n",
            app_id, (int)peer_pid, fd, h.a, h.b, h.c, c->reply_port);
    replay_windows_for_client_locked(c);
    pthread_mutex_unlock(&s_lock);

    /* Reads of subsequent control records are non-blocking (poll-driven). */
    set_nonblock(fd);
    fprintf(stderr, "xios-canvas: host bound app_id=\"%s\" pid=%d fd=%d (total=%d)\n",
            app_id, (int)peer_pid, fd, s_nclients);
    return 0;
}

/* Swap-remove client index i (caller holds s_lock). Canvases retain their
 * metadata; a re-bind by the same app_id gets WINDOW_NEW + the live port again. */
static void drop_client_locked(int i)
{
    fprintf(stderr, "xios-canvas: host fd=%d (app_id=\"%s\") dropped\n",
            s_clients[i].fd, s_clients[i].app_id);
    close(s_clients[i].fd);
    s_clients[i] = s_clients[s_nclients - 1];
    s_nclients--;
}

/* Dispatch one fully-read 32-byte control record from a host. Called on the
 * reader thread WITHOUT s_lock held (handlers may call back into iosc). Returns
 * 0 to keep the host, -1 for a protocol mismatch. */
static int dispatch_control(const xios_msg *m)
{
    switch (m->type) {
    case XIOS_MSG_RESIZE:
        if (s_handlers.resize) s_handlers.resize(m->window_id, m->a, m->b, s_handlers.user);
        return 0;
    case XIOS_MSG_ACTIVATE:
        if (s_handlers.activate) s_handlers.activate(m->window_id, m->a != 0, s_handlers.user);
        return 0;
    case XIOS_MSG_CLOSED:
        if (s_handlers.closed) s_handlers.closed(m->window_id, s_handlers.user);
        return 0;
    default:
        fprintf(stderr, "xios-canvas: unknown host record type=0x%x window=%u; dropping host\n",
                m->type, m->window_id);
        return -1;
    }
}

/* A host fd is readable: accumulate into its 32-byte record buffer and dispatch
 * every complete record. Returns 0 to keep the client, -1 to drop it (EOF/err).
 * Caller holds s_lock; we release it around dispatch so handlers can re-enter. */
static int client_readable_locked(int idx)
{
    struct canvas_client *c = &s_clients[idx];
    uint8_t buf[512];
    ssize_t r = read(c->fd, buf, sizeof(buf));
    if (r == 0) return -1;                                  /* EOF */
    if (r < 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) return 0;
        return -1;
    }
    size_t off = 0;
    while (off < (size_t)r) {
        size_t need = sizeof(xios_msg) - c->infill;
        size_t avail = (size_t)r - off;
        size_t take = avail < need ? avail : need;
        memcpy(c->inbuf + c->infill, buf + off, take);
        c->infill += take; off += take;
        if (c->infill < sizeof(xios_msg)) break;            /* partial record */
        xios_msg m;
        memcpy(&m, c->inbuf, sizeof(m));
        c->infill = 0;
        if (m.magic != XIOS_MSG_MAGIC) return -1;           /* desync => drop */
        int fd = c->fd;
        /* Dispatch outside the lock: a handler may call xios_canvas_* back. */
        pthread_mutex_unlock(&s_lock);
        int bad = dispatch_control(&m);
        pthread_mutex_lock(&s_lock);
        if (bad < 0) return -1;
        idx = -1;
        for (int i = 0; i < s_nclients; i++)
            if (s_clients[i].fd == fd) { idx = i; break; }
        if (idx < 0) return 0;            /* host was already dropped */
        c = &s_clients[idx];
    }
    return 0;
}

/* Drain queued canvas deliveries — the ONLY place the blocking mach hand-off runs
 * (reader thread, never the compositor). Single-threaded here, so each window's
 * {WINDOW_NEW/GEOM record, canvas port} pair stays correlated on the host
 * (recv_canvas reads the port right after the record). The record write stays
 * under s_lock (serialized with the wl thread's DIRTY/TITLE writes; the fd is
 * non-blocking so it can't stall); the mach send runs unlocked so a suspended
 * host stalls only this thread, not the compositor. */
static void process_pending_deliveries(void)
{
    for (int i = 0; i < XIOS_CANVAS_MAX_WINDOWS; i++) {
        pthread_mutex_lock(&s_lock);
        struct canvas_entry *e = &s_windows[i];
        if (!e->window_id || !e->surface || e->deliver_pending == CANVAS_DELIVER_NONE) {
            pthread_mutex_unlock(&s_lock);
            continue;
        }
        struct canvas_client *c = client_for_app(e->app_id);
        if (!c) {                         /* host vanished before we delivered */
            e->deliver_pending = CANVAS_DELIVER_NONE;
            pthread_mutex_unlock(&s_lock);
            continue;
        }
        int kind = e->deliver_pending;
        e->deliver_pending = CANVAS_DELIVER_NONE;
        uint32_t window_id = e->window_id;
        int fd = c->fd;
        pid_t pid = c->pid;
        mach_port_name_t reply_port = c->reply_port;

        xios_msg rec = make_msg((kind == CANVAS_DELIVER_NEW) ? XIOS_MSG_WINDOW_NEW : XIOS_MSG_WINDOW_GEOM,
                                window_id);
        rec.a = e->w; rec.b = e->h; rec.c = e->stride; rec.d = (int32_t)e->flags;
        size_t tlen = (kind == CANVAS_DELIVER_NEW) ? strlen(e->title) : 0;
        if (tlen > 255) tlen = 255;
        rec.length = (uint32_t)tlen;
        uint8_t out[sizeof(rec) + 255];
        memcpy(out, &rec, sizeof(rec));
        if (tlen)
            memcpy(out + sizeof(rec), e->title, tlen);
        int wrote = send_record(fd, out, sizeof(rec) + tlen) == 1;
        IOSurfaceRef surf = e->surface;
        CFRetain(surf);                   /* hold across the unlocked mach hand-off */
        pthread_mutex_unlock(&s_lock);

        int dr = wrote ? deliver_canvas_port(pid, reply_port, surf) : -1;
        CFRelease(surf);

        pthread_mutex_lock(&s_lock);
        e = window_find(window_id);       /* may have been torn down meanwhile */
        if (e && kind == CANVAS_DELIVER_NEW)
            e->announced = (wrote && dr == 0);
        if (!wrote)
            drop_client_fd_locked(fd);    /* partial/error/backpressure: host can re-BIND */
        pthread_mutex_unlock(&s_lock);

        if (!wrote || dr != 0)
            fprintf(stderr, "xios-canvas: deliver (kind=%d) failed for window=%u\n",
                    kind, window_id);
    }
}

static void *reader_loop(void *arg)
{
    (void)arg;
    struct pollfd pfds[XIOS_CANVAS_MAX_CLIENTS + 2];
    while (s_thread_running) {
        pthread_mutex_lock(&s_lock);
        int n = 0;
        pfds[n].fd = s_listen_fd;   pfds[n].events = POLLIN; n++;
        pfds[n].fd = s_wake_pipe[0]; pfds[n].events = POLLIN; n++;
        int base = n;
        for (int i = 0; i < s_nclients && n < (int)(sizeof(pfds)/sizeof(pfds[0])); i++) {
            pfds[n].fd = s_clients[i].fd; pfds[n].events = POLLIN; pfds[n].revents = 0; n++;
        }
        pthread_mutex_unlock(&s_lock);

        int pr = poll(pfds, n, -1);
        if (pr < 0) { if (errno == EINTR) continue; break; }

        if (pfds[0].revents & POLLIN) {
            int fd = accept(s_listen_fd, NULL, NULL);
            if (fd >= 0) handle_bind(fd);
            else if (!(errno == EINTR || errno == ECONNABORTED || errno == ECONNRESET)) {
                if (errno == EMFILE || errno == ENFILE) usleep(10000);
                else break;   /* dead listen socket => shutdown */
            }
        }
        if (pfds[1].revents & POLLIN) {   /* wake nudge: rebuild the fd set */
            char drain[64];
            while (read(s_wake_pipe[0], drain, sizeof(drain)) > 0) { }
        }
        /* Host control fds. Map poll slots back to client indices by fd, dropping
         * on error. Iterate a snapshot of fds since drops mutate s_clients. */
        for (int p = base; p < n; p++) {
            if (!(pfds[p].revents & (POLLIN | POLLHUP | POLLERR))) continue;
            pthread_mutex_lock(&s_lock);
            int idx = -1;
            for (int i = 0; i < s_nclients; i++)
                if (s_clients[i].fd == pfds[p].fd) { idx = i; break; }
            if (idx >= 0) {
                if (client_readable_locked(idx) < 0) drop_client_locked(idx);
            }
            pthread_mutex_unlock(&s_lock);
        }

        /* After every wake (a nudge from announce/geom, a fresh BIND's replay, or
         * host traffic) drain any queued canvas hand-offs on THIS thread. */
        process_pending_deliveries();
    }
    return NULL;
}

/* ---- lifecycle ------------------------------------------------------------ */

void xios_canvas_set_handlers(const struct xios_canvas_handlers *h)
{
    pthread_mutex_lock(&s_lock);
    if (h) s_handlers = *h;
    else memset(&s_handlers, 0, sizeof(s_handlers));
    pthread_mutex_unlock(&s_lock);
}

int xios_canvas_server_start(const char *sock_path)
{
    if (s_listen_fd >= 0) return 0;   /* already serving */
    const char *path = (sock_path && *sock_path) ? sock_path : XIOS_CANVAS_SOCK;

    if (strlen(path) >= sizeof(((struct sockaddr_un *)0)->sun_path)) {
        fprintf(stderr, "xios-canvas: socket path too long: %s\n", path);
        return -1;
    }
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) { perror("xios-canvas: socket"); return -1; }
    set_cloexec(fd);

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, path, sizeof(addr.sun_path) - 1);
    unlink(path);
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("xios-canvas: bind"); close(fd); return -1;
    }
    if (listen(fd, 8) < 0) { perror("xios-canvas: listen"); close(fd); return -1; }
    /* Hosts run as mobile; connect() needs write on the socket. Lock it to mobile
     * (0660) so no other uid can bind an app_id and receive its canvas ports. The
     * whole native flavor's isolation rests on app_id addressing, so never leave
     * this world-writable — fall back to mobile's canonical uid, and only if even
     * that fails degrade to root-only (native mode won't work, but nothing leaks).
     * getpwnam("mobile") resolving is the universal case on iOS. */
    chmod_mobile_socket(path, "native hosts may fail to connect");
    if (pipe(s_wake_pipe) == 0) {
        set_cloexec(s_wake_pipe[0]); set_cloexec(s_wake_pipe[1]);
        set_nonblock(s_wake_pipe[0]);
        set_nonblock(s_wake_pipe[1]);
    }
    s_listen_fd = fd;
    s_thread_running = 1;
    if (pthread_create(&s_thread, NULL, reader_loop, NULL) != 0) {
        perror("xios-canvas: pthread_create");
        close(fd); s_listen_fd = -1; s_thread_running = 0;
        return -1;
    }
    pthread_detach(s_thread);
    fprintf(stderr, "xios-canvas: serving native rendezvous on %s\n", path);
    return 0;
}

void xios_canvas_server_stop(void)
{
    s_thread_running = 0;
    /* Wake the reader out of poll(-1) so it observes the cleared flag and exits
     * before we close the fds under it. */
    if (s_wake_pipe[1] >= 0) { char b = 1; (void)write(s_wake_pipe[1], &b, 1); }
    if (s_listen_fd >= 0) { close(s_listen_fd); s_listen_fd = -1; }
    pthread_mutex_lock(&s_lock);
    for (int i = 0; i < s_nclients; i++) close(s_clients[i].fd);
    s_nclients = 0;
    for (int i = 0; i < XIOS_CANVAS_MAX_WINDOWS; i++)
        if (s_windows[i].surface) { CFRelease(s_windows[i].surface); }
    memset(s_windows, 0, sizeof(s_windows));
    pthread_mutex_unlock(&s_lock);
    if (s_wake_pipe[0] >= 0) { close(s_wake_pipe[0]); s_wake_pipe[0] = -1; }
    if (s_wake_pipe[1] >= 0) { close(s_wake_pipe[1]); s_wake_pipe[1] = -1; }
}

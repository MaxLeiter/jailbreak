/*
 * iosc_egl_shim.c — a wayland-egl↔ANGLE EGL platform shim (libiosc_egl.dylib).
 *
 * iOS has no Wayland EGL platform in ANGLE and no dma-buf. This shim is a tiny
 * "Mesa-wayland-egl-platform" retargeted to IOSurface + the iosc_iosurface
 * protocol: a GL client (GTK4/GSK, Qt, SDL, ...) that does the standard
 * eglGetPlatformDisplay(WAYLAND) + wl_egl_window + eglCreateWindowSurface +
 * eglSwapBuffers dance renders on the A10 (ANGLE→Metal) straight into IOSurfaces,
 * which are handed to the iosc compositor zero-copy.
 *
 * Mechanism: dlopen ANGLE's real libEGL and forward ~every EGL call to it, EXCEPT
 *   - eglGetPlatformDisplay/eglGetDisplay  -> ANGLE Metal display (record wl_display)
 *   - eglCreateWindowSurface(wl_egl_window) -> N IOSurfaces + ANGLE iosurface
 *     pbuffers; the client renders into pbuf[cur] as FBO 0 (proven renderable).
 *   - eglMakeCurrent(window)                -> bind pbuf[cur]
 *   - eglSwapBuffers(window)                -> fence/flush pbuf[cur], hand its
 *     IOSurface to iosc (create_buffer + attach + commit), then rotate to the
 *     next released pbuffer.
 * Loaded in place of ANGLE's libEGL (the GL client / libepoxy resolves us first).
 *
 * MIT.
 */
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>

#include <wayland-client.h>
#include <wayland-egl-backend.h>     /* struct wl_egl_window layout */
#include "iosc-iosurface-client-protocol.h"
#include "xios_metal_sync.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOSurface/IOSurfaceRef.h>
#include <mach/mach.h>

#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <unistd.h>

#ifndef EGL_PLATFORM_ANGLE_ANGLE
#define EGL_PLATFORM_ANGLE_ANGLE 0x3202
#define EGL_PLATFORM_ANGLE_TYPE_ANGLE 0x3203
#endif
#ifndef EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE
#define EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE 0x3489
#endif
#ifndef EGL_PLATFORM_WAYLAND_KHR
#define EGL_PLATFORM_WAYLAND_KHR 0x31D8
#endif
#ifndef EGL_IOSURFACE_ANGLE
#define EGL_IOSURFACE_ANGLE 0x3454
#define EGL_IOSURFACE_PLANE_ANGLE 0x345A
#define EGL_TEXTURE_TYPE_ANGLE 0x345C
#define EGL_TEXTURE_INTERNAL_FORMAT_ANGLE 0x345D
#endif
#ifndef GL_BGRA_EXT
#define GL_BGRA_EXT 0x80E1
#endif

#define IOSC_NBUF 3
#define WIN_MAGIC 0x494f5357u  /* 'IOSW' */

/* ---- real ANGLE libEGL ---------------------------------------------------- */

static void *s_angle;
static void  ensure_angle(void)
{
    if (s_angle) return;
    /* The real ANGLE libEGL. When the shim is installed as the standing
     * /var/jb/lib/angle/libEGL.dylib, the package keeps ANGLE itself at
     * libEGL.angle.dylib so we don't dlopen ourselves. ANGLE_REAL_LIBEGL can
     * still override this for ad-hoc testing. */
    const char *path = getenv("ANGLE_REAL_LIBEGL");
    if (!path || !*path) {
        path = access("/var/jb/lib/angle/libEGL.angle.dylib", R_OK) == 0
             ? "/var/jb/lib/angle/libEGL.angle.dylib"
             : "/var/jb/lib/angle/libEGL.dylib";
    }
    s_angle = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (!s_angle) {
        fprintf(stderr, "iosc_egl: dlopen ANGLE libEGL (%s) failed: %s\n", path, dlerror());
        abort();
    }
}
static void *sym(const char *n)
{
    ensure_angle();
    return dlsym(s_angle, n);
}
#define REAL(name) ((typeof(&name)) sym(#name))

/* IOSC_EGL_DEBUG=1 traces the shim's EGL interception (display/config/window path)
 * so the GSK-ngl-on-ANGLE bring-up is diagnosable on-device. */
static int egl_debug(void)
{
    static int v = -1;
    if (v < 0) v = getenv("IOSC_EGL_DEBUG") ? 1 : 0;
    return v;
}

/* Confirm the shim is actually loaded into the client (kgx/GTK), not just iosc. */
__attribute__((constructor)) static void iosc_egl_ctor(void)
{
    if (egl_debug())
        fprintf(stderr, "iosc_egl: shim loaded (pid=%d)\n", (int)getpid());
}

/* ---- wayland iosc_iosurface binding (one private queue per wl_display) ----- */

struct iosc_wl_state {
    struct wl_display     *display;
    struct wl_event_queue *queue;
    struct iosc_iosurface *factory;
    struct iosc_wl_state  *next;
};

static pthread_mutex_t s_state_lock = PTHREAD_MUTEX_INITIALIZER;
static struct iosc_wl_state *s_states;
static _Thread_local EGLint s_shim_error = EGL_SUCCESS;

static void reg_global(void *d, struct wl_registry *r, uint32_t name,
                       const char *iface, uint32_t ver)
{
    struct iosc_wl_state *state = d;
    if (!strcmp(iface, "iosc_iosurface")) {
        uint32_t bind_version = ver < 4 ? ver : 4;
        state->factory = wl_registry_bind(r, name, &iosc_iosurface_interface,
                                          bind_version);
        wl_proxy_set_queue((struct wl_proxy *)state->factory, state->queue);
    }
}
static void reg_remove(void *d, struct wl_registry *r, uint32_t n){ (void)d;(void)r;(void)n; }
static const struct wl_registry_listener reg_listener = { reg_global, reg_remove };

static struct iosc_wl_state *ensure_factory(struct wl_display *wl)
{
    if (!wl)
        return NULL;

    pthread_mutex_lock(&s_state_lock);
    for (struct iosc_wl_state *it = s_states; it; it = it->next) {
        if (it->display == wl) {
            pthread_mutex_unlock(&s_state_lock);
            return it->factory ? it : NULL;
        }
    }

    struct iosc_wl_state *state = calloc(1, sizeof(*state));
    if (!state) {
        pthread_mutex_unlock(&s_state_lock);
        return NULL;
    }
    state->display = wl;
    state->queue = wl_display_create_queue(wl);
    if (!state->queue) {
        free(state);
        pthread_mutex_unlock(&s_state_lock);
        return NULL;
    }
    struct wl_registry *reg = wl_display_get_registry(wl);
    wl_proxy_set_queue((struct wl_proxy *)reg, state->queue);
    wl_registry_add_listener(reg, &reg_listener, state);
    if (wl_display_roundtrip_queue(wl, state->queue) < 0 || !state->factory) {
        fprintf(stderr, "iosc_egl: compositor has no iosc_iosurface global\n");
        wl_registry_destroy(reg);
        wl_event_queue_destroy(state->queue);
        free(state);
        pthread_mutex_unlock(&s_state_lock);
        return NULL;
    }
    wl_registry_destroy(reg);
    state->next = s_states;
    s_states = state;
    pthread_mutex_unlock(&s_state_lock);
    fprintf(stderr, "iosc_egl: bound iosc_iosurface on wl_display=%p\n", (void *)wl);
    return state;
}

/* ---- window surface (the IOSurface swapchain) ----------------------------- */

struct iosc_egl_win;

/* One swapchain buffer, heap-allocated so it can outlive its slot: on
 * wl_egl_window resize the swapchain is rebuilt, but a buffer still attached
 * in iosc (busy) must live until its wl_buffer.release — and a wl_buffer's
 * listener data is fixed at creation, so the slot itself is the listener data. */
struct iosc_egl_buf {
    struct iosc_egl_win *win;
    IOSurfaceRef         ios;
    EGLSurface           pbuf;
    struct wl_buffer    *buf;
    int                  busy;     /* attached, awaiting wl_buffer.release */
    int                  retired;  /* slot replaced by resize; free on release */
    struct iosc_egl_buf *next;     /* link in the window's retired list */
};

struct iosc_egl_win {
    uint32_t              magic;
    struct wl_egl_window *ewin;    /* wl_egl_window_resize updates its fields */
    struct wl_surface    *surface;
    EGLDisplay            dpy;
    EGLConfig             cfg;
    struct iosc_wl_state *wl;
    int                   w, h;
    int                   cur;
    struct iosc_egl_buf  *bufs[IOSC_NBUF];
    struct iosc_egl_buf  *retired; /* busy buffers whose slot was replaced */
    struct iosc_egl_win  *registry_next;
};
/* Dynamic registry of live wrappers so window 33 cannot silently escape shim
 * ownership and later be forwarded to ANGLE as a fake native EGLSurface. */
static pthread_mutex_t s_win_lock = PTHREAD_MUTEX_INITIALIZER;
static struct iosc_egl_win *s_wins;
static struct iosc_egl_win *as_win(EGLSurface s)
{
    struct iosc_egl_win *found = NULL;
    pthread_mutex_lock(&s_win_lock);
    for (struct iosc_egl_win *it = s_wins; it; it = it->registry_next) {
        if (it == (struct iosc_egl_win *)s) {
            found = it;
            break;
        }
    }
    pthread_mutex_unlock(&s_win_lock);
    return found;
}
static void win_register(struct iosc_egl_win *w)
{
    pthread_mutex_lock(&s_win_lock);
    w->registry_next = s_wins;
    s_wins = w;
    pthread_mutex_unlock(&s_win_lock);
}
static void win_unregister(struct iosc_egl_win *w)
{
    pthread_mutex_lock(&s_win_lock);
    for (struct iosc_egl_win **p = &s_wins; *p; p = &(*p)->registry_next) {
        if (*p == w) {
            *p = w->registry_next;
            break;
        }
    }
    pthread_mutex_unlock(&s_win_lock);
}

static void cfnum(CFMutableDictionaryRef d, CFStringRef k, int32_t v)
{ CFNumberRef n = CFNumberCreate(0, kCFNumberSInt32Type, &v); CFDictionarySetValue(d, k, n); CFRelease(n); }

static IOSurfaceRef make_ios(int w, int h)
{
    size_t bpr = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, (size_t)w * 4);
    size_t al  = IOSurfaceAlignProperty(kIOSurfaceAllocSize, bpr * (size_t)h);
    CFMutableDictionaryRef d = CFDictionaryCreateMutable(0, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    cfnum(d, kIOSurfaceWidth, w); cfnum(d, kIOSurfaceHeight, h);
    cfnum(d, kIOSurfaceBytesPerElement, 4); cfnum(d, kIOSurfaceBytesPerRow, (int)bpr);
    cfnum(d, kIOSurfaceAllocSize, (int)al); cfnum(d, kIOSurfacePixelFormat, 0x42475241);
    IOSurfaceRef s = IOSurfaceCreate(d); CFRelease(d);
    return s;
}

static void buf_destroy(struct iosc_egl_buf *bb)
{
    if (bb->pbuf != EGL_NO_SURFACE) REAL(eglDestroySurface)(bb->win->dpy, bb->pbuf);
    if (bb->buf) wl_buffer_destroy(bb->buf);
    if (bb->ios) CFRelease(bb->ios);
    free(bb);
}

static void buf_release(void *data, struct wl_buffer *b)
{
    (void)b;
    struct iosc_egl_buf *bb = data;
    if (!bb->retired) {
        bb->busy = 0;
        return;
    }
    /* A resize replaced this buffer's slot; iosc is done with it now. */
    for (struct iosc_egl_buf **p = &bb->win->retired; *p; p = &(*p)->next)
        if (*p == bb) { *p = bb->next; break; }
    buf_destroy(bb);
}
static const struct wl_buffer_listener buf_listener = { buf_release };

/* Build a complete replacement swapchain before publishing any slot into the
 * window. Allocation is transactional: a failed resize keeps the old buffers
 * usable instead of leaving NULL entries that crash the next swap. */
static int win_alloc_bufs(struct iosc_egl_win *w, int width, int height,
                          struct iosc_egl_buf *out[IOSC_NBUF])
{
    const EGLint pa[] = {
        EGL_WIDTH, width, EGL_HEIGHT, height, EGL_IOSURFACE_PLANE_ANGLE, 0,
        EGL_TEXTURE_TARGET, EGL_TEXTURE_2D, EGL_TEXTURE_INTERNAL_FORMAT_ANGLE, GL_BGRA_EXT,
        EGL_TEXTURE_FORMAT, EGL_TEXTURE_RGBA, EGL_TEXTURE_TYPE_ANGLE, GL_UNSIGNED_BYTE, EGL_NONE };
    mach_port_t ports[IOSC_NBUF] = { MACH_PORT_NULL, MACH_PORT_NULL, MACH_PORT_NULL };
    memset(out, 0, sizeof(*out) * IOSC_NBUF);
    for (int i = 0; i < IOSC_NBUF; i++) {
        struct iosc_egl_buf *bb = calloc(1, sizeof(*bb));
        if (!bb)
            goto fail;
        bb->win = w;
        bb->ios = make_ios(width, height);
        if (!bb->ios) {
            free(bb);
            goto fail;
        }
        bb->pbuf = REAL(eglCreatePbufferFromClientBuffer)(w->dpy, EGL_IOSURFACE_ANGLE,
                        (EGLClientBuffer)bb->ios, w->cfg, pa);
        if (bb->pbuf == EGL_NO_SURFACE) {
            fprintf(stderr, "iosc_egl: pbuffer %d failed 0x%x\n", i, REAL(eglGetError)());
            buf_destroy(bb);
            goto fail;
        }
        ports[i] = IOSurfaceCreateMachPort(bb->ios);
        if (ports[i] == MACH_PORT_NULL) {
            buf_destroy(bb);
            goto fail;
        }
        bb->buf = iosc_iosurface_create_buffer(w->wl->factory, (uint32_t)ports[i], width, height,
                                               IOSC_IOSURFACE_FORMAT_BGRA8888_GL_ORIGIN);
        if (!bb->buf) {
            buf_destroy(bb);
            goto fail;
        }
        wl_proxy_set_queue((struct wl_proxy *)bb->buf, w->wl->queue);
        wl_buffer_add_listener(bb->buf, &buf_listener, bb);
        out[i] = bb;
    }
    /* The port is a one-shot handoff token: iosc extracts its own COPY_SEND right
     * while processing create_buffer. Roundtrip so that's done, then drop our send
     * right — otherwise each port pins its IOSurface in the kernel forever and every
     * destroyed window surface leaks IOSC_NBUF full-window IOSurfaces + port names. */
    if (wl_display_roundtrip_queue(w->wl->display, w->wl->queue) < 0)
        goto fail;
    for (int i = 0; i < IOSC_NBUF; i++)
        if (ports[i] != MACH_PORT_NULL)
            mach_port_deallocate(mach_task_self(), ports[i]);
    return 0;

fail:
    for (int i = 0; i < IOSC_NBUF; i++) {
        if (ports[i] != MACH_PORT_NULL)
            mach_port_deallocate(mach_task_self(), ports[i]);
        if (out[i]) {
            buf_destroy(out[i]);
            out[i] = NULL;
        }
    }
    return -1;
}

/* Resize contract (Mesa wayland-egl semantics): wl_egl_window_resize only
 * updates ewin->width/height; the EGL platform re-reads them at the next
 * buffer acquisition. Rebuild the swapchain when they changed. Buffers iosc
 * still holds are retired and freed on their wl_buffer.release; free ones go
 * now. Returns 1 if the swapchain was rebuilt (w->cur reset to 0). */
static int win_sync_size(struct iosc_egl_win *w)
{
    int nw = w->ewin->width, nh = w->ewin->height;
    if (nw <= 0) nw = 1; if (nh <= 0) nh = 1;
    if (nw == w->w && nh == w->h) return 0;
    struct iosc_egl_buf *replacement[IOSC_NBUF];
    if (win_alloc_bufs(w, nw, nh, replacement) != 0) {
        s_shim_error = EGL_BAD_ALLOC;
        fprintf(stderr, "iosc_egl: keeping %dx%d swapchain; resize to %dx%d failed\n",
                w->w, w->h, nw, nh);
        return -1;
    }
    for (int i = 0; i < IOSC_NBUF; i++) {
        struct iosc_egl_buf *bb = w->bufs[i];
        if (bb->busy) {
            bb->retired = 1;
            bb->next = w->retired;
            w->retired = bb;
        } else {
            buf_destroy(bb);
        }
        w->bufs[i] = replacement[i];
    }
    w->w = nw; w->h = nh; w->cur = 0;
    if (egl_debug())
        fprintf(stderr, "iosc_egl: window surface resized to %dx%d\n", w->w, w->h);
    return 1;
}

static int win_find_free_buffer(struct iosc_egl_win *w, int start)
{
    for (int n = 0; n < IOSC_NBUF; n++) {
        int idx = (start + n) % IOSC_NBUF;
        if (!w->bufs[idx]->busy)
            return idx;
    }
    return -1;
}

static int win_next_buffer(struct iosc_egl_win *w, int start)
{
    int idx;

    wl_display_dispatch_queue_pending(w->wl->display, w->wl->queue);
    idx = win_find_free_buffer(w, start);
    if (idx >= 0)
        return idx;

    /* All buffers are still attached. Block only for real swapchain backpressure,
     * not because the arbitrary next slot is busy while another slot is free. */
    do {
        if (wl_display_roundtrip_queue(w->wl->display, w->wl->queue) < 0)
            return -1;
        idx = win_find_free_buffer(w, start);
    } while (idx < 0);

    return idx;
}

/* ---- intercepted EGL entrypoints ------------------------------------------ */

/* Create the ANGLE-Metal EGLDisplay EXACTLY as iosc/xios_egl.c does — the one
 * proven-good path: the EXT entrypoint resolved via eglGetProcAddress + EGLint
 * ANGLE-type attribs + EGL_DEFAULT_DISPLAY. NB: ANGLE's CORE eglGetPlatformDisplay
 * (EGL 1.5, dlsym'd) returns NO_DISPLAY with err=SUCCESS for the ANGLE platform on
 * this build — only the EXT variant actually constructs the Metal display. The
 * client's wl_display is recorded separately per thread for later wl_egl_window
 * binding; it is NEVER passed to ANGLE as the native display. */
static EGLDisplay angle_metal_display(void)
{
    /* An EGLDisplay is a singleton per (platform, native_display, attribs), so
     * caching the successful one is plain EGL semantics and stops every
     * eglGetDisplay call from re-entering ANGLE's Metal bring-up. Failures are
     * not cached, so a caller may retry.
     *
     * NOTE: this returns EGL_NO_DISPLAY (with err EGL_SUCCESS, so there is
     * nothing to report) inside a process that ALREADY owns an ANGLE Metal
     * display created outside this shim -- kwin_wayland is the case in practice:
     * its compositing backend makes one directly, and the Qt Wayland QPA then
     * asks us for a second. Qt treats that as "EGL not available" and drops its
     * QtQuick scenegraph to software for that process. Harmless there (it is
     * kwin's internal QtQuick, not compositing, and not plasmashell), but it is
     * why that warning appears in a session log while the desktop still renders
     * through ANGLE. Verified: plasmashell launched on its own gets a display
     * and the threaded render loop. */
    static EGLDisplay cached = EGL_NO_DISPLAY;
    if (cached != EGL_NO_DISPLAY) {
        return cached;
    }

    typedef EGLDisplay (*getpd_ext_fn)(EGLenum, void *, const EGLint *);
    getpd_ext_fn get = (getpd_ext_fn)REAL(eglGetProcAddress)("eglGetPlatformDisplayEXT");
    if (!get) {
        if (egl_debug()) fprintf(stderr, "iosc_egl: real eglGetPlatformDisplayEXT missing\n");
        return EGL_NO_DISPLAY;
    }
    const EGLint a[] = { EGL_PLATFORM_ANGLE_TYPE_ANGLE, EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE, EGL_NONE };
    EGLDisplay dpy = get(EGL_PLATFORM_ANGLE_ANGLE, EGL_DEFAULT_DISPLAY, a);
    if (egl_debug())
        fprintf(stderr, "iosc_egl: ANGLE Metal display = %p (err 0x%x)\n", dpy, REAL(eglGetError)());
    cached = dpy;
    return dpy;
}

EGLDisplay eglGetPlatformDisplay(EGLenum platform, void *native_display, const EGLAttrib *attrs)
{
    if (platform == EGL_PLATFORM_WAYLAND_KHR || platform == EGL_PLATFORM_WAYLAND_EXT) {
        if (egl_debug()) fprintf(stderr, "iosc_egl: GetPlatformDisplay(WAYLAND)\n");
        return angle_metal_display();
    }
    return REAL(eglGetPlatformDisplay)(platform, native_display, attrs);
}
EGLDisplay eglGetPlatformDisplayEXT(EGLenum platform, void *native_display, const EGLint *attrs)
{
    if (platform == EGL_PLATFORM_WAYLAND_KHR || platform == EGL_PLATFORM_WAYLAND_EXT) {
        if (egl_debug()) fprintf(stderr, "iosc_egl: GetPlatformDisplayEXT(WAYLAND)\n");
        return angle_metal_display();
    }
    return REAL(eglGetPlatformDisplayEXT)(platform, native_display, attrs);
}
EGLDisplay eglGetDisplay(EGLNativeDisplayType native)
{
    /* This ANGLE header also defines EGLNativeDisplayType as int. A Wayland
     * pointer cannot safely reach this legacy entry point on arm64. */
    if (native != EGL_DEFAULT_DISPLAY) {
        s_shim_error = EGL_BAD_PARAMETER;
        fprintf(stderr, "iosc_egl: eglGetDisplay cannot carry a Wayland pointer; "
                        "use eglGetPlatformDisplay*\n");
        return EGL_NO_DISPLAY;
    }
    return REAL(eglGetDisplay)(native);
}

static EGLSurface make_window(EGLDisplay dpy, EGLConfig cfg, struct wl_egl_window *ewin)
{
    if (!ewin) {
        s_shim_error = EGL_BAD_NATIVE_WINDOW;
        return EGL_NO_SURFACE;
    }
    /* Qt may initialize EGL on its GUI thread and create/swap the window surface
     * on a render thread. The wl_surface itself is the authoritative connection;
     * deriving its owner here avoids a thread-local display guess and also keeps
     * multiple Wayland connections in one process correctly separated. */
    struct wl_display *display =
        wl_proxy_get_display((struct wl_proxy *)ewin->surface);
    struct iosc_wl_state *wl = ensure_factory(display);
    if (!wl) {
        s_shim_error = EGL_BAD_DISPLAY;
        return EGL_NO_SURFACE;
    }
    struct iosc_egl_win *w = calloc(1, sizeof(*w));
    if (!w) {
        s_shim_error = EGL_BAD_ALLOC;
        return EGL_NO_SURFACE;
    }
    w->magic = WIN_MAGIC;
    w->ewin = ewin;
    w->surface = ewin->surface;       /* the wl_surface (last member of wl_egl_window) */
    w->dpy = dpy;
    w->cfg = cfg;
    w->wl = wl;
    w->w = ewin->width; w->h = ewin->height;
    if (w->w <= 0) w->w = 1; if (w->h <= 0) w->h = 1;

    if (win_alloc_bufs(w, w->w, w->h, w->bufs) != 0) {
        s_shim_error = EGL_BAD_ALLOC;
        free(w);
        return EGL_NO_SURFACE;
    }
    win_register(w);
    fprintf(stderr, "iosc_egl: window surface %dx%d (%d IOSurface buffers)\n", w->w, w->h, IOSC_NBUF);
    return (EGLSurface)w;
}
/* QtWayland uses the core entry point rather than the platform variants. ANGLE's
 * Apple/iOS eglplatform.h defines EGLNativeWindowType as void *, so the published
 * ABI carries the wl_egl_window pointer at full width and can use the same
 * IOSurface swapchain path. Keep a defensive low-address check for a client built
 * against an incompatible header where EGLNativeWindowType was a 32-bit integer;
 * that pointer is already irrecoverably truncated and must not be dereferenced. */
EGLSurface eglCreateWindowSurface(EGLDisplay dpy, EGLConfig cfg,
                                  EGLNativeWindowType win, const EGLint *attrs)
{
    (void)attrs;
    const uintptr_t v = (uintptr_t)win;
    if (v <= 0xffffffffu) {
        s_shim_error = EGL_BAD_NATIVE_WINDOW;
        fprintf(stderr, "iosc_egl: eglCreateWindowSurface got 0x%llx, too small to be a "
                        "wl_egl_window pointer (truncated EGLNativeWindowType?); "
                        "use eglCreatePlatformWindowSurface*\n",
                (unsigned long long)v);
        return EGL_NO_SURFACE;
    }
    return make_window(dpy, cfg, (struct wl_egl_window *)win);
}
EGLSurface eglCreatePlatformWindowSurface(EGLDisplay dpy, EGLConfig cfg, void *win, const EGLAttrib *attrs)
{ (void)attrs; return make_window(dpy, cfg, (struct wl_egl_window *)win); }
EGLSurface eglCreatePlatformWindowSurfaceEXT(EGLDisplay dpy, EGLConfig cfg, void *win, const EGLint *attrs)
{ (void)attrs; return make_window(dpy, cfg, (struct wl_egl_window *)win); }

EGLBoolean eglMakeCurrent(EGLDisplay dpy, EGLSurface draw, EGLSurface read, EGLContext ctx)
{
    struct iosc_egl_win *w = as_win(draw);
    if (w) {
        if (win_sync_size(w) < 0)
            return EGL_FALSE;
        struct iosc_egl_buf *bb = w->bufs[w->cur];
        EGLSurface pb = bb ? bb->pbuf : EGL_NO_SURFACE;
        return REAL(eglMakeCurrent)(dpy, pb, pb, ctx);
    }
    return REAL(eglMakeCurrent)(dpy, draw, read, ctx);
}

/* Which framebuffer the client had bound when it swapped. Non-zero means the
 * client rendered into its own FBO, so nothing reached the pbuffer's IOSurface. */
static GLint cur_draw_fbo(void)
{
    GLint fbo = -1;
    glGetIntegerv(GL_FRAMEBUFFER_BINDING, &fbo);
    return fbo;
}

EGLBoolean eglSwapBuffers(EGLDisplay dpy, EGLSurface surf)
{
    struct iosc_egl_win *w = as_win(surf);
    if (!w) return REAL(eglSwapBuffers)(dpy, surf);

    int i = w->cur;
    struct iosc_egl_buf *bb = w->bufs[i];
    if (!bb || !bb->buf)
        return EGL_FALSE;

    /* Production path: pass an MTLSharedEvent acquire fence with this buffer and
     * let iosc enqueue a GPU wait before sampling. A CPU-side completion barrier
     * exists only behind IOSC_ALLOW_CPU_SYNC_DIAGNOSTIC for narrow bring-up. */
    int asynchronous = 0;
    if (wl_proxy_get_version((struct wl_proxy *)w->wl->factory) >= 4) {
        const void *token = NULL;
        size_t token_size = 0;
        uint64_t event_value = 0;
        if (xios_metal_sync_signal(dpy, &token, &token_size, &event_value)) {
            struct wl_array handle;
            handle.size = token_size;
            handle.alloc = token_size;
            handle.data = (void *)token;
            iosc_iosurface_set_acquire_fence_token(
                w->wl->factory, bb->buf, &handle,
                (uint32_t)(event_value & 0xffffffffu),
                (uint32_t)(event_value >> 32));
            asynchronous = 1;
        }
    }
    if (!asynchronous) {
        const char *diagnostic = getenv("IOSC_ALLOW_CPU_SYNC_DIAGNOSTIC");
        int allow_cpu_sync = diagnostic && *diagnostic &&
                             strcmp(diagnostic, "0") != 0 &&
                             strcasecmp(diagnostic, "false") != 0 &&
                             strcasecmp(diagnostic, "no") != 0;
        if (!allow_cpu_sync) {
            static int reported;
            if (!reported) {
                reported = 1;
                fprintf(stderr,
                        "iosc_egl: cross-process GPU acquire fence unavailable; "
                        "refusing an unfenced swap\n");
            }
            return EGL_FALSE;
        }
        static int warned;
        if (!warned) {
            warned = 1;
            fprintf(stderr,
                    "iosc_egl: IOSC_ALLOW_CPU_SYNC_DIAGNOSTIC=1; "
                    "using a CPU-side completion barrier\n");
        }
        EGLSync (*mk)(EGLDisplay, EGLenum, const EGLAttrib *) = REAL(eglCreateSync);
        EGLint (*fwait)(EGLDisplay, EGLSync, EGLint, EGLTime) =
            REAL(eglClientWaitSync);
        EGLBoolean (*del)(EGLDisplay, EGLSync) = REAL(eglDestroySync);
        EGLSync fence =
            (mk && fwait && del) ? mk(dpy, EGL_SYNC_FENCE, NULL) : EGL_NO_SYNC;
        if (fence != EGL_NO_SYNC) {
            glFlush();
            fwait(dpy, fence, EGL_SYNC_FLUSH_COMMANDS_BIT, EGL_FOREVER);
            del(dpy, fence);
        } else {
            glFinish();
        }
    }
    /* IOSC_EGL_DEBUG: sample the IOSurface right after the fence, i.e. at the exact
     * moment the client claims the frame is done. All-black here means the client's
     * GL never reached this IOSurface, which separates a client that drew nothing
     * from a compositor that lost the frame. */
    if (egl_debug()) {
        static unsigned long swapN;
        int nonblack = 0, sampled = 0;
        unsigned centre = 0;
        if (IOSurfaceLock(bb->ios, 0x1 /* kIOSurfaceLockReadOnly */, NULL) == 0) {
            const uint8_t *base = (const uint8_t *)IOSurfaceGetBaseAddress(bb->ios);
            size_t stride = IOSurfaceGetBytesPerRow(bb->ios);
            if (base) {
                for (int y = 0; y < w->h; y += 16) {
                    const uint8_t *row = base + (size_t)y * stride;
                    for (int x = 0; x < w->w; x += 16) {
                        const uint8_t *px = row + (size_t)x * 4;
                        if (px[0] | px[1] | px[2]) nonblack++;
                        sampled++;
                    }
                }
                centre = *(const uint32_t *)(base + (size_t)(w->h / 2) * stride + (size_t)(w->w / 2) * 4);
            }
            IOSurfaceUnlock(bb->ios, 0x1, NULL);
        }
        fprintf(stderr, "iosc_egl: swap #%lu buf=%d %dx%d nonblack=%d/%d centre=0x%08x fbo=%d\n",
                swapN++, i, w->w, w->h, nonblack, sampled, centre, (int)cur_draw_fbo());
    }
    wl_surface_attach(w->surface, bb->buf, 0, 0);
    /* Damage in BUFFER coordinates when the compositor supports it (wl_surface v4+).
     * wl_surface.damage is in surface-local coordinates, so the compositor has to
     * map it through buffer_scale and any wp_viewport the toolkit set. Qt sets a
     * viewport on these surfaces, and a damage rect expressed in buffer pixels is
     * not the same rectangle in surface coordinates -- getting that conversion
     * wrong yields empty damage, which reads downstream as "the client committed
     * nothing" even though a full frame was rendered. damage_buffer says exactly
     * what we mean: the whole buffer changed. */
    {
        const uint32_t sv = wl_proxy_get_version((struct wl_proxy *)w->surface);
        static int logged;
        if (sv >= WL_SURFACE_DAMAGE_BUFFER_SINCE_VERSION) {
            wl_surface_damage_buffer(w->surface, 0, 0, w->w, w->h);
        } else {
            wl_surface_damage(w->surface, 0, 0, w->w, w->h);
        }
        if (egl_debug() && !logged) {
            logged = 1;
            fprintf(stderr, "iosc_egl: damage path=%s (wl_surface v%u)\n",
                    sv >= WL_SURFACE_DAMAGE_BUFFER_SINCE_VERSION ? "damage_buffer" : "damage", sv);
        }
    }
    wl_surface_commit(w->surface);
    bb->busy = 1;
    wl_display_flush(w->wl->display);

    /* Rotate to any released buffer. The old path waited on exactly cur+1, which
     * could stall even when another swapchain buffer had already been released. */
    int next = win_next_buffer(w, (i + 1) % IOSC_NBUF);
    if (next < 0)
        return EGL_FALSE;
    w->cur = next;

    EGLContext ctx = REAL(eglGetCurrentContext)();
    bb = w->bufs[w->cur];
    EGLSurface pb = bb ? bb->pbuf : EGL_NO_SURFACE;
    REAL(eglMakeCurrent)(dpy, pb, pb, ctx);  /* next frame renders into the new buffer */
    return EGL_TRUE;
}

EGLBoolean eglQuerySurface(EGLDisplay dpy, EGLSurface surf, EGLint attr, EGLint *value)
{
    struct iosc_egl_win *w = as_win(surf);
    if (w) {
        if (attr == EGL_WIDTH)  { *value = w->w; return EGL_TRUE; }
        if (attr == EGL_HEIGHT) { *value = w->h; return EGL_TRUE; }
        struct iosc_egl_buf *bb = w->bufs[w->cur];
        return REAL(eglQuerySurface)(dpy, bb ? bb->pbuf : EGL_NO_SURFACE, attr, value);
    }
    return REAL(eglQuerySurface)(dpy, surf, attr, value);
}
EGLBoolean eglDestroySurface(EGLDisplay dpy, EGLSurface surf)
{
    struct iosc_egl_win *w = as_win(surf);
    if (!w) return REAL(eglDestroySurface)(dpy, surf);
    win_unregister(w);
    for (int i = 0; i < IOSC_NBUF; i++)
        if (w->bufs[i])
            buf_destroy(w->bufs[i]);
    while (w->retired) {
        struct iosc_egl_buf *next = w->retired->next;
        buf_destroy(w->retired);
        w->retired = next;
    }
    free(w);
    return EGL_TRUE;
}
EGLBoolean eglSwapInterval(EGLDisplay dpy, EGLint interval)
{ (void)dpy; (void)interval; return EGL_TRUE; }  /* iosc drives present timing */

/* Force a GLES >= 3 context. GTK4's GskNglRenderer needs ES 3.0 and GskGLRenderer
 * needs half-float vertex data (an ES3 feature); GDK otherwise requests ES 2.0 and
 * both GL renderers fail to realize (falling back to cairo). ANGLE-Metal supports
 * ES 3.0, so bump the requested version. (EGL_CONTEXT_CLIENT_VERSION ==
 * EGL_CONTEXT_MAJOR_VERSION == 0x3098.) */
EGLContext eglCreateContext(EGLDisplay d, EGLConfig c, EGLContext share, const EGLint *attrs)
{
    EGLint patched[40]; int n = 0, have_major = 0;
    if (attrs) {
        for (int i = 0; attrs[i] != EGL_NONE && n < 36; i += 2) {
            EGLint k = attrs[i], v = attrs[i + 1];
            if (k == EGL_CONTEXT_MAJOR_VERSION) { if (v < 3) v = 3; have_major = 1; }
            patched[n++] = k; patched[n++] = v;
        }
    }
    if (!have_major) { patched[n++] = EGL_CONTEXT_MAJOR_VERSION; patched[n++] = 3; }
    patched[n] = EGL_NONE;
    return REAL(eglCreateContext)(d, c, share, patched);
}

/* eglGetProcAddress: hand out our intercepts; forward the rest to ANGLE. */
__eglMustCastToProperFunctionPointerType eglGetProcAddress(const char *name)
{
    if (!strcmp(name, "eglGetPlatformDisplay"))            return (void *)eglGetPlatformDisplay;
    if (!strcmp(name, "eglGetPlatformDisplayEXT"))         return (void *)eglGetPlatformDisplayEXT;
    if (!strcmp(name, "eglCreateWindowSurface"))           return (void *)eglCreateWindowSurface;
    if (!strcmp(name, "eglCreatePlatformWindowSurface"))   return (void *)eglCreatePlatformWindowSurface;
    if (!strcmp(name, "eglCreatePlatformWindowSurfaceEXT"))return (void *)eglCreatePlatformWindowSurfaceEXT;
    if (!strcmp(name, "eglCreateContext"))                 return (void *)eglCreateContext;
    if (!strcmp(name, "eglMakeCurrent"))                   return (void *)eglMakeCurrent;
    if (!strcmp(name, "eglSwapBuffers"))                   return (void *)eglSwapBuffers;
    if (!strcmp(name, "eglQuerySurface"))                  return (void *)eglQuerySurface;
    if (!strcmp(name, "eglDestroySurface"))                return (void *)eglDestroySurface;
    if (!strcmp(name, "eglSwapInterval"))                  return (void *)eglSwapInterval;
    /* config + client-extension intercepts too, in case epoxy resolves these core
     * calls via eglGetProcAddress rather than direct dlsym (the P0.1 fix depends on
     * both being reached). */
    if (!strcmp(name, "eglQueryString"))                   return (void *)eglQueryString;
    if (!strcmp(name, "eglChooseConfig"))                  return (void *)eglChooseConfig;
    if (!strcmp(name, "eglGetConfigAttrib"))               return (void *)eglGetConfigAttrib;
    if (!strcmp(name, "eglInitialize"))                    return (void *)eglInitialize;
    return REAL(eglGetProcAddress)(name);
}

/* ---- pure forwarders (everything else GDK/epoxy resolves) ----------------- */

EGLBoolean eglInitialize(EGLDisplay d, EGLint *a, EGLint *b)
{
    EGLBoolean r = REAL(eglInitialize)(d, a, b);
    if (egl_debug())
        fprintf(stderr, "iosc_egl: eglInitialize(%p) -> ok=%d ver=%d.%d err=0x%x\n",
                d, (int)r, a ? *a : -1, b ? *b : -1, REAL(eglGetError)());
    return r;
}
EGLBoolean eglTerminate(EGLDisplay d){ return REAL(eglTerminate)(d); }
EGLint eglGetError(void)
{
    if (s_shim_error != EGL_SUCCESS) {
        EGLint error = s_shim_error;
        s_shim_error = EGL_SUCCESS;
        return error;
    }
    return REAL(eglGetError)();
}

/* GDK-wayland decides whether it may use eglGetPlatformDisplay(EGL_PLATFORM_WAYLAND)
 * by first checking the EGL CLIENT extension string (eglQueryString(EGL_NO_DISPLAY,
 * EGL_EXTENSIONS)) for EGL_KHR/EXT_platform_wayland. ANGLE has no Wayland platform so
 * it never advertises those — GDK bails with "Failed to create EGL display" BEFORE it
 * ever reaches our eglGetPlatformDisplay remap (which is why no shim display log
 * appears). Inject the platform-wayland client extensions so GDK proceeds to
 * eglGetPlatformDisplay(WAYLAND), which the shim then remaps to ANGLE Metal. */
const char *eglQueryString(EGLDisplay d, EGLint n)
{
    if (d == EGL_NO_DISPLAY && n == EGL_EXTENSIONS) {
        /* QtWayland probes client extensions before creating the display. Do not
         * forward that EGL_NO_DISPLAY query into ANGLE: on iOS this can leave the
         * later ANGLE Metal platform display creation returning EGL_NO_DISPLAY.
         * The shim only needs to advertise enough client-side platform support for
         * toolkits to proceed to eglGetPlatformDisplay*(WAYLAND), which we remap. */
        static const char exts[] =
            "EGL_EXT_client_extensions "
            "EGL_EXT_platform_base "
            "EGL_KHR_platform_wayland "
            "EGL_EXT_platform_wayland ";
        if (egl_debug())
            fprintf(stderr, "iosc_egl: client EGL_EXTENSIONS (+platform_wayland): %s\n", exts);
        return exts;
    }
    const char *real = REAL(eglQueryString)(d, n);
    return real;
}
EGLBoolean eglGetConfigs(EGLDisplay d, EGLConfig *c, EGLint n, EGLint *m){ return REAL(eglGetConfigs)(d,c,n,m); }

/* GDK's GskNglRenderer selects an EGL config for an on-screen window, so it filters
 * for EGL_WINDOW_BIT + (usually) the ES3 renderable bit. On our HEADLESS ANGLE-Metal
 * display neither is offered on the matching configs: there is no native window, so
 * configs carry EGL_PBUFFER_BIT (not EGL_WINDOW_BIT), and EGL_RENDERABLE_TYPE
 * advertises only ES1|ES2 even though ES3 works. So GDK's eglChooseConfig (or its
 * eglGetConfigs+eglGetConfigAttrib manual filter) matches nothing -> "No EGL
 * configuration available". The shim backs every "window" with an IOSurface pbuffer,
 * so we bridge BOTH mismatches symmetrically: on the way IN (eglChooseConfig) rewrite
 * the request so ANGLE's real pbuffer/ES2 configs match; on the way OUT
 * (eglGetConfigAttrib) report WINDOW_BIT + ES3 so GDK believes the config is a
 * window-capable ES3 config. Set IOSC_EGL_DEBUG=1 to log what GDK asks for and how
 * many configs match (the diagnostic for the on-device config-search loop). */
#define EGL_ES3_BIT 0x0040  /* EGL_OPENGL_ES3_BIT_KHR */

EGLBoolean eglChooseConfig(EGLDisplay d, const EGLint *a, EGLConfig *c, EGLint n, EGLint *m)
{
    EGLint p[64]; int k = 0;
    EGLint want_surf = -1, want_rend = -1;
    if (a) for (int i = 0; a[i] != EGL_NONE && k < 60; i += 2) {
        EGLint key = a[i], val = a[i + 1];
        if (key == EGL_RENDERABLE_TYPE) {
            want_rend = val;
            if (val & EGL_ES3_BIT)                 /* ES3 -> ES2 (ANGLE mislabels) */
                val = (val & ~EGL_ES3_BIT) | EGL_OPENGL_ES2_BIT;
        }
        if (key == EGL_SURFACE_TYPE) {
            want_surf = val;
            if (val & EGL_WINDOW_BIT)              /* WINDOW -> PBUFFER (headless: no window configs) */
                val = (val & ~EGL_WINDOW_BIT) | EGL_PBUFFER_BIT;
        }
        p[k++] = key; p[k++] = val;
    }
    p[k] = EGL_NONE;
    EGLBoolean r = REAL(eglChooseConfig)(d, p, c, n, m);
    if (egl_debug()) {
        fprintf(stderr, "iosc_egl: eglChooseConfig surface_type=0x%x renderable=0x%x "
                        "-> ok=%d matched=%d; full request:",
                want_surf, want_rend, (int)r, (r && m) ? *m : -1);
        if (a) for (int i = 0; a[i] != EGL_NONE; i += 2)
            fprintf(stderr, " 0x%x=0x%x", a[i], a[i + 1]);
        fprintf(stderr, "\n");
    }
    return r;
}
EGLBoolean eglGetConfigAttrib(EGLDisplay d, EGLConfig c, EGLint a, EGLint *v)
{
    EGLBoolean r = REAL(eglGetConfigAttrib)(d, c, a, v);
    if (r && a == EGL_RENDERABLE_TYPE) *v |= EGL_ES3_BIT;    /* ANGLE supports ES3 here     */
    if (r && a == EGL_SURFACE_TYPE)    *v |= EGL_WINDOW_BIT; /* shim backs windows w/ pbuffer */
    /* The shim's swap interval is always zero and its three-buffer IOSurface
     * queue provides backpressure. Report that actual contract instead of
     * ANGLE's headless-pbuffer minimum of one; QtWayland otherwise serializes
     * its render loop and warns that subsurface rendering can freeze. */
    if (r && a == EGL_MIN_SWAP_INTERVAL) *v = 0;
    return r;
}
EGLBoolean eglDestroyContext(EGLDisplay d, EGLContext c){ return REAL(eglDestroyContext)(d,c); }
EGLContext eglGetCurrentContext(void){ return REAL(eglGetCurrentContext)(); }
EGLSurface eglGetCurrentSurface(EGLint r){ return REAL(eglGetCurrentSurface)(r); }
EGLDisplay eglGetCurrentDisplay(void){ return REAL(eglGetCurrentDisplay)(); }
EGLBoolean eglQueryContext(EGLDisplay d, EGLContext c, EGLint a, EGLint *v){ return REAL(eglQueryContext)(d,c,a,v); }
EGLSurface eglCreatePbufferSurface(EGLDisplay d, EGLConfig c, const EGLint *a){ return REAL(eglCreatePbufferSurface)(d,c,a); }
EGLSurface eglCreatePixmapSurface(EGLDisplay d, EGLConfig c, EGLNativePixmapType p, const EGLint *a){ return REAL(eglCreatePixmapSurface)(d,c,p,a); }
EGLSurface eglCreatePbufferFromClientBuffer(EGLDisplay d, EGLenum t, EGLClientBuffer b, EGLConfig c, const EGLint *a){ return REAL(eglCreatePbufferFromClientBuffer)(d,t,b,c,a); }
EGLBoolean eglBindAPI(EGLenum a){ return REAL(eglBindAPI)(a); }
EGLenum    eglQueryAPI(void){ return REAL(eglQueryAPI)(); }
EGLBoolean eglWaitClient(void){ return REAL(eglWaitClient)(); }
EGLBoolean eglWaitGL(void){ return REAL(eglWaitGL)(); }
EGLBoolean eglWaitNative(EGLint e){ return REAL(eglWaitNative)(e); }
EGLBoolean eglReleaseThread(void){ return REAL(eglReleaseThread)(); }
EGLBoolean eglBindTexImage(EGLDisplay d, EGLSurface s, EGLint b){ return REAL(eglBindTexImage)(d,s,b); }
EGLBoolean eglReleaseTexImage(EGLDisplay d, EGLSurface s, EGLint b){ return REAL(eglReleaseTexImage)(d,s,b); }
EGLImage   eglCreateImage(EGLDisplay d, EGLContext c, EGLenum t, EGLClientBuffer b, const EGLAttrib *a){ return REAL(eglCreateImage)(d,c,t,b,a); }
EGLBoolean eglDestroyImage(EGLDisplay d, EGLImage i){ return REAL(eglDestroyImage)(d,i); }
EGLImageKHR eglCreateImageKHR(EGLDisplay d, EGLContext c, EGLenum t, EGLClientBuffer b, const EGLint *a){ return REAL(eglCreateImageKHR)(d,c,t,b,a); }
EGLBoolean eglDestroyImageKHR(EGLDisplay d, EGLImageKHR i){ return REAL(eglDestroyImageKHR)(d,i); }
EGLSync    eglCreateSync(EGLDisplay d, EGLenum t, const EGLAttrib *a){ return REAL(eglCreateSync)(d,t,a); }
EGLBoolean eglDestroySync(EGLDisplay d, EGLSync s){ return REAL(eglDestroySync)(d,s); }
EGLint     eglClientWaitSync(EGLDisplay d, EGLSync s, EGLint f, EGLTime t){ return REAL(eglClientWaitSync)(d,s,f,t); }

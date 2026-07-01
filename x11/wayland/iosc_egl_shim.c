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
 *   - eglSwapBuffers(window)                -> glFinish, hand pbuf[cur]'s IOSurface
 *     to iosc (create_buffer + attach + commit), rotate, bind the next pbuffer.
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

#include <CoreFoundation/CoreFoundation.h>
#include <IOSurface/IOSurfaceRef.h>
#include <mach/mach.h>

#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

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
#define IOSC_MAX_WINS 32       /* live wl_egl_window wrappers tracked at once */
#define WIN_MAGIC 0x494f5357u  /* 'IOSW' */

/* ---- real ANGLE libEGL ---------------------------------------------------- */

static void *s_angle;
static void  ensure_angle(void)
{
    if (s_angle) return;
    /* The real ANGLE libEGL. Default to the deb's path; override via env when the
     * shim is installed AS /var/jb/lib/angle/libEGL.dylib (so it can't dlopen
     * itself) — point ANGLE_REAL_LIBEGL at the renamed real library. */
    const char *path = getenv("ANGLE_REAL_LIBEGL");
    if (!path || !*path) path = "/var/jb/lib/angle/libEGL.dylib";
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

/* ---- wayland iosc_iosurface binding (private queue) ----------------------- */

static struct wl_display      *g_wl;
static struct wl_event_queue  *g_queue;
static struct iosc_iosurface  *g_factory;

static void reg_global(void *d, struct wl_registry *r, uint32_t name,
                       const char *iface, uint32_t ver)
{
    (void)d; (void)ver;
    if (!strcmp(iface, "iosc_iosurface")) {
        g_factory = wl_registry_bind(r, name, &iosc_iosurface_interface, 1);
        wl_proxy_set_queue((struct wl_proxy *)g_factory, g_queue);
    }
}
static void reg_remove(void *d, struct wl_registry *r, uint32_t n){ (void)d;(void)r;(void)n; }
static const struct wl_registry_listener reg_listener = { reg_global, reg_remove };

static int ensure_factory(struct wl_display *wl)
{
    if (g_factory) return 0;
    g_wl = wl;
    g_queue = wl_display_create_queue(wl);
    struct wl_registry *reg = wl_display_get_registry(wl);
    wl_proxy_set_queue((struct wl_proxy *)reg, g_queue);
    wl_registry_add_listener(reg, &reg_listener, NULL);
    wl_display_roundtrip_queue(wl, g_queue);
    if (!g_factory) {
        fprintf(stderr, "iosc_egl: compositor has no iosc_iosurface global\n");
        return -1;
    }
    fprintf(stderr, "iosc_egl: bound iosc_iosurface\n");
    return 0;
}

/* ---- window surface (the IOSurface swapchain) ----------------------------- */

struct iosc_egl_win {
    uint32_t            magic;
    struct wl_surface  *surface;
    int                 w, h;
    int                 cur;
    IOSurfaceRef        ios[IOSC_NBUF];
    EGLSurface          pbuf[IOSC_NBUF];
    struct wl_buffer   *buf[IOSC_NBUF];
    int                 busy[IOSC_NBUF];   /* attached, awaiting wl_buffer.release */
};
/* registry of live wrappers so we can tell our handles from real EGLSurfaces. */
static struct iosc_egl_win *s_wins[IOSC_MAX_WINS];
static struct iosc_egl_win *as_win(EGLSurface s)
{
    for (int i = 0; i < IOSC_MAX_WINS; i++) if (s_wins[i] == (struct iosc_egl_win *)s) return s_wins[i];
    return NULL;
}
static void win_register(struct iosc_egl_win *w)
{ for (int i = 0; i < IOSC_MAX_WINS; i++) if (!s_wins[i]) { s_wins[i] = w; return; } }
static void win_unregister(struct iosc_egl_win *w)
{ for (int i = 0; i < IOSC_MAX_WINS; i++) if (s_wins[i] == w) { s_wins[i] = NULL; return; } }

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

static void buf_release(void *data, struct wl_buffer *b)
{
    (void)b;
    int *busy = data;
    *busy = 0;
}
static const struct wl_buffer_listener buf_listener = { buf_release };

/* ---- intercepted EGL entrypoints ------------------------------------------ */

EGLDisplay eglGetPlatformDisplay(EGLenum platform, void *native_display, const EGLAttrib *attrs)
{
    (void)attrs;
    if (platform == EGL_PLATFORM_WAYLAND_KHR || platform == EGL_PLATFORM_WAYLAND_EXT) {
        g_wl = (struct wl_display *)native_display;   /* remember the client's wl_display */
        const EGLAttrib a[] = { EGL_PLATFORM_ANGLE_TYPE_ANGLE, EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE, EGL_NONE };
        fprintf(stderr, "iosc_egl: GetPlatformDisplay(WAYLAND) -> ANGLE Metal\n");
        return REAL(eglGetPlatformDisplay)(EGL_PLATFORM_ANGLE_ANGLE, EGL_DEFAULT_DISPLAY, a);
    }
    return REAL(eglGetPlatformDisplay)(platform, native_display, attrs);
}
EGLDisplay eglGetPlatformDisplayEXT(EGLenum platform, void *native_display, const EGLint *attrs)
{
    if (platform == EGL_PLATFORM_WAYLAND_KHR || platform == EGL_PLATFORM_WAYLAND_EXT) {
        g_wl = (struct wl_display *)native_display;
        const EGLint a[] = { EGL_PLATFORM_ANGLE_TYPE_ANGLE, EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE, EGL_NONE };
        return REAL(eglGetPlatformDisplayEXT)(EGL_PLATFORM_ANGLE_ANGLE, EGL_DEFAULT_DISPLAY, a);
    }
    return REAL(eglGetPlatformDisplayEXT)(platform, native_display, attrs);
}
EGLDisplay eglGetDisplay(EGLNativeDisplayType native)
{
    /* GDK may use eglGetDisplay(wl_display). Treat a non-default arg as wayland. */
    if (native != EGL_DEFAULT_DISPLAY) {
        g_wl = (struct wl_display *)native;
        const EGLAttrib a[] = { EGL_PLATFORM_ANGLE_TYPE_ANGLE, EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE, EGL_NONE };
        return REAL(eglGetPlatformDisplay)(EGL_PLATFORM_ANGLE_ANGLE, EGL_DEFAULT_DISPLAY, a);
    }
    return REAL(eglGetDisplay)(native);
}

static EGLSurface make_window(EGLDisplay dpy, EGLConfig cfg, struct wl_egl_window *ewin)
{
    if (!g_wl || ensure_factory(g_wl) != 0) return EGL_NO_SURFACE;
    struct iosc_egl_win *w = calloc(1, sizeof(*w));
    w->magic = WIN_MAGIC;
    w->surface = ewin->surface;       /* the wl_surface (last member of wl_egl_window) */
    w->w = ewin->width; w->h = ewin->height;
    if (w->w <= 0) w->w = 1; if (w->h <= 0) w->h = 1;

    const EGLint pa[] = {
        EGL_WIDTH, w->w, EGL_HEIGHT, w->h, EGL_IOSURFACE_PLANE_ANGLE, 0,
        EGL_TEXTURE_TARGET, EGL_TEXTURE_2D, EGL_TEXTURE_INTERNAL_FORMAT_ANGLE, GL_BGRA_EXT,
        EGL_TEXTURE_FORMAT, EGL_TEXTURE_RGBA, EGL_TEXTURE_TYPE_ANGLE, GL_UNSIGNED_BYTE, EGL_NONE };
    for (int i = 0; i < IOSC_NBUF; i++) {
        w->ios[i] = make_ios(w->w, w->h);
        w->pbuf[i] = REAL(eglCreatePbufferFromClientBuffer)(dpy, EGL_IOSURFACE_ANGLE,
                        (EGLClientBuffer)w->ios[i], cfg, pa);
        mach_port_t port = IOSurfaceCreateMachPort(w->ios[i]);
        w->buf[i] = iosc_iosurface_create_buffer(g_factory, (uint32_t)port, w->w, w->h, 0);
        wl_proxy_set_queue((struct wl_proxy *)w->buf[i], g_queue);
        wl_buffer_add_listener(w->buf[i], &buf_listener, &w->busy[i]);
        if (w->pbuf[i] == EGL_NO_SURFACE)
            fprintf(stderr, "iosc_egl: pbuffer %d failed 0x%x\n", i, REAL(eglGetError)());
    }
    win_register(w);
    fprintf(stderr, "iosc_egl: window surface %dx%d (%d IOSurface buffers)\n", w->w, w->h, IOSC_NBUF);
    return (EGLSurface)w;
}
/* NB on this ANGLE EGLNativeWindowType is `int` (headless EGL default), so the
 * pointer-truncating eglCreateWindowSurface path is unusable — GDK uses the
 * platform variants (void* native_window). For EGL_PLATFORM_WAYLAND the native
 * window IS the struct wl_egl_window* (Mesa convention), passed directly. */
EGLSurface eglCreateWindowSurface(EGLDisplay dpy, EGLConfig cfg, EGLNativeWindowType win, const EGLint *attrs)
{ (void)attrs; return make_window(dpy, cfg, (struct wl_egl_window *)(uintptr_t)win); }
EGLSurface eglCreatePlatformWindowSurface(EGLDisplay dpy, EGLConfig cfg, void *win, const EGLAttrib *attrs)
{ (void)attrs; return make_window(dpy, cfg, (struct wl_egl_window *)win); }
EGLSurface eglCreatePlatformWindowSurfaceEXT(EGLDisplay dpy, EGLConfig cfg, void *win, const EGLint *attrs)
{ (void)attrs; return make_window(dpy, cfg, (struct wl_egl_window *)win); }

EGLBoolean eglMakeCurrent(EGLDisplay dpy, EGLSurface draw, EGLSurface read, EGLContext ctx)
{
    struct iosc_egl_win *w = as_win(draw);
    if (w) {
        EGLSurface pb = w->pbuf[w->cur];
        return REAL(eglMakeCurrent)(dpy, pb, pb, ctx);
    }
    return REAL(eglMakeCurrent)(dpy, draw, read, ctx);
}

EGLBoolean eglSwapBuffers(EGLDisplay dpy, EGLSurface surf)
{
    struct iosc_egl_win *w = as_win(surf);
    if (!w) return REAL(eglSwapBuffers)(dpy, surf);

    /* Barrier: the GPU render into ios[cur] must complete before iosc (a separate
     * process) samples that IOSurface. A per-frame fence blocks on just this
     * frame's work; glFinish drains the whole device. Fall back to glFinish if
     * EGL fence sync doesn't resolve. */
    EGLSync (*mk)(EGLDisplay, EGLenum, const EGLAttrib *) = REAL(eglCreateSync);
    EGLint (*fwait)(EGLDisplay, EGLSync, EGLint, EGLTime) = REAL(eglClientWaitSync);
    EGLBoolean (*del)(EGLDisplay, EGLSync)               = REAL(eglDestroySync);
    EGLSync fence = (mk && fwait && del) ? mk(dpy, EGL_SYNC_FENCE, NULL) : EGL_NO_SYNC;
    if (fence != EGL_NO_SYNC) {
        glFlush();
        fwait(dpy, fence, EGL_SYNC_FLUSH_COMMANDS_BIT, EGL_FOREVER);
        del(dpy, fence);
    } else {
        glFinish();                          /* GPU render into ios[cur] complete */
    }
    int i = w->cur;
    wl_surface_attach(w->surface, w->buf[i], 0, 0);
    wl_surface_damage(w->surface, 0, 0, w->w, w->h);
    wl_surface_commit(w->surface);
    w->busy[i] = 1;
    wl_display_flush(g_wl);

    /* rotate to the next buffer; wait (bounded) for it to be released by iosc. */
    w->cur = (i + 1) % IOSC_NBUF;
    int spins = 0;
    while (w->busy[w->cur] && spins++ < 100)
        wl_display_roundtrip_queue(g_wl, g_queue);

    EGLContext ctx = REAL(eglGetCurrentContext)();
    EGLSurface pb = w->pbuf[w->cur];
    REAL(eglMakeCurrent)(dpy, pb, pb, ctx);  /* next frame renders into the new buffer */
    return EGL_TRUE;
}

EGLBoolean eglQuerySurface(EGLDisplay dpy, EGLSurface surf, EGLint attr, EGLint *value)
{
    struct iosc_egl_win *w = as_win(surf);
    if (w) {
        if (attr == EGL_WIDTH)  { *value = w->w; return EGL_TRUE; }
        if (attr == EGL_HEIGHT) { *value = w->h; return EGL_TRUE; }
        return REAL(eglQuerySurface)(dpy, w->pbuf[w->cur], attr, value);
    }
    return REAL(eglQuerySurface)(dpy, surf, attr, value);
}
EGLBoolean eglDestroySurface(EGLDisplay dpy, EGLSurface surf)
{
    struct iosc_egl_win *w = as_win(surf);
    if (!w) return REAL(eglDestroySurface)(dpy, surf);
    win_unregister(w);
    for (int i = 0; i < IOSC_NBUF; i++) {
        if (w->pbuf[i] != EGL_NO_SURFACE) REAL(eglDestroySurface)(dpy, w->pbuf[i]);
        if (w->buf[i]) wl_buffer_destroy(w->buf[i]);
        if (w->ios[i]) CFRelease(w->ios[i]);
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
    return REAL(eglGetProcAddress)(name);
}

/* ---- pure forwarders (everything else GDK/epoxy resolves) ----------------- */

EGLBoolean eglInitialize(EGLDisplay d, EGLint *a, EGLint *b){ return REAL(eglInitialize)(d,a,b); }
EGLBoolean eglTerminate(EGLDisplay d){ return REAL(eglTerminate)(d); }
EGLint     eglGetError(void){ return REAL(eglGetError)(); }
const char*eglQueryString(EGLDisplay d, EGLint n){ return REAL(eglQueryString)(d,n); }
EGLBoolean eglGetConfigs(EGLDisplay d, EGLConfig *c, EGLint n, EGLint *m){ return REAL(eglGetConfigs)(d,c,n,m); }

/* ANGLE-Metal's configs are all window+pbuffer+bind-to-texture+RGBA8 — but their
 * EGL_RENDERABLE_TYPE advertises only ES1|ES2, NOT the ES3 bit (0x40), even though
 * the implementation supports ES3. So GDK's ES3 config search finds nothing ("No
 * EGL configuration available"). Bridge it: when a client asks for ES3 configs,
 * drop the ES3 bit so ANGLE's (ES2-advertised, ES3-capable) configs match; and
 * report the ES3 bit back so GDK/GSK believe ES3 is available. */
#define EGL_ES3_BIT 0x0040  /* EGL_OPENGL_ES3_BIT_KHR */
EGLBoolean eglChooseConfig(EGLDisplay d, const EGLint *a, EGLConfig *c, EGLint n, EGLint *m)
{
    EGLint p[64]; int k = 0;
    if (a) for (int i = 0; a[i] != EGL_NONE && k < 60; i += 2) {
        EGLint key = a[i], val = a[i + 1];
        if (key == EGL_RENDERABLE_TYPE && (val & EGL_ES3_BIT))
            val = (val & ~EGL_ES3_BIT) | EGL_OPENGL_ES2_BIT;
        p[k++] = key; p[k++] = val;
    }
    p[k] = EGL_NONE;
    return REAL(eglChooseConfig)(d, p, c, n, m);
}
EGLBoolean eglGetConfigAttrib(EGLDisplay d, EGLConfig c, EGLint a, EGLint *v)
{
    EGLBoolean r = REAL(eglGetConfigAttrib)(d, c, a, v);
    if (r && a == EGL_RENDERABLE_TYPE) *v |= EGL_ES3_BIT;   /* ANGLE supports ES3 here */
    return r;
}
EGLBoolean eglDestroyContext(EGLDisplay d, EGLContext c){ return REAL(eglDestroyContext)(d,c); }
EGLContext eglGetCurrentContext(void){ return REAL(eglGetCurrentContext)(); }
EGLSurface eglGetCurrentSurface(EGLint r){ return REAL(eglGetCurrentSurface)(r); }
EGLDisplay eglGetCurrentDisplay(void){ return REAL(eglGetCurrentDisplay)(); }
EGLBoolean eglQueryContext(EGLDisplay d, EGLContext c, EGLint a, EGLint *v){ return REAL(eglQueryContext)(d,c,a,v); }
EGLSurface eglCreatePbufferSurface(EGLDisplay d, EGLConfig c, const EGLint *a){ return REAL(eglCreatePbufferSurface)(d,c,a); }
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

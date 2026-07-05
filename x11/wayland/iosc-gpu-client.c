/*
 * iosc-gpu-client.c — a Wayland client that renders on the A-series GPU via ANGLE
 * (GLES → Metal) straight into an IOSurface, then hands that IOSurface to the iosc
 * compositor through the iosc_iosurface protocol. Validates the full GPU desktop
 * driver chain: GLES-on-Metal → IOSurface → Wayland → display (Xios app).
 *
 * Pipeline:
 *   1. IOSurfaceCreate (BGRA8) — the GPU render target + the buffer we share.
 *   2. ANGLE EGL: eglGetPlatformDisplayEXT(METAL) → context → a pbuffer bound to
 *      the IOSurface via EGL_ANGLE_iosurface_client_buffer.
 *   3. Render: clear (teal) + draw an orange triangle through a GLES2 shader, so
 *      the rasterizer (GPU) provably touched the pixels. glFinish().
 *   4. IOSurfaceCreateMachPort() → a port name in our task.
 *   5. iosc_iosurface.create_buffer(port_name,...) → wl_buffer; attach to an
 *      xdg_toplevel; commit. iosc imports the surface (task_for_pid) and blits it.
 *
 * MIT. Needs the Xios-app GPU entitlement set (AGX + IOSurface) + get-task-allow.
 */
#include <wayland-client.h>
#include "xdg-shell-client-protocol.h"
#include "iosc-iosurface-client-protocol.h"

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>
#include <GLES2/gl2ext.h>

#include <CoreFoundation/CoreFoundation.h>
#include <IOSurface/IOSurfaceRef.h>
#include <mach/mach.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ANGLE EGL/GL enums (in case a header is older than the ext) */
#ifndef EGL_PLATFORM_ANGLE_ANGLE
#define EGL_PLATFORM_ANGLE_ANGLE            0x3202
#define EGL_PLATFORM_ANGLE_TYPE_ANGLE       0x3203
#endif
#ifndef EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE
#define EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE 0x3489
#endif
#ifndef EGL_IOSURFACE_ANGLE
#define EGL_IOSURFACE_ANGLE                 0x3454
#define EGL_IOSURFACE_PLANE_ANGLE           0x345A
#define EGL_TEXTURE_RECTANGLE_ANGLE         0x345B
#define EGL_TEXTURE_TYPE_ANGLE              0x345C
#define EGL_TEXTURE_INTERNAL_FORMAT_ANGLE   0x345D
#endif
#ifndef EGL_BIND_TO_TEXTURE_TARGET_ANGLE
#define EGL_BIND_TO_TEXTURE_TARGET_ANGLE    0x348D
#endif
#ifndef GL_TEXTURE_RECTANGLE_ANGLE
#define GL_TEXTURE_RECTANGLE_ANGLE          0x84F5
#endif
#ifndef GL_BGRA_EXT
#define GL_BGRA_EXT                         0x80E1
#endif

static const int W = 1280, H = 960;

/* ---- IOSurface (BGRA8 render target) ------------------------------------- */

static void cfnum(CFMutableDictionaryRef d, CFStringRef k, int32_t v)
{ CFNumberRef n = CFNumberCreate(NULL, kCFNumberSInt32Type, &v);
  CFDictionarySetValue(d, k, n); CFRelease(n); }

static IOSurfaceRef make_iosurface(int w, int h)
{
    /* Fully specify the surface (aligned BytesPerRow + AllocSize) — ANGLE's
     * IOSurface validation checks the per-plane geometry, and an under-specified
     * surface makes eglCreatePbufferFromClientBuffer fail EGL_BAD_ATTRIBUTE. */
    size_t bpr = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, (size_t)(w * 4));
    size_t alloc = IOSurfaceAlignProperty(kIOSurfaceAllocSize, bpr * (size_t)h);
    CFMutableDictionaryRef d = CFDictionaryCreateMutable(
        NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    cfnum(d, kIOSurfaceWidth, w);
    cfnum(d, kIOSurfaceHeight, h);
    cfnum(d, kIOSurfaceBytesPerElement, 4);
    cfnum(d, kIOSurfaceBytesPerRow, (int32_t)bpr);
    cfnum(d, kIOSurfaceAllocSize, (int32_t)alloc);
    cfnum(d, kIOSurfacePixelFormat, 0x42475241 /* 'BGRA' */);
    IOSurfaceRef s = IOSurfaceCreate(d);
    CFRelease(d);
    if (!s) fprintf(stderr, "client: IOSurfaceCreate failed (IOSurface entitlement?)\n");
    return s;
}

/* ---- GLES via ANGLE ------------------------------------------------------ */

static GLuint compile(GLenum type, const char *src)
{
    GLuint s = glCreateShader(type);
    glShaderSource(s, 1, &src, NULL);
    glCompileShader(s);
    GLint ok = 0; glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
    if (!ok) { char log[512]; glGetShaderInfoLog(s, sizeof log, NULL, log);
               fprintf(stderr, "client: shader compile failed: %s\n", log); }
    return s;
}

static void egl_debug_cb(EGLenum error, const char *command, EGLint msgType,
                         EGLLabelKHR thread, EGLLabelKHR obj, const char *message)
{ (void)error; (void)msgType; (void)thread; (void)obj;
  fprintf(stderr, "client: [EGL] %s: %s\n", command ? command : "?", message ? message : ""); }

/* Render an orange triangle over a teal clear, into the IOSurface, on the GPU. */
static int gpu_render(IOSurfaceRef surface)
{
    /* EGL_KHR_debug: surface ANGLE's exact validation message to stderr. */
    EGLint (*debugControl)(EGLDEBUGPROCKHR, const EGLAttrib *) =
        (void *) eglGetProcAddress("eglDebugMessageControlKHR");
    if (debugControl) {
        const EGLAttrib da[] = { EGL_DEBUG_MSG_CRITICAL_KHR, EGL_TRUE,
            EGL_DEBUG_MSG_ERROR_KHR, EGL_TRUE, EGL_DEBUG_MSG_WARN_KHR, EGL_TRUE,
            EGL_DEBUG_MSG_INFO_KHR, EGL_TRUE, EGL_NONE };
        debugControl(egl_debug_cb, da);
    }

    EGLDisplay (*getPlatformDisplay)(EGLenum, void *, const EGLint *) =
        (void *) eglGetProcAddress("eglGetPlatformDisplayEXT");
    if (!getPlatformDisplay) { fprintf(stderr, "client: no eglGetPlatformDisplayEXT\n"); return -1; }

    const EGLint dpyAttrs[] = {
        EGL_PLATFORM_ANGLE_TYPE_ANGLE, EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE, EGL_NONE };
    EGLDisplay dpy = getPlatformDisplay(EGL_PLATFORM_ANGLE_ANGLE, EGL_DEFAULT_DISPLAY, dpyAttrs);
    if (dpy == EGL_NO_DISPLAY) { fprintf(stderr, "client: eglGetPlatformDisplay failed\n"); return -1; }

    EGLint major = 0, minor = 0;
    if (!eglInitialize(dpy, &major, &minor)) { fprintf(stderr, "client: eglInitialize failed 0x%x\n", eglGetError()); return -1; }
    fprintf(stderr, "client: EGL %d.%d; vendor=%s\n", major, minor, eglQueryString(dpy, EGL_VENDOR));
    const char *exts = eglQueryString(dpy, EGL_EXTENSIONS);
    fprintf(stderr, "client: iosurface_client_buffer advertised: %s\n",
            (exts && strstr(exts, "EGL_ANGLE_iosurface_client_buffer")) ? "YES" : "NO");

    /* On the Metal backend ANGLE binds IOSurfaces to GL_TEXTURE_2D (rectangle is
     * the desktop-GL backend), so a texture-bindable (BIND_TO_TEXTURE_RGBA) pbuffer
     * config — whose bindToTextureTarget is 2D — is what the IOSurface pbuffer wants. */
    const EGLint cfgAttrs[] = {
        EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
        EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
        EGL_BIND_TO_TEXTURE_RGBA, EGL_TRUE,
        EGL_NONE };
    EGLConfig config; EGLint n = 0;
    if (!eglChooseConfig(dpy, cfgAttrs, &config, 1, &n) || n == 0) {
        fprintf(stderr, "client: eglChooseConfig failed\n"); return -1; }

    const EGLint ctxAttrs[] = { EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE };
    EGLContext ctx = eglCreateContext(dpy, config, EGL_NO_CONTEXT, ctxAttrs);
    if (ctx == EGL_NO_CONTEXT) { fprintf(stderr, "client: eglCreateContext failed 0x%x\n", eglGetError()); return -1; }

    const EGLint pbAttrs[] = {
        EGL_WIDTH, W, EGL_HEIGHT, H,
        EGL_IOSURFACE_PLANE_ANGLE, 0,
        EGL_TEXTURE_TARGET, EGL_TEXTURE_2D,
        EGL_TEXTURE_INTERNAL_FORMAT_ANGLE, GL_BGRA_EXT,
        EGL_TEXTURE_FORMAT, EGL_TEXTURE_RGBA,
        EGL_TEXTURE_TYPE_ANGLE, GL_UNSIGNED_BYTE,
        EGL_NONE };
    EGLSurface pb = eglCreatePbufferFromClientBuffer(dpy, EGL_IOSURFACE_ANGLE,
                                                     (EGLClientBuffer) surface, config, pbAttrs);
    if (pb == EGL_NO_SURFACE) { fprintf(stderr, "client: eglCreatePbufferFromClientBuffer failed 0x%x\n", eglGetError()); return -1; }

    if (!eglMakeCurrent(dpy, pb, pb, ctx)) { fprintf(stderr, "client: eglMakeCurrent failed 0x%x\n", eglGetError()); return -1; }
    fprintf(stderr, "client: GL_RENDERER=%s\n", glGetString(GL_RENDERER));

    /* Bind the IOSurface pbuffer as the FBO color attachment, then render to it. */
    GLuint tex = 0; glGenTextures(1, &tex);
    glBindTexture(GL_TEXTURE_2D, tex);
    if (!eglBindTexImage(dpy, pb, EGL_BACK_BUFFER)) { fprintf(stderr, "client: eglBindTexImage failed 0x%x\n", eglGetError()); return -1; }
    GLuint fbo = 0; glGenFramebuffers(1, &fbo);
    glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                           GL_TEXTURE_2D, tex, 0);
    GLenum fbo_status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    if (fbo_status != GL_FRAMEBUFFER_COMPLETE)
        fprintf(stderr, "client: FBO incomplete 0x%x\n", fbo_status);

    glViewport(0, 0, W, H);
    glClearColor(0.0f, 0.5f, 0.5f, 1.0f);   /* teal */
    glClear(GL_COLOR_BUFFER_BIT);

    const char *vs = "attribute vec2 pos;\nvoid main(){ gl_Position = vec4(pos,0.0,1.0); }\n";
    const char *fs = "precision mediump float;\nvoid main(){ gl_FragColor = vec4(1.0,0.5,0.0,1.0); }\n";
    GLuint prog = glCreateProgram();
    glAttachShader(prog, compile(GL_VERTEX_SHADER, vs));
    glAttachShader(prog, compile(GL_FRAGMENT_SHADER, fs));
    glBindAttribLocation(prog, 0, "pos");
    glLinkProgram(prog);
    glUseProgram(prog);
    const GLfloat verts[] = { -0.8f, -0.8f,  0.8f, -0.8f,  0.0f, 0.8f };  /* covers center */
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, verts);
    glEnableVertexAttribArray(0);
    glDrawArrays(GL_TRIANGLES, 0, 3);

    glFinish();   /* ensure the GPU is done before the compositor reads the surface */
    eglReleaseTexImage(dpy, pb, EGL_BACK_BUFFER);
    fprintf(stderr, "client: GPU render complete (GL error 0x%x)\n", glGetError());
    return 0;
}

/* ---- Wayland ------------------------------------------------------------- */

static struct wl_compositor *compositor;
static struct xdg_wm_base   *wm_base;
static struct iosc_iosurface *iosurface_factory;

static void wm_base_ping(void *d, struct xdg_wm_base *b, uint32_t serial)
{ (void)d; xdg_wm_base_pong(b, serial); }
static const struct xdg_wm_base_listener wm_base_listener = { .ping = wm_base_ping };

static void reg_global(void *data, struct wl_registry *reg, uint32_t name,
                       const char *iface, uint32_t version)
{
    (void)data; (void)version;
    if (!strcmp(iface, "wl_compositor"))
        compositor = wl_registry_bind(reg, name, &wl_compositor_interface, 4);
    else if (!strcmp(iface, "xdg_wm_base")) {
        wm_base = wl_registry_bind(reg, name, &xdg_wm_base_interface, 1);
        xdg_wm_base_add_listener(wm_base, &wm_base_listener, NULL);
    } else if (!strcmp(iface, "iosc_iosurface"))
        iosurface_factory = wl_registry_bind(reg, name, &iosc_iosurface_interface, 1);
    fprintf(stderr, "client: global %s v%u\n", iface, version);
}
static void reg_global_remove(void *d, struct wl_registry *r, uint32_t n){ (void)d;(void)r;(void)n; }
static const struct wl_registry_listener registry_listener = {
    .global = reg_global, .global_remove = reg_global_remove };

static struct wl_surface  *surface;
static struct wl_buffer   *gpu_buffer;

static void commit_frame(void)
{
    wl_surface_attach(surface, gpu_buffer, 0, 0);
    wl_surface_damage(surface, 0, 0, W, H);
    wl_surface_commit(surface);
    fprintf(stderr, "client: committed GPU IOSurface buffer\n");
}
static void xsurf_configure(void *d, struct xdg_surface *xs, uint32_t serial)
{ (void)d; xdg_surface_ack_configure(xs, serial); commit_frame(); }
static const struct xdg_surface_listener xsurf_listener = { .configure = xsurf_configure };
static void top_configure(void *d, struct xdg_toplevel *t, int32_t w, int32_t h, struct wl_array *s)
{ (void)d;(void)t;(void)s; fprintf(stderr, "client: toplevel configure %dx%d\n", w, h); }
static void top_close(void *d, struct xdg_toplevel *t){ (void)d;(void)t; exit(0); }
static const struct xdg_toplevel_listener top_listener = { .configure = top_configure, .close = top_close };

int main(void)
{
    /* 1) GPU-render into an IOSurface. */
    IOSurfaceRef surf = make_iosurface(W, H);
    if (!surf) return 1;
    if (gpu_render(surf) != 0) { fprintf(stderr, "client: GPU render failed\n"); return 1; }

    /* 2) A mach port naming the IOSurface in our task — iosc imports it by this. */
    mach_port_t port = IOSurfaceCreateMachPort(surf);
    if (port == MACH_PORT_NULL) { fprintf(stderr, "client: IOSurfaceCreateMachPort failed\n"); return 1; }
    fprintf(stderr, "client: IOSurface mach port name = 0x%x\n", port);

    /* 3) Wayland: hand the IOSurface to iosc as a wl_buffer + map a toplevel. */
    struct wl_display *dpy = wl_display_connect(NULL);
    if (!dpy) { fprintf(stderr, "client: wl_display_connect failed\n"); return 1; }
    struct wl_registry *reg = wl_display_get_registry(dpy);
    wl_registry_add_listener(reg, &registry_listener, NULL);
    wl_display_roundtrip(dpy);
    if (!compositor || !wm_base || !iosurface_factory) {
        fprintf(stderr, "client: missing globals (compositor=%p wm_base=%p iosc_iosurface=%p)\n",
                (void*)compositor, (void*)wm_base, (void*)iosurface_factory);
        return 1;
    }

    gpu_buffer = iosc_iosurface_create_buffer(iosurface_factory, (uint32_t)port, W, H,
                                              IOSC_IOSURFACE_FORMAT_BGRA8888_GL_ORIGIN);

    surface = wl_compositor_create_surface(compositor);
    struct xdg_surface *xs = xdg_wm_base_get_xdg_surface(wm_base, surface);
    xdg_surface_add_listener(xs, &xsurf_listener, NULL);
    struct xdg_toplevel *top = xdg_surface_get_toplevel(xs);
    xdg_toplevel_add_listener(top, &top_listener, NULL);
    xdg_toplevel_set_title(top, "iosc-gpu-client");
    wl_surface_commit(surface);

    fprintf(stderr, "client: mapped; dispatching\n");
    while (wl_display_dispatch(dpy) != -1) { /* keep the IOSurface alive for iosc */ }
    return 0;
}

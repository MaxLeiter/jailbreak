/*
 * iosc-egl-client.c — validates the wayland-egl↔ANGLE shim in isolation.
 *
 * Uses ONLY the standard Wayland-EGL API (the same calls GTK4/GSK make):
 * eglGetDisplay(wl_display) → wl_egl_window_create → eglCreateWindowSurface →
 * render GLES → eglSwapBuffers. All the IOSurface/iosc_iosurface machinery lives
 * in the shim (libiosc_egl), so if this paints on the A10 through iosc, the shim
 * works for any GL Wayland client. Renders a few animated frames (color cycles +
 * an orange triangle) to exercise buffer rotation.
 *
 * MIT.
 */
#include <wayland-client.h>
#include <wayland-egl.h>
#include "xdg-shell-client-protocol.h"

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>

#ifndef EGL_PLATFORM_WAYLAND_EXT
#define EGL_PLATFORM_WAYLAND_EXT 0x31D8
#endif

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static struct wl_compositor *compositor;
static struct xdg_wm_base   *wm_base;
static struct wl_surface    *surface;
static int configured = 0;

static const int W = 1280, H = 960;

static void wm_ping(void *d, struct xdg_wm_base *b, uint32_t s){ (void)d; xdg_wm_base_pong(b, s); }
static const struct xdg_wm_base_listener wm_listener = { wm_ping };

static void reg_global(void *d, struct wl_registry *r, uint32_t name, const char *i, uint32_t v)
{
    (void)d; (void)v;
    if (!strcmp(i, "wl_compositor")) compositor = wl_registry_bind(r, name, &wl_compositor_interface, 4);
    else if (!strcmp(i, "xdg_wm_base")) { wm_base = wl_registry_bind(r, name, &xdg_wm_base_interface, 1);
                                          xdg_wm_base_add_listener(wm_base, &wm_listener, NULL); }
}
static void reg_remove(void *d, struct wl_registry *r, uint32_t n){ (void)d;(void)r;(void)n; }
static const struct wl_registry_listener reg_listener = { reg_global, reg_remove };

static void xsurf_configure(void *d, struct xdg_surface *xs, uint32_t serial)
{ (void)d; xdg_surface_ack_configure(xs, serial); configured = 1; }
static const struct xdg_surface_listener xsurf_listener = { xsurf_configure };
static void top_configure(void *d, struct xdg_toplevel *t, int32_t w, int32_t h, struct wl_array *s)
{ (void)d;(void)t;(void)w;(void)h;(void)s; }
static void top_close(void *d, struct xdg_toplevel *t){ (void)d;(void)t; exit(0); }
static const struct xdg_toplevel_listener top_listener = { top_configure, top_close };

static GLuint compile(GLenum t, const char *s)
{ GLuint sh = glCreateShader(t); glShaderSource(sh,1,&s,0); glCompileShader(sh); return sh; }

int main(void)
{
    struct wl_display *dpy = wl_display_connect(NULL);
    if (!dpy) { fprintf(stderr, "client: connect failed\n"); return 1; }
    struct wl_registry *reg = wl_display_get_registry(dpy);
    wl_registry_add_listener(reg, &reg_listener, NULL);
    wl_display_roundtrip(dpy);
    if (!compositor || !wm_base) { fprintf(stderr, "client: missing globals\n"); return 1; }

    surface = wl_compositor_create_surface(compositor);
    struct xdg_surface *xs = xdg_wm_base_get_xdg_surface(wm_base, surface);
    xdg_surface_add_listener(xs, &xsurf_listener, NULL);
    struct xdg_toplevel *top = xdg_surface_get_toplevel(xs);
    xdg_toplevel_add_listener(top, &top_listener, NULL);
    xdg_toplevel_set_title(top, "iosc-egl-client (wl_egl_window+ANGLE)");
    wl_surface_commit(surface);
    while (!configured) wl_display_dispatch(dpy);

    /* ---- standard Wayland-EGL setup (this is what the shim intercepts) ----
     * Use the platform (void*) entrypoints, like GDK: on this ANGLE the legacy
     * eglGetDisplay/eglCreateWindowSurface take `int` natives and would truncate
     * the wl_display / wl_egl_window pointers. */
    PFNEGLGETPLATFORMDISPLAYEXTPROC getPD = (void *)eglGetProcAddress("eglGetPlatformDisplayEXT");
    PFNEGLCREATEPLATFORMWINDOWSURFACEEXTPROC createWin = (void *)eglGetProcAddress("eglCreatePlatformWindowSurfaceEXT");
    if (!getPD || !createWin) { fprintf(stderr, "client: missing platform EGL entrypoints\n"); return 1; }
    EGLDisplay egl = getPD(EGL_PLATFORM_WAYLAND_EXT, dpy, NULL);
    if (egl == EGL_NO_DISPLAY) { fprintf(stderr, "client: eglGetPlatformDisplay failed\n"); return 1; }
    EGLint maj, min; eglInitialize(egl, &maj, &min);
    fprintf(stderr, "client: EGL %d.%d vendor=%s\n", maj, min, eglQueryString(egl, EGL_VENDOR));

    const EGLint cfgA[] = { EGL_SURFACE_TYPE, EGL_WINDOW_BIT | EGL_PBUFFER_BIT,
        EGL_RED_SIZE,8,EGL_GREEN_SIZE,8,EGL_BLUE_SIZE,8,EGL_ALPHA_SIZE,8,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT, EGL_BIND_TO_TEXTURE_RGBA, EGL_TRUE, EGL_NONE };
    EGLConfig cfg; EGLint n = 0;
    if (!eglChooseConfig(egl, cfgA, &cfg, 1, &n) || n == 0) { fprintf(stderr, "client: chooseConfig failed\n"); return 1; }
    const EGLint ctxA[] = { EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE };
    EGLContext ctx = eglCreateContext(egl, cfg, EGL_NO_CONTEXT, ctxA);

    struct wl_egl_window *ewin = wl_egl_window_create(surface, W, H);
    EGLSurface es = createWin(egl, cfg, ewin, NULL);
    if (es == EGL_NO_SURFACE) { fprintf(stderr, "client: createPlatformWindowSurface failed 0x%x\n", eglGetError()); return 1; }
    if (!eglMakeCurrent(egl, es, es, ctx)) { fprintf(stderr, "client: makeCurrent failed 0x%x\n", eglGetError()); return 1; }
    fprintf(stderr, "client: GL_RENDERER=%s\n", glGetString(GL_RENDERER));

    GLuint prog = glCreateProgram();
    glAttachShader(prog, compile(GL_VERTEX_SHADER, "attribute vec2 p; void main(){ gl_Position=vec4(p,0,1);}"));
    glAttachShader(prog, compile(GL_FRAGMENT_SHADER, "precision mediump float; void main(){ gl_FragColor=vec4(1.0,0.5,0.0,1.0);}"));
    glBindAttribLocation(prog, 0, "p");
    glLinkProgram(prog); glUseProgram(prog);
    const GLfloat v[] = { -0.8f,-0.8f, 0.8f,-0.8f, 0.0f,0.8f };

    for (int f = 0; f < 60; f++) {
        glViewport(0, 0, W, H);
        float c = (f % 30) / 30.0f;
        glClearColor(0.0f, 0.3f + 0.4f*c, 0.5f, 1.0f);   /* animated teal->green */
        glClear(GL_COLOR_BUFFER_BIT);
        glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, v);
        glEnableVertexAttribArray(0);
        glDrawArrays(GL_TRIANGLES, 0, 3);
        eglSwapBuffers(egl, es);            /* shim hands an IOSurface to iosc */
        if (f == 0) fprintf(stderr, "client: first eglSwapBuffers done (GL err 0x%x)\n", glGetError());
        wl_display_dispatch_pending(dpy);
        struct timespec ts = { 0, 80*1000*1000 }; nanosleep(&ts, NULL);
    }
    fprintf(stderr, "client: 60 frames swapped; idling\n");
    while (wl_display_dispatch(dpy) != -1) {}
    return 0;
}

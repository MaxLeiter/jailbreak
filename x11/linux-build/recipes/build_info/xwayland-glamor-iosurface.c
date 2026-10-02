/*
 * xwayland-glamor-iosurface.c — Xwayland glamor EGL backend for iOS/ANGLE.
 *
 * iOS has no DRM/gbm/dma-buf. This backend renders glamor pixmaps directly
 * into IOSurfaces via ANGLE's EGL_ANGLE_iosurface_client_buffer (pbuffer
 * bound to a GL texture with eglBindTexImage), and exports them to the
 * compositor with the iosc_iosurface protocol (a mach-port-name handoff;
 * see iosc-iosurface.xml — a mach send right cannot traverse the Wayland
 * socket's SCM_RIGHTS, so the compositor imports the surface from this
 * task by pid via task_for_pid + mach_port_extract_right).
 *
 * The EGL/IOSurface sequence mirrors the on-device-proven plumbing in
 * x11/wayland/xios_egl.c and iosc-gpu-client.c (pbuffer EGL_TEXTURE_2D +
 * EGL_BIND_TO_TEXTURE_RGBA config + fully-specified IOSurface geometry).
 *
 * Xwayland 24.1 removed the pluggable xwl_egl_backend vtable: the gbm/dma-buf
 * backend is the only one and xwayland-glamor.c is hard-wired to it. When the
 * build has no gbm (build_iosurface, see the build patch) this file is compiled
 * INSTEAD of xwayland-glamor.c and xwayland-glamor-gbm.c and provides every
 * symbol the rest of hw/xwayland expects from them:
 *   - the glamor entry points (xwl_glamor_init, _init_wl_registry, _egl_make_current,
 *     _pixmap_get_wl_buffer, _create_pixmap_for_window, _check_flip, ...)
 *   - glamor_egl_screen_init / glamor_egl_fd_name_from_pixmap (called by glamor/)
 *   - inert compat shims for the gbm explicit-sync/dmabuf-feedback hooks
 *     (window-buffers.c, dmabuf.c), so those upstream files stay unmodified.
 * Presentation sync is the brokered Metal shared-event fence, signalled from
 * xwl_glamor_iosurface_signal_acquire() (called by the window-buffers.c hook).
 *
 * MIT, same terms as the surrounding X server code.
 */

#include <xwayland-config.h>

#define MESA_EGL_NO_X11_HEADERS
#define EGL_NO_X11
#include <glamor_egl.h>

#include <glamor.h>
#include <glamor_context.h>
#include <glamor_glx_provider.h>
#ifdef GLXEXT
#include "glx_extinit.h"
#endif

#include "xwayland-glamor.h"
#include "xwayland-pixmap.h"
#include "xwayland-present.h"
#include "xwayland-screen.h"
#include "xwayland-window.h"
#include "xwayland-window-buffers.h"

#include "iosc-iosurface-client-protocol.h"
#include "xios_metal_sync.h"

#include <IOSurface/IOSurfaceRef.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach.h>
#include <limits.h>
#include <stdint.h>
#include <string.h>

/* ANGLE enums, self-contained (values match eglext_angle.h; same set as
 * xios_egl.c so we do not depend on the angle -dev headers here). */
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
#define EGL_TEXTURE_TYPE_ANGLE              0x345C
#define EGL_TEXTURE_INTERNAL_FORMAT_ANGLE   0x345D
#endif
#ifndef GL_BGRA_EXT
#define GL_BGRA_EXT                         0x80E1
#endif
#ifndef EGL_NO_CONFIG_KHR
#define EGL_NO_CONFIG_KHR                   ((EGLConfig)0)
#endif
struct xwl_iosurface_private {
    struct iosc_iosurface *iosc_iosurface; /* the compositor's export global */
    EGLConfig pbuffer_config;              /* bind-to-texture RGBA pbuffer config */
    EGLSurface dummy_surface;              /* only if surfaceless MakeCurrent fails */
};

struct xwl_pixmap {
    struct wl_buffer *buffer;
    IOSurfaceRef iosurface;
    mach_port_t port;       /* IOSurfaceCreateMachPort send right (our IPC space) */
    EGLSurface pbuffer;     /* EGL_IOSURFACE_ANGLE pbuffer over iosurface */
    unsigned int texture;   /* GL texture the pbuffer is bound to (glamor's) */
};

static DevPrivateKeyRec xwl_iosurface_private_key;

/* Surface for glamor_egl_make_current: stays EGL_NO_SURFACE unless
 * surfaceless MakeCurrent turned out unsupported at init_egl time, in which
 * case it is a 1x1 pbuffer. */
static EGLSurface xwl_iosurface_fallback_surface = EGL_NO_SURFACE;

static inline struct xwl_iosurface_private *
xwl_iosurface_get(struct xwl_screen *xwl_screen)
{
    return dixLookupPrivate(&xwl_screen->screen->devPrivates,
                            &xwl_iosurface_private_key);
}

/* ---- IOSurface creation (proven shape: iosc-gpu-client.c) ---------------- */

static Bool
xwl_iosurface_dict_set_int(CFMutableDictionaryRef d, CFStringRef k, int32_t v)
{
    CFNumberRef n = CFNumberCreate(NULL, kCFNumberSInt32Type, &v);
    if (!n)
        return FALSE;
    CFDictionarySetValue(d, k, n);
    CFRelease(n);
    return TRUE;
}

static IOSurfaceRef
xwl_iosurface_create(int width, int height)
{
    /* Fully specify the surface (aligned BytesPerRow + AllocSize) — ANGLE's
     * IOSurface validation checks the per-plane geometry, and an
     * under-specified surface fails eglCreatePbufferFromClientBuffer with
     * EGL_BAD_ATTRIBUTE. */
    if (width <= 0 || height <= 0 || width > INT_MAX / 4) {
        ErrorF("glamor/iosurface: invalid IOSurface geometry %dx%d\n",
               width, height);
        return NULL;
    }

    size_t bpr = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow,
                                        (size_t)width * 4);
    size_t alloc = IOSurfaceAlignProperty(kIOSurfaceAllocSize,
                                          bpr * (size_t)height);
    if (bpr > INT32_MAX || alloc > INT32_MAX) {
        ErrorF("glamor/iosurface: IOSurface too large %dx%d stride=%zu alloc=%zu\n",
               width, height, bpr, alloc);
        return NULL;
    }

    CFMutableDictionaryRef d = CFDictionaryCreateMutable(
        NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    IOSurfaceRef s;

    if (!d)
        return NULL;

    if (!xwl_iosurface_dict_set_int(d, kIOSurfaceWidth, width) ||
        !xwl_iosurface_dict_set_int(d, kIOSurfaceHeight, height) ||
        !xwl_iosurface_dict_set_int(d, kIOSurfaceBytesPerElement, 4) ||
        !xwl_iosurface_dict_set_int(d, kIOSurfaceBytesPerRow, (int32_t)bpr) ||
        !xwl_iosurface_dict_set_int(d, kIOSurfaceAllocSize, (int32_t)alloc) ||
        !xwl_iosurface_dict_set_int(d, kIOSurfacePixelFormat,
                                    0x42475241 /* 'BGRA' */)) {
        CFRelease(d);
        return NULL;
    }

    s = IOSurfaceCreate(d);
    CFRelease(d);

    if (!s)
        ErrorF("glamor/iosurface: IOSurfaceCreate %dx%d failed "
               "(IOSurface entitlement?)\n", width, height);
    return s;
}

/* ---- pixmaps -------------------------------------------------------------- */

static void
xwl_iosurface_destroy_pixmap_storage(struct xwl_screen *xwl_screen,
                                     struct xwl_pixmap *xwl_pixmap)
{
    if (xwl_pixmap->buffer)
        wl_buffer_destroy(xwl_pixmap->buffer);
    if (xwl_pixmap->port != MACH_PORT_NULL)
        mach_port_deallocate(mach_task_self(), xwl_pixmap->port);
    /* The texture belongs to glamor once glamor_set_pixmap_texture has run
     * (glamor_destroy_pixmap deletes it — same ownership as the gbm backend);
     * only unbind + destroy the pbuffer here. */
    if (xwl_pixmap->pbuffer != EGL_NO_SURFACE) {
        xwl_glamor_egl_make_current(xwl_screen);
        if (xwl_pixmap->texture)
            eglReleaseTexImage(xwl_screen->egl_display, xwl_pixmap->pbuffer,
                               EGL_BACK_BUFFER);
        eglDestroySurface(xwl_screen->egl_display, xwl_pixmap->pbuffer);
    }
    if (xwl_pixmap->iosurface)
        CFRelease(xwl_pixmap->iosurface);
    free(xwl_pixmap);
}

static PixmapPtr
xwl_glamor_iosurface_create_backed_pixmap(ScreenPtr screen,
                                          int width, int height, int depth)
{
    struct xwl_screen *xwl_screen = xwl_screen_get(screen);
    struct xwl_iosurface_private *xwl_iosurface = xwl_iosurface_get(xwl_screen);
    struct xwl_pixmap *xwl_pixmap;
    PixmapPtr pixmap;
    Bool texture_owned_by_glamor = FALSE;
    EGLint pb_attribs[] = {
        EGL_WIDTH, width,
        EGL_HEIGHT, height,
        EGL_IOSURFACE_PLANE_ANGLE, 0,
        /* Metal binds IOSurfaces to GL_TEXTURE_2D, NOT the rectangle target
         * (rectangle is the desktop-GL backend; wrong target fails with
         * "texture target to match the config"). */
        EGL_TEXTURE_TARGET, EGL_TEXTURE_2D,
        EGL_TEXTURE_INTERNAL_FORMAT_ANGLE, GL_BGRA_EXT,
        EGL_TEXTURE_FORMAT, EGL_TEXTURE_RGBA,
        EGL_TEXTURE_TYPE_ANGLE, GL_UNSIGNED_BYTE,
        EGL_NONE
    };

    xwl_pixmap = calloc(1, sizeof(*xwl_pixmap));
    if (xwl_pixmap == NULL)
        return NULL;
    xwl_pixmap->pbuffer = EGL_NO_SURFACE;
    xwl_pixmap->port = MACH_PORT_NULL;

    pixmap = glamor_create_pixmap(screen, width, height, depth,
                                  GLAMOR_CREATE_PIXMAP_NO_TEXTURE);
    if (!pixmap) {
        free(xwl_pixmap);
        return NULL;
    }

    xwl_glamor_egl_make_current(xwl_screen);

    xwl_pixmap->iosurface = xwl_iosurface_create(width, height);
    if (!xwl_pixmap->iosurface)
        goto error;

    xwl_pixmap->pbuffer =
        eglCreatePbufferFromClientBuffer(xwl_screen->egl_display,
                                         EGL_IOSURFACE_ANGLE,
                                         (EGLClientBuffer) xwl_pixmap->iosurface,
                                         xwl_iosurface->pbuffer_config,
                                         pb_attribs);
    if (xwl_pixmap->pbuffer == EGL_NO_SURFACE) {
        ErrorF("glamor/iosurface: eglCreatePbufferFromClientBuffer failed 0x%x\n",
               eglGetError());
        goto error;
    }

    glGenTextures(1, &xwl_pixmap->texture);
    glBindTexture(GL_TEXTURE_2D, xwl_pixmap->texture);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    if (!eglBindTexImage(xwl_screen->egl_display, xwl_pixmap->pbuffer,
                         EGL_BACK_BUFFER)) {
        ErrorF("glamor/iosurface: eglBindTexImage failed 0x%x\n", eglGetError());
        glBindTexture(GL_TEXTURE_2D, 0);
        goto error;
    }
    glBindTexture(GL_TEXTURE_2D, 0);

    if (!glamor_set_pixmap_texture(pixmap, xwl_pixmap->texture))
        goto error;
    texture_owned_by_glamor = TRUE;

    glamor_set_pixmap_type(pixmap, GLAMOR_TEXTURE_DRM);
    xwl_pixmap_set_private(pixmap, xwl_pixmap);

    return pixmap;

error:
    if (!texture_owned_by_glamor && xwl_pixmap->texture) {
        glDeleteTextures(1, &xwl_pixmap->texture);
        xwl_pixmap->texture = 0;
    }
    xwl_iosurface_destroy_pixmap_storage(xwl_screen, xwl_pixmap);
    glamor_destroy_pixmap(pixmap);
    return NULL;
}

static PixmapPtr
xwl_glamor_iosurface_create_pixmap(ScreenPtr screen,
                                   int width, int height, int depth,
                                   unsigned int hint)
{
    struct xwl_screen *xwl_screen = xwl_screen_get(screen);
    PixmapPtr pixmap = NULL;

    /* Only window-backing / shareable pixmaps need IOSurface storage
     * (they become wl_buffers). BGRA covers depth 24 (XRGB) and 32 (ARGB);
     * everything else stays a plain glamor texture. Same hint policy as
     * the gbm backend. */
    if (width > 0 && height > 0 && (depth == 24 || depth == 32) &&
        (hint == CREATE_PIXMAP_USAGE_BACKING_PIXMAP ||
         hint == CREATE_PIXMAP_USAGE_SHARED ||
         (xwl_screen->rootless && hint == 0))) {
        pixmap = xwl_glamor_iosurface_create_backed_pixmap(screen, width,
                                                           height, depth);
        if (pixmap && xwl_screen->rootless &&
            hint == CREATE_PIXMAP_USAGE_BACKING_PIXMAP)
            glamor_clear_pixmap(pixmap);
    }

    if (!pixmap)
        pixmap = glamor_create_pixmap(screen, width, height, depth, hint);

    return pixmap;
}

PixmapPtr
xwl_glamor_create_pixmap_for_window(struct xwl_window *xwl_window)
{
    struct xwl_screen *xwl_screen = xwl_window->xwl_screen;
    WindowPtr window = xwl_window->surface_window;
    unsigned border_width = 2 * window->borderWidth;

    if (!xwl_screen->glamor)
        return NullPixmap;

    return xwl_glamor_iosurface_create_pixmap(xwl_screen->screen,
                                              window->drawable.width + border_width,
                                              window->drawable.height + border_width,
                                              window->drawable.depth,
                                              CREATE_PIXMAP_USAGE_BACKING_PIXMAP);
}

static Bool
xwl_glamor_iosurface_destroy_pixmap(PixmapPtr pixmap)
{
    struct xwl_screen *xwl_screen = xwl_screen_get(pixmap->drawable.pScreen);
    struct xwl_pixmap *xwl_pixmap = xwl_pixmap_get(pixmap);

    if (xwl_pixmap && pixmap->refcnt == 1) {
        xwl_pixmap_del_buffer_release_cb(pixmap);
        xwl_iosurface_destroy_pixmap_storage(xwl_screen, xwl_pixmap);
    }

    return glamor_destroy_pixmap(pixmap);
}

/* ---- wl_buffer export (iosc_iosurface handoff) ---------------------------- */

static const struct wl_buffer_listener xwl_glamor_iosurface_buffer_listener = {
    xwl_pixmap_buffer_release_cb,
};

struct wl_buffer *
xwl_glamor_pixmap_get_wl_buffer(PixmapPtr pixmap)
{
    struct xwl_screen *xwl_screen = xwl_screen_get(pixmap->drawable.pScreen);
    struct xwl_iosurface_private *xwl_iosurface = xwl_iosurface_get(xwl_screen);
    struct xwl_pixmap *xwl_pixmap = xwl_pixmap_get(pixmap);

    if (xwl_pixmap == NULL)
        return NULL;

    if (xwl_pixmap->buffer)
        return xwl_pixmap->buffer;

    if (!xwl_pixmap->iosurface || !xwl_iosurface->iosc_iosurface)
        return NULL;

    /* A send right in OUR IPC space; the compositor extracts it from this
     * task by the wl socket's peer pid. Must stay alive as long as the
     * wl_buffer does (deallocated in destroy_pixmap_storage). */
    if (xwl_pixmap->port != MACH_PORT_NULL) {
        mach_port_deallocate(mach_task_self(), xwl_pixmap->port);
        xwl_pixmap->port = MACH_PORT_NULL;
    }

    xwl_pixmap->port = IOSurfaceCreateMachPort(xwl_pixmap->iosurface);
    if (xwl_pixmap->port == MACH_PORT_NULL) {
        ErrorF("glamor/iosurface: IOSurfaceCreateMachPort failed\n");
        return NULL;
    }

    xwl_pixmap->buffer =
        iosc_iosurface_create_buffer(xwl_iosurface->iosc_iosurface,
                                     (uint32_t) xwl_pixmap->port,
                                     pixmap->drawable.width,
                                     pixmap->drawable.height,
                                     IOSC_IOSURFACE_FORMAT_BGRA8888_GL_ORIGIN |
                                     IOSC_IOSURFACE_FORMAT_FLAG_TOP_LEFT);

    if (xwl_pixmap->buffer) {
        wl_buffer_add_listener(xwl_pixmap->buffer,
                               &xwl_glamor_iosurface_buffer_listener, pixmap);
    } else {
        mach_port_deallocate(mach_task_self(), xwl_pixmap->port);
        xwl_pixmap->port = MACH_PORT_NULL;
    }

    return xwl_pixmap->buffer;
}

/* ---- presentation sync ----------------------------------------------------- */

/* Called from xwl_window_handle_pixmap_sync() (window-buffers.c) after the
 * damage has been copied into the window buffer and before it is attached.
 * 23.2 did this in the backend's post_damage vfunc. Exports a Metal shared
 * event the compositor GPU waits on before sampling the IOSurface; there is
 * no CPU fallback (a missing broker is fatal, as before). */
void
xwl_glamor_iosurface_signal_acquire(struct xwl_window *xwl_window,
                                    PixmapPtr pixmap)
{
    struct xwl_screen *xwl_screen = xwl_window->xwl_screen;
    struct xwl_pixmap *xwl_pixmap = xwl_pixmap_get(pixmap);
    const void *token = NULL;
    size_t token_size = 0;
    uint64_t value = 0;
    struct wl_array token_array;

    if (!xwl_pixmap)
        return;
    if (!xwl_pixmap->buffer && !xwl_glamor_pixmap_get_wl_buffer(pixmap))
        return;

    xwl_glamor_egl_make_current(xwl_screen);
    if (!xios_metal_sync_signal(xwl_screen->egl_display,
                                &token, &token_size, &value))
        FatalError("glamor/iosurface: brokered GPU acquire fence unavailable\n");

    token_array.size = token_size;
    token_array.alloc = token_size;
    token_array.data = (void *)token;
    iosc_iosurface_set_acquire_fence(
        xwl_iosurface_get(xwl_screen)->iosc_iosurface,
        xwl_pixmap->buffer,
        &token_array,
        (uint32_t)(value & 0xffffffffu),
        (uint32_t)(value >> 32));
}

/* ---- registry ------------------------------------------------------------- */

void
xwl_glamor_init_wl_registry(struct xwl_screen *xwl_screen,
                            struct wl_registry *registry,
                            uint32_t id, const char *interface,
                            uint32_t version)
{
    struct xwl_iosurface_private *xwl_iosurface = xwl_iosurface_get(xwl_screen);

    if (strcmp(interface, "iosc_iosurface") == 0)
        xwl_iosurface->iosc_iosurface =
            wl_registry_bind(registry, id, &iosc_iosurface_interface, 1);
}

static Bool
xwl_glamor_has_wl_interfaces(struct xwl_screen *xwl_screen)
{
    struct xwl_iosurface_private *xwl_iosurface = xwl_iosurface_get(xwl_screen);

    if (xwl_iosurface->iosc_iosurface == NULL) {
        LogMessageVerb(X_INFO, 3, "glamor/iosurface: 'iosc_iosurface' not "
                       "advertised by the compositor\n");
        return FALSE;
    }

    return TRUE;
}

/* ---- EGL bring-up (proven shape: xios_egl.c) ------------------------------ */

static Bool
xwl_glamor_iosurface_init_egl(struct xwl_screen *xwl_screen)
{
    if (!(xwl_screen->glamor & XWL_GLAMOR_GLES)) {
        ErrorF("glamor/iosurface: GLES only (ANGLE); -glamor gl is unsupported\n");
        return FALSE;
    }

    struct xwl_iosurface_private *xwl_iosurface = xwl_iosurface_get(xwl_screen);
    EGLDisplay (*get_platform_display)(EGLenum, void *, const EGLint *);
    static const EGLint display_attribs[] = {
        EGL_PLATFORM_ANGLE_TYPE_ANGLE,
        EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE,
        EGL_NONE
    };
    static const EGLint config_attribs[] = {
        EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
        EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
        /* M2 gotcha: plain pbuffer configs are non-bindable; glamor's pixmap
         * textures come from eglBindTexImage, so the config must bind. */
        EGL_BIND_TO_TEXTURE_RGBA, EGL_TRUE,
        EGL_NONE
    };
    EGLint major, minor, n = 0, es_version;
    const GLubyte *renderer;

    get_platform_display =
        (void *) eglGetProcAddress("eglGetPlatformDisplayEXT");
    if (!get_platform_display) {
        ErrorF("glamor/iosurface: no eglGetPlatformDisplayEXT\n");
        return FALSE;
    }

    xwl_screen->egl_display = get_platform_display(EGL_PLATFORM_ANGLE_ANGLE,
                                                   EGL_DEFAULT_DISPLAY,
                                                   display_attribs);
    if (xwl_screen->egl_display == EGL_NO_DISPLAY) {
        ErrorF("glamor/iosurface: eglGetPlatformDisplayEXT(ANGLE/Metal) failed\n");
        return FALSE;
    }

    if (!eglInitialize(xwl_screen->egl_display, &major, &minor)) {
        ErrorF("glamor/iosurface: eglInitialize failed\n");
        goto error;
    }

    if (!eglChooseConfig(xwl_screen->egl_display, config_attribs,
                         &xwl_iosurface->pbuffer_config, 1, &n) || n == 0) {
        ErrorF("glamor/iosurface: no bind-to-texture pbuffer EGLConfig\n");
        goto error;
    }

    eglBindAPI(EGL_OPENGL_ES_API);

    /* ES 3 preferred (better formats for glamor), ES 2 fallback. */
    for (es_version = 3; es_version >= 2; es_version--) {
        const EGLint ctx_attribs[] = {
            EGL_CONTEXT_CLIENT_VERSION, es_version,
            EGL_NONE
        };
        xwl_screen->egl_context =
            eglCreateContext(xwl_screen->egl_display, EGL_NO_CONFIG_KHR,
                             EGL_NO_CONTEXT, ctx_attribs);
        if (xwl_screen->egl_context != EGL_NO_CONTEXT)
            break;
    }
    if (xwl_screen->egl_context == EGL_NO_CONTEXT) {
        ErrorF("glamor/iosurface: eglCreateContext(ES3/ES2) failed 0x%x\n",
               eglGetError());
        goto error;
    }

    if (!eglMakeCurrent(xwl_screen->egl_display, EGL_NO_SURFACE,
                        EGL_NO_SURFACE, xwl_screen->egl_context)) {
        /* No surfaceless support: fall back to a 1x1 dummy pbuffer, which
         * the patched glamor_egl_make_current then uses for every
         * MakeCurrent (xwl_iosurface_fallback_surface). */
        static const EGLint dummy_attribs[] = {
            EGL_WIDTH, 1, EGL_HEIGHT, 1, EGL_NONE
        };
        xwl_iosurface->dummy_surface =
            eglCreatePbufferSurface(xwl_screen->egl_display,
                                    xwl_iosurface->pbuffer_config,
                                    dummy_attribs);
        if (xwl_iosurface->dummy_surface == EGL_NO_SURFACE ||
            !eglMakeCurrent(xwl_screen->egl_display,
                            xwl_iosurface->dummy_surface,
                            xwl_iosurface->dummy_surface,
                            xwl_screen->egl_context)) {
            ErrorF("glamor/iosurface: MakeCurrent failed (surfaceless AND "
                   "dummy pbuffer) 0x%x\n", eglGetError());
            goto error;
        }
        xwl_iosurface_fallback_surface = xwl_iosurface->dummy_surface;
        LogMessageVerb(X_INFO, 3,
                       "glamor/iosurface: using dummy-pbuffer MakeCurrent\n");
    }

    renderer = glGetString(GL_RENDERER);
    if (!renderer) {
        ErrorF("glamor/iosurface: glGetString(GL_RENDERER) NULL\n");
        goto error;
    }
    LogMessageVerb(X_INFO, 3, "glamor/iosurface: GL_RENDERER = %s\n",
                   (const char *) renderer);

    if (!epoxy_has_gl_extension("GL_EXT_texture_format_BGRA8888"))
        LogMessageVerb(X_WARNING, 0, "glamor/iosurface: no "
                       "GL_EXT_texture_format_BGRA8888; expect format trouble\n");

    return TRUE;

error:
    if (xwl_screen->egl_context != EGL_NO_CONTEXT) {
        eglMakeCurrent(xwl_screen->egl_display, EGL_NO_SURFACE,
                       EGL_NO_SURFACE, EGL_NO_CONTEXT);
        eglDestroyContext(xwl_screen->egl_display, xwl_screen->egl_context);
        xwl_screen->egl_context = EGL_NO_CONTEXT;
    }
    if (xwl_screen->egl_display != EGL_NO_DISPLAY) {
        eglTerminate(xwl_screen->egl_display);
        xwl_screen->egl_display = EGL_NO_DISPLAY;
    }
    return FALSE;
}

static Bool
xwl_glamor_iosurface_init_screen(struct xwl_screen *xwl_screen)
{
    /* No DRI3 (no client-side GPU drivers on iOS; GLX apps use swrast/SHM). */
    xwl_screen->screen->CreatePixmap = xwl_glamor_iosurface_create_pixmap;
    xwl_screen->screen->DestroyPixmap = xwl_glamor_iosurface_destroy_pixmap;

    return TRUE;
}

/* Early (before the registry round trip): allocate the screen private that
 * xwl_glamor_init_wl_registry() fills in. Stands in for xwl_glamor_init_gbm
 * (xwayland-glamor.h maps the name). */
Bool
xwl_glamor_init_iosurface(struct xwl_screen *xwl_screen)
{
    struct xwl_iosurface_private *xwl_iosurface;

    if (!dixRegisterPrivateKey(&xwl_iosurface_private_key, PRIVATE_SCREEN, 0))
        return FALSE;

    xwl_iosurface = calloc(1, sizeof(*xwl_iosurface));
    if (!xwl_iosurface) {
        ErrorF("glamor/iosurface: out of memory, disabling\n");
        return FALSE;
    }
    xwl_iosurface->dummy_surface = EGL_NO_SURFACE;

    dixSetPrivate(&xwl_screen->screen->devPrivates, &xwl_iosurface_private_key,
                  xwl_iosurface);
    return TRUE;
}

/* ---- glamor entry points (the parts of xwayland-glamor.c we replace) ------ */

static void
glamor_egl_make_current(struct glamor_context *glamor_ctx)
{
    EGLSurface s = xwl_iosurface_fallback_surface;

    eglMakeCurrent(glamor_ctx->display, EGL_NO_SURFACE,
                   EGL_NO_SURFACE, EGL_NO_CONTEXT);
    if (!eglMakeCurrent(glamor_ctx->display, s, s, glamor_ctx->ctx))
        FatalError("Failed to make EGL context current\n");
}

void
xwl_glamor_egl_make_current(struct xwl_screen *xwl_screen)
{
    EGLContext ctx = xwl_screen->glamor_ctx->ctx;

    if (lastGLContext == ctx)
        return;

    lastGLContext = ctx;
    xwl_screen->glamor_ctx->make_current(xwl_screen->glamor_ctx);
}

void
glamor_egl_screen_init(ScreenPtr screen, struct glamor_context *glamor_ctx)
{
    struct xwl_screen *xwl_screen = xwl_screen_get(screen);

    glamor_set_glvnd_vendor(screen, xwl_screen->glvnd_vendor);
    glamor_enable_dri3(screen);
    glamor_ctx->ctx = xwl_screen->egl_context;
    glamor_ctx->display = xwl_screen->egl_display;

    glamor_ctx->make_current = glamor_egl_make_current;

    xwl_screen->glamor_ctx = glamor_ctx;
}

int
glamor_egl_fd_name_from_pixmap(ScreenPtr screen,
                               PixmapPtr pixmap,
                               CARD16 *stride, CARD32 *size)
{
    return 0;
}

Bool
xwl_glamor_check_flip(WindowPtr present_window, PixmapPtr pixmap)
{
    ScreenPtr screen = pixmap->drawable.pScreen;
    PixmapPtr backing_pixmap = screen->GetWindowPixmap(present_window);

    if (pixmap->drawable.depth != backing_pixmap->drawable.depth) {
        if (pixmap->drawable.depth == 32)
            return FALSE;

        return xwl_present_maybe_redirect_window(present_window, pixmap);
    }

    return TRUE;
}

static Bool
xwl_glamor_create_screen_resources(ScreenPtr screen)
{
    struct xwl_screen *xwl_screen = xwl_screen_get(screen);
    int ret;

    screen->CreateScreenResources = xwl_screen->CreateScreenResources;
    ret = (*screen->CreateScreenResources) (screen);
    xwl_screen->CreateScreenResources = screen->CreateScreenResources;
    screen->CreateScreenResources = xwl_glamor_create_screen_resources;

    if (!ret)
        return ret;

    if (xwl_screen->rootless) {
        screen->devPrivate =
            fbCreatePixmap(screen, 0, 0, screen->rootDepth, 0);
    }
    else {
        screen->devPrivate = screen->CreatePixmap(
            screen, screen->width, screen->height, screen->rootDepth,
            CREATE_PIXMAP_USAGE_BACKING_PIXMAP);
    }

    SetRootClip(screen, xwl_screen->root_clip_mode);

    return screen->devPrivate != NULL;
}

/* No native-fence / syncobj / implicit-sync story here: sync is the Metal
 * shared event above. Present's fenced flush degrades to "no fence". */
int
xwl_glamor_get_fence(struct xwl_screen *xwl_screen)
{
    return -1;
}

void
xwl_glamor_wait_fence(struct xwl_screen *xwl_screen, int fence_fd)
{
    if (fence_fd >= 0)
        close(fence_fd);
}

/* TRUE keeps xwl_window_handle_pixmap_sync() from glamor_finish()ing (a CPU
 * stall) and from the gbm explicit-sync path; the acquire fence is attached
 * by xwl_glamor_iosurface_signal_acquire(). */
Bool
xwl_glamor_supports_implicit_sync(struct xwl_screen *xwl_screen)
{
    return TRUE;
}

Bool
xwl_glamor_supports_syncobjs(struct xwl_screen *xwl_screen)
{
    return FALSE;
}

/* ---- compat shims for gbm-only hooks in unmodified upstream files --------- */

drmDevice *
xwl_gbm_get_main_device(struct xwl_screen *xwl_screen)
{
    return NULL;                /* xwayland-dmabuf.c: no DRM device on iOS */
}

Bool
xwl_glamor_gbm_set_syncpts(struct xwl_window *xwl_window, PixmapPtr pixmap)
{
    return FALSE;
}

void
xwl_glamor_gbm_dispose_syncpts(PixmapPtr pixmap)
{
}

void
xwl_glamor_gbm_wait_syncpts(PixmapPtr pixmap)
{
}

void
xwl_glamor_gbm_wait_release_fence(struct xwl_window *xwl_window,
                                  PixmapPtr pixmap,
                                  struct xwl_window_buffer *xwl_window_buffer)
{
}

Bool
xwl_glamor_init(struct xwl_screen *xwl_screen)
{
    ScreenPtr screen = xwl_screen->screen;
    const char *no_glamor_env;

    no_glamor_env = getenv("XWAYLAND_NO_GLAMOR");
    if (no_glamor_env && *no_glamor_env != '0') {
        ErrorF("Disabling glamor and dri3 support, XWAYLAND_NO_GLAMOR is set\n");
        return FALSE;
    }

    if (!xwl_glamor_has_wl_interfaces(xwl_screen)) {
        ErrorF("Xwayland glamor: iosc_iosurface Wayland interface not available\n");
        return FALSE;
    }

    if (!xwl_glamor_iosurface_init_egl(xwl_screen)) {
        ErrorF("EGL setup failed, disabling glamor\n");
        return FALSE;
    }

    /* Surface (and drop) any GL error ANGLE has pending from EGL bring-up so
     * it cannot be mistaken for a failure of glamor's own format probes. */
    for (int i = 0; i < 16; i++) {
        GLenum e = glGetError();
        if (e == GL_NO_ERROR)
            break;
        LogMessageVerb(X_INFO, 3, "glamor/iosurface: pending GL error 0x%x "
                       "after EGL init (dropped)\n", e);
    }

    if (!glamor_init(xwl_screen->screen, GLAMOR_USE_EGL_SCREEN)) {
        ErrorF("Failed to initialize glamor\n");
        return FALSE;
    }

    if (!xwl_glamor_iosurface_init_screen(xwl_screen)) {
        ErrorF("EGL backend init_screen() failed, disabling glamor\n");
        return FALSE;
    }

    xwl_screen->CreateScreenResources = screen->CreateScreenResources;
    screen->CreateScreenResources = xwl_glamor_create_screen_resources;

#ifdef XV
    if (!xwl_glamor_xv_init(screen))
        ErrorF("Failed to initialize glamor Xv extension\n");
#endif

#ifdef GLXEXT
    GlxPushProvider(&glamor_provider);
#endif

    return TRUE;
}

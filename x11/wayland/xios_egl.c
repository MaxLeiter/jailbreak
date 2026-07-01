/*
 * xios_egl.c — shared ANGLE-Metal EGL + IOSurface plumbing. See xios_egl.h.
 *
 * Extracted verbatim (behavior-preserving) from iosc_gl.c's "job 1": the ANGLE
 * Metal display bring-up, the pbuffer+bind-to-texture config, and the IOSurface
 * client-buffer pbuffer/texture bridging. iosc_gl.c now calls these; a future
 * MetaRendererIOS Cogl winsys links the same code.
 */
#include "xios_egl.h"
#include "xios_surface.h"

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>
#include <GLES2/gl2ext.h>

#include <stdio.h>

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
#ifndef EGL_GL_TEXTURE_2D_KHR
#define EGL_GL_TEXTURE_2D_KHR               0x30B1
#endif

/* ---- shared display / config / context ----------------------------------- */

static int        s_inited = 0;
static EGLDisplay s_dpy = EGL_NO_DISPLAY;
static EGLConfig  s_config = 0;
static EGLContext s_ctx = EGL_NO_CONTEXT;

EGLDisplay xios_egl_display(void)
{
    if (s_inited) return s_dpy;
    s_inited = 1;   /* one-shot: even on failure, don't retry the whole bring-up */

    EGLDisplay (*getPlatformDisplay)(EGLenum, void *, const EGLint *) =
        (void *) eglGetProcAddress("eglGetPlatformDisplayEXT");
    if (!getPlatformDisplay) {
        fprintf(stderr, "xios_egl: no eglGetPlatformDisplayEXT\n");
        return EGL_NO_DISPLAY;
    }
    const EGLint da[] = { EGL_PLATFORM_ANGLE_TYPE_ANGLE,
                          EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE, EGL_NONE };
    s_dpy = getPlatformDisplay(EGL_PLATFORM_ANGLE_ANGLE, EGL_DEFAULT_DISPLAY, da);
    if (s_dpy == EGL_NO_DISPLAY) {
        fprintf(stderr, "xios_egl: getPlatformDisplay failed\n");
        return EGL_NO_DISPLAY;
    }
    EGLint maj = 0, min = 0;
    if (!eglInitialize(s_dpy, &maj, &min)) {
        fprintf(stderr, "xios_egl: eglInitialize failed\n");
        s_dpy = EGL_NO_DISPLAY;
        return EGL_NO_DISPLAY;
    }

    const EGLint cfg[] = {
        EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
        EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
        EGL_BIND_TO_TEXTURE_RGBA, EGL_TRUE,
        EGL_NONE };
    EGLint n = 0;
    if (!eglChooseConfig(s_dpy, cfg, &s_config, 1, &n) || n == 0) {
        fprintf(stderr, "xios_egl: eglChooseConfig failed\n");
        s_dpy = EGL_NO_DISPLAY;
        return EGL_NO_DISPLAY;
    }
    return s_dpy;
}

EGLConfig xios_egl_config(void)
{
    if (!s_inited) xios_egl_display();
    return s_config;
}

EGLContext xios_egl_context(int es_version)
{
    if (s_ctx != EGL_NO_CONTEXT) return s_ctx;
    if (xios_egl_display() == EGL_NO_DISPLAY) return EGL_NO_CONTEXT;
    const EGLint ca[] = { EGL_CONTEXT_CLIENT_VERSION, es_version >= 3 ? 3 : 2, EGL_NONE };
    s_ctx = eglCreateContext(s_dpy, s_config, EGL_NO_CONTEXT, ca);
    if (s_ctx == EGL_NO_CONTEXT)
        fprintf(stderr, "xios_egl: eglCreateContext failed 0x%x\n", eglGetError());
    return s_ctx;
}

/* ---- IOSurface <-> GL ----------------------------------------------------- */

EGLSurface xios_egl_create_iosurface_pbuffer(void *iosurface, int w, int h)
{
    if (xios_egl_display() == EGL_NO_DISPLAY) return EGL_NO_SURFACE;
    const EGLint attrs[] = {
        EGL_WIDTH, w, EGL_HEIGHT, h,
        EGL_IOSURFACE_PLANE_ANGLE, 0,
        EGL_TEXTURE_TARGET, EGL_TEXTURE_2D,
        EGL_TEXTURE_INTERNAL_FORMAT_ANGLE, GL_BGRA_EXT,
        EGL_TEXTURE_FORMAT, EGL_TEXTURE_RGBA,
        EGL_TEXTURE_TYPE_ANGLE, GL_UNSIGNED_BYTE,
        EGL_NONE };
    EGLSurface pb = eglCreatePbufferFromClientBuffer(s_dpy, EGL_IOSURFACE_ANGLE,
                        (EGLClientBuffer) iosurface, s_config, attrs);
    if (pb == EGL_NO_SURFACE)
        fprintf(stderr, "xios_egl: pbuffer from IOSurface failed 0x%x\n", eglGetError());
    return pb;
}

unsigned xios_egl_bind_pbuffer_texture(EGLSurface pb)
{
    GLuint tex = 0;
    glGenTextures(1, &tex);
    glBindTexture(GL_TEXTURE_2D, tex);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    eglBindTexImage(s_dpy, pb, EGL_BACK_BUFFER);
    return tex;
}

void xios_egl_destroy_pbuffer(EGLSurface pb)
{
    if (pb == EGL_NO_SURFACE || s_dpy == EGL_NO_DISPLAY) return;
    eglReleaseTexImage(s_dpy, pb, EGL_BACK_BUFFER);
    eglDestroySurface(s_dpy, pb);
}

/* ---- IOSurface -> EGLImage (for the Cogl/Wayland buffer type) ------------- */

/* eglCreateImageKHR / eglDestroyImageKHR are extension entry points. */
static EGLImageKHR (*s_create_image)(EGLDisplay, EGLContext, EGLenum, EGLClientBuffer, const EGLint *);
static EGLBoolean  (*s_destroy_image)(EGLDisplay, EGLImageKHR);

/* Retain each image's backing pbuffer + GL texture so it stays valid until
 * xios_egl_destroy_image. */
#define XIOS_EGL_MAX_IMAGES 64
static struct { EGLImageKHR img; EGLSurface pb; GLuint tex; } s_images[XIOS_EGL_MAX_IMAGES];

EGLImageKHR xios_egl_image_from_iosurface(void *iosurface, int width, int height)
{
    if (xios_egl_display() == EGL_NO_DISPLAY) return EGL_NO_IMAGE_KHR;
    EGLContext ctx = xios_egl_context(2);
    if (ctx == EGL_NO_CONTEXT) return EGL_NO_IMAGE_KHR;

    if (!s_create_image) {
        s_create_image  = (void *) eglGetProcAddress("eglCreateImageKHR");
        s_destroy_image = (void *) eglGetProcAddress("eglDestroyImageKHR");
    }
    if (!s_create_image || !s_destroy_image) {
        fprintf(stderr, "xios_egl: no eglCreateImageKHR (EGL_KHR_image_base)\n");
        return EGL_NO_IMAGE_KHR;
    }

    EGLSurface pb = xios_egl_create_iosurface_pbuffer(iosurface, width, height);
    if (pb == EGL_NO_SURFACE) return EGL_NO_IMAGE_KHR;

    /* Bind the IOSurface to a GL texture in our context, then wrap that texture as
     * an EGLImage. Save + restore the caller's current binding so this is safe to
     * call from inside a Cogl frame. */
    EGLDisplay pdpy = eglGetCurrentDisplay();
    EGLContext pctx = eglGetCurrentContext();
    EGLSurface pdraw = eglGetCurrentSurface(EGL_DRAW);
    EGLSurface pread = eglGetCurrentSurface(EGL_READ);

    if (!eglMakeCurrent(s_dpy, pb, pb, ctx)) {
        fprintf(stderr, "xios_egl: image makeCurrent failed 0x%x\n", eglGetError());
        xios_egl_destroy_pbuffer(pb);
        return EGL_NO_IMAGE_KHR;
    }
    GLuint tex = xios_egl_bind_pbuffer_texture(pb);
    const EGLint img_attrs[] = { EGL_IMAGE_PRESERVED_KHR, EGL_TRUE, EGL_NONE };
    EGLImageKHR img = s_create_image(s_dpy, ctx, EGL_GL_TEXTURE_2D_KHR,
                                     (EGLClientBuffer)(uintptr_t) tex, img_attrs);

    /* restore the caller's context (NULL fields become EGL_NO_* -> release) */
    if (pdpy == EGL_NO_DISPLAY) pdpy = s_dpy;
    eglMakeCurrent(pdpy, pdraw, pread, pctx);

    if (img == EGL_NO_IMAGE_KHR) {
        fprintf(stderr, "xios_egl: eglCreateImageKHR(GL_TEXTURE_2D) failed 0x%x\n", eglGetError());
        glDeleteTextures(1, &tex);
        xios_egl_destroy_pbuffer(pb);
        return EGL_NO_IMAGE_KHR;
    }
    for (int i = 0; i < XIOS_EGL_MAX_IMAGES; i++)
        if (s_images[i].img == EGL_NO_IMAGE_KHR) {
            s_images[i].img = img; s_images[i].pb = pb; s_images[i].tex = tex;
            return img;
        }
    fprintf(stderr, "xios_egl: image retain table full; leaking backing pbuffer\n");
    return img;
}

void xios_egl_destroy_image(EGLImageKHR image)
{
    if (image == EGL_NO_IMAGE_KHR || s_dpy == EGL_NO_DISPLAY) return;
    if (s_destroy_image) s_destroy_image(s_dpy, image);
    for (int i = 0; i < XIOS_EGL_MAX_IMAGES; i++)
        if (s_images[i].img == image) {
            if (s_images[i].tex) glDeleteTextures(1, &s_images[i].tex);
            xios_egl_destroy_pbuffer(s_images[i].pb);
            s_images[i].img = EGL_NO_IMAGE_KHR; s_images[i].pb = EGL_NO_SURFACE; s_images[i].tex = 0;
            return;
        }
}

/* ---- output geometry / scale --------------------------------------------- */

static float s_scale = 2.0f;

void xios_output_geometry(int *width, int *height)
{
    /* Backed by the created output IOSurface's dimensions (xios_surface). */
    xios_surface_geometry(width, height);
}

float xios_output_scale(void) { return s_scale > 0.f ? s_scale : 1.f; }
void  xios_output_set_scale(float scale) { if (scale > 0.f) s_scale = scale; }

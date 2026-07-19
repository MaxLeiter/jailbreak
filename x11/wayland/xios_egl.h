/*
 * xios_egl.{c,h} — shared ANGLE-Metal EGL + IOSurface plumbing (libxios_glue).
 *
 * "Job 1" of the split in docs/iosc-shared-glue.md: the EGL/ANGLE-Metal
 * display/config/context and the IOSurface<->GL bridging. This is the code that
 * BOTH iosc's own compositor (iosc_gl.c) and Mutter's MetaRendererIOS Cogl custom
 * winsys need, and neither should fork. iosc_gl.c keeps "job 2" (shaders, the
 * placement/flip conventions, the draw loop) and calls into here for the EGL bits.
 *
 * Nothing in here is iosc- or Mutter-specific: it is pure ANGLE-Metal + IOSurface.
 * The symbols marked "MetaBackendIOS contract" match x11/wayland/xios-glue-stub.h — that
 * header is the contract MetaBackendIOS compiles against off-device.
 */
#ifndef XIOS_EGL_H
#define XIOS_EGL_H

#include <stdint.h>
#include <EGL/egl.h>
#include <EGL/eglext.h>

/* ---- the shared ANGLE-Metal display / config / context ------------------- */

/* Lazily create + initialize the ANGLE-Metal EGLDisplay (idempotent; the first
 * call sets it up, later calls return it). EGL_NO_DISPLAY on failure. */
EGLDisplay xios_egl_display(void);

/* The pbuffer + RGBA8 + BIND_TO_TEXTURE_RGBA config used for IOSurface pbuffers
 * (chosen once against the display). EGL_NO_CONFIG_KHR-equivalent NULL on failure. */
EGLConfig  xios_egl_config(void);

/* A shared GLES context against (display, config). `es_version` is 2 or 3; the
 * first caller's version wins and later calls return the same context. The Cogl
 * winsys may instead create its OWN context that SHARES with this one (pass this
 * as the share context) so client-IOSurface textures/images are mutually usable.
 * EGL_NO_CONTEXT on failure. */
EGLContext xios_egl_context(int es_version);

/* ---- IOSurface <-> GL bridging ------------------------------------------- */

/* Wrap a BGRA IOSurface (opaque IOSurfaceRef) as an ANGLE pbuffer via
 * EGL_ANGLE_iosurface_client_buffer. No GL calls -> safe before any context is
 * current. `w`/`h` are the surface dimensions. EGL_NO_SURFACE on failure. */
EGLSurface xios_egl_create_iosurface_pbuffer(void *iosurface, int w, int h);

/* Bind a pbuffer's IOSurface to a fresh GL_TEXTURE_2D (needs a current context).
 * Returns the GL texture name (a GLuint), or 0 on failure. */
unsigned   xios_egl_bind_pbuffer_texture(EGLSurface pb);

/* Release (eglReleaseTexImage) + destroy a pbuffer from
 * xios_egl_create_iosurface_pbuffer. The caller owns any GL texture it made. */
void       xios_egl_destroy_pbuffer(EGLSurface pb);

/* ---- MetaBackendIOS contract: IOSurface -> EGLImage -----------------------
 * MetaWaylandBuffer wants an EGLImageKHR to feed cogl_egl_texture_2d_new_from_image
 * (the same path mutter uses for EGL_IMAGE / dma-buf). ANGLE-Metal exposes no
 * direct IOSurface->EGLImage, so this bridges via the proven route:
 *   IOSurface -> ANGLE pbuffer -> GL_TEXTURE_2D -> eglCreateImageKHR(EGL_GL_TEXTURE_2D).
 * It saves/restores the caller's current context (making xios_egl_context current
 * on the pbuffer only long enough to bind the texture), so it is safe to call from
 * a Cogl context. The backing pbuffer+texture are retained until
 * xios_egl_destroy_image(). REQUIRES xios_egl_context() to have been created.
 * EGL_NO_IMAGE_KHR on failure. Signatures match xios-glue-stub.h. */
EGLImageKHR xios_egl_image_from_iosurface(void *iosurface, int width, int height);
void        xios_egl_destroy_image(EGLImageKHR image);

/* ---- MetaBackendIOS contract: output geometry / scale ---------------------
 * Geometry is the created output IOSurface's size (from xios_surface). Scale is a
 * glue-held value (default 2.0; set with xios_output_set_scale — iosc uses its own
 * output_scale(), the mutter backend sets this). Signatures match xios-glue-stub.h. */
void  xios_output_geometry(int *width, int *height);
float xios_output_scale(void);
void  xios_output_set_scale(float scale);

#endif /* XIOS_EGL_H */

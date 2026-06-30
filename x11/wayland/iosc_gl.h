/*
 * iosc_gl.h — ANGLE (GLES→Metal) GPU compositor for iosc.
 *
 * iosc holds one EGL context whose render target is the OUTPUT IOSurface (the
 * surface the Xios app presents via Metal). Each committed client buffer is drawn
 * as a textured quad into that output on the GPU. For a client that handed over an
 * IOSurface (the ANGLE-Metal GPU path), the surface is adopted directly as a
 * GL/Metal texture (EGL_ANGLE_iosurface_client_buffer) and sampled — NO CPU copy,
 * the whole per-frame path stays on the GPU. wl_shm buffers are CPU pixels, so they
 * cost one glTexImage2D upload. All EGL/GLES code is isolated here so iosc.c stays
 * free of GL headers; the caller falls back to the CPU blit if init fails.
 */
#ifndef IOSC_GL_H
#define IOSC_GL_H

#include <stdint.h>

/* Set up the EGL context + output framebuffer bound to `output_iosurface`
 * (opaque IOSurfaceRef) at w x h. 0 on success; nonzero => use the CPU fallback. */
int  iosc_gl_init(void *output_iosurface, int w, int h);

/* True once iosc_gl_init() has succeeded. */
int  iosc_gl_ok(void);

/* Begin a frame: bind the output FBO and clear to black. */
void iosc_gl_begin(void);

/* Draw a client IOSurface (opaque IOSurfaceRef) of source size sw x sh as a quad
 * at output-pixel dest rect (dx,dy,dw,dh). Zero-copy: the IOSurface is sampled
 * directly as a GL/Metal texture (the texture is sized to the surface, sw x sh). */
void iosc_gl_draw_iosurface(void *client_iosurface, int sw, int sh,
                            int sx, int sy, int src_w, int src_h,
                            int dx, int dy, int dw, int dh);

/* Draw a wl_shm BGRA buffer (one CPU->GPU upload) as a quad at the dest rect. */
void iosc_gl_draw_shm(const void *data, int sw, int sh, int stride,
                      int sx, int sy, int src_w, int src_h,
                      int dx, int dy, int dw, int dh);

/* End the frame: flush so the output IOSurface is ready to present. Returns the
 * composited output center pixel (BGRA, via glReadPixels) for validation. */
uint32_t iosc_gl_end(void);

/* Read one composited output pixel (BGRA) at top-left coord (x,y) — validation
 * (proves a given window's content landed at its placement). Call after iosc_gl_end. */
uint32_t iosc_gl_read_at(int x, int y);

/* Drop the cached pbuffer/texture for a client IOSurface that is going away. */
void iosc_gl_forget_iosurface(void *client_iosurface);

#endif /* IOSC_GL_H */

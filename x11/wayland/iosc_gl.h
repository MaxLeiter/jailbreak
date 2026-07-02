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

/* Rebind the render target to a NEW output IOSurface at w x h (device rotation:
 * iosc reallocated the output via xios_surface_resize). The EGL display/context,
 * shader program, and the client-surface texture cache all survive; only the
 * output pbuffer/texture/FBO are torn down and rebuilt. 0 on success; on failure
 * the GPU path is marked unavailable (iosc_gl_ok() false => CPU fallback). */
int  iosc_gl_resize(void *output_iosurface, int w, int h);

/* Rebind the current EGL render target/FBO to an IOSurface without recreating the
 * context, shader program, or client texture caches. This is the native-iPadOS
 * per-window hook: callers can bind a window canvas, draw, end, then bind another
 * canvas. It is also the implementation behind iosc_gl_resize(). */
int  iosc_gl_bind_target(void *iosurface, int w, int h);

/* Begin a frame: bind the output FBO and clear to black. */
void iosc_gl_begin(void);

/* Draw a client IOSurface (opaque IOSurfaceRef) of source size sw x sh as a quad
 * at output-pixel dest rect (dx,dy,dw,dh). Zero-copy: the IOSurface is sampled
 * directly as a GL/Metal texture (the texture is sized to the surface, sw x sh). */
void iosc_gl_draw_iosurface(void *client_iosurface, int sw, int sh,
                            int sx, int sy, int src_w, int src_h,
                            int dx, int dy, int dw, int dh);

/* Draw a wl_shm BGRA buffer as a quad at the dest rect. `key` (a stable
 * per-surface pointer) caches one GL texture per surface: the buffer is uploaded
 * only when `dirty` (or the size changed), so an unchanged surface re-drawn on a
 * cursor-move repaint costs no upload. Pass key=NULL for transient/uncached
 * buffers (single-pixel, the procedural cursor); those always upload. */
void iosc_gl_draw_shm(void *key, int dirty, const void *data, int sw, int sh, int stride,
                      int sx, int sy, int src_w, int src_h,
                      int dx, int dy, int dw, int dh);

/* Drop the cached texture for a surface `key` that is going away (its address may
 * be reused by a later surface). Safe to call for keys that were never cached. */
void iosc_gl_forget_shm(void *key);

/* End the frame: kick the GPU and block on a per-frame fence (glFinish fallback)
 * so the output IOSurface is fully composited before the Xios app presents it. */
void iosc_gl_end(void);

/* Read one composited output pixel (BGRA) at top-left coord (x,y) — validation
 * (proves a given window's content landed at its placement). Call after iosc_gl_end. */
uint32_t iosc_gl_read_at(int x, int y);

/* Read the composited output center pixel (BGRA) — validation only (IOSC_DEBUG). */
uint32_t iosc_gl_read_center(void);

/* Wrap a composite in premultiplied-alpha blending so the buffer's real alpha is
 * honored (source-over) instead of drawing opaque. Used for the cursor and DnD
 * icon (transparent around the artwork) and for layer-shell surfaces (the shell's
 * translucent panel/overview chrome). Call begin before the draw and end after;
 * windows draw between frames with blending off and alpha forced opaque. */
void iosc_gl_begin_blend(void);
void iosc_gl_end_blend(void);

/* Drop the cached pbuffer/texture for a client IOSurface that is going away. */
void iosc_gl_forget_iosurface(void *client_iosurface);

#endif /* IOSC_GL_H */

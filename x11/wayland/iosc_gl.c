/*
 * iosc_gl.c — ANGLE GLES→Metal GPU compositor for iosc. See iosc_gl.h.
 *
 * Zero-copy path: a client IOSurface is bound as a GL texture via
 * EGL_ANGLE_iosurface_client_buffer (the GL equivalent of makeTexture(iosurface:))
 * and sampled while rendering into the output IOSurface's FBO — no memcpy.
 */
#include "iosc_gl.h"
#include "xios_egl.h"           /* shared ANGLE-Metal EGL + IOSurface plumbing (job 1) */

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>
#include <GLES2/gl2ext.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifndef GL_BGRA_EXT
#define GL_BGRA_EXT                         0x80E1
#endif

/* ---- state --------------------------------------------------------------- */

static int s_ok = 0;
static int s_ow = 0, s_oh = 0;

/* The display/config/context live in xios_egl (shared); iosc_gl caches the display
 * only for the one eglMakeCurrent in init. */
static EGLDisplay s_dpy = EGL_NO_DISPLAY;
static EGLSurface s_out_pb = EGL_NO_SURFACE;   /* pbuffer bound to output IOSurface */
static GLuint     s_out_tex = 0;               /* output IOSurface as a GL texture   */
static GLuint     s_fbo = 0;                   /* renders into s_out_tex             */

static GLuint s_prog = 0;
static GLint  s_a_pos = -1, s_a_uv = -1, s_u_tex = -1, s_u_opaque = -1;
static GLuint s_shm_tex = 0;                   /* reused upload texture for wl_shm    */
static float  s_opaque = 1.f;                  /* 1 = force opaque (windows); 0 = keep alpha (cursor) */

/* small cache: client IOSurface -> its sampling pbuffer + texture */
#define MAXBUF 16
static struct { void *surf; EGLSurface pb; GLuint tex; } s_cache[MAXBUF];

/* Per-frame completion fence (EGL_KHR_fence_sync). Resolved at init; NULL => the
 * extension is unavailable and iosc_gl_end() falls back to glFinish. */
#ifdef EGL_KHR_fence_sync
static PFNEGLCREATESYNCKHRPROC     s_create_sync;
static PFNEGLCLIENTWAITSYNCKHRPROC s_client_wait_sync;
static PFNEGLDESTROYSYNCKHRPROC    s_destroy_sync;
#endif

/* ---- helpers ------------------------------------------------------------- */

static GLuint compile(GLenum type, const char *src)
{
    GLuint s = glCreateShader(type);
    glShaderSource(s, 1, &src, NULL);
    glCompileShader(s);
    GLint ok = 0; glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
    if (!ok) { char log[512]; glGetShaderInfoLog(s, sizeof log, NULL, log);
               fprintf(stderr, "iosc_gl: shader compile: %s\n", log); }
    return s;
}

/* Make an ANGLE pbuffer + bound GL texture (context must be current). The EGL
 * mechanics live in xios_egl (shared with the Mutter backend). */
static int make_iosurface_tex_wh(void *iosurface, int w, int h,
                                 EGLSurface *out_pb, GLuint *out_tex)
{
    EGLSurface pb = xios_egl_create_iosurface_pbuffer(iosurface, w, h);
    if (pb == EGL_NO_SURFACE) return -1;
    *out_pb = pb; *out_tex = xios_egl_bind_pbuffer_texture(pb);
    return 0;
}

static GLuint cache_get(void *surf, int w, int h)
{
    for (int i = 0; i < MAXBUF; i++)
        if (s_cache[i].surf == surf) return s_cache[i].tex;
    for (int i = 0; i < MAXBUF; i++) {
        if (s_cache[i].surf == NULL) {
            EGLSurface pb; GLuint tex;
            if (make_iosurface_tex_wh(surf, w, h, &pb, &tex) != 0) return 0;
            s_cache[i].surf = surf; s_cache[i].pb = pb; s_cache[i].tex = tex;
            return tex;
        }
    }
    fprintf(stderr, "iosc_gl: IOSurface texture cache full\n");
    return 0;
}

/* ---- public -------------------------------------------------------------- */

int iosc_gl_init(void *output_iosurface, int w, int h)
{
    s_ow = w; s_oh = h;

    /* The ANGLE-Metal display / config / ES2 context now come from xios_egl (the
     * shared glue). Same bring-up as before, just factored out. */
    s_dpy = xios_egl_display();
    if (s_dpy == EGL_NO_DISPLAY) { fprintf(stderr, "iosc_gl: xios_egl_display failed\n"); return -1; }
    EGLContext ctx = xios_egl_context(2);
    if (ctx == EGL_NO_CONTEXT) { fprintf(stderr, "iosc_gl: xios_egl_context failed\n"); return -1; }

    /* The output IOSurface as a render target. Create the pbuffer FIRST, make the
     * context current on it, THEN create the GL texture + FBO (GL calls need a
     * current context, so this ordering matters). */
    s_out_pb = xios_egl_create_iosurface_pbuffer(output_iosurface, w, h);
    if (s_out_pb == EGL_NO_SURFACE) return -1;
    if (!eglMakeCurrent(s_dpy, s_out_pb, s_out_pb, ctx)) {
        fprintf(stderr, "iosc_gl: eglMakeCurrent failed 0x%x\n", eglGetError()); return -1; }
    fprintf(stderr, "iosc_gl: GL_RENDERER=%s\n", glGetString(GL_RENDERER));
    s_out_tex = xios_egl_bind_pbuffer_texture(s_out_pb);

    glGenFramebuffers(1, &s_fbo);
    glBindFramebuffer(GL_FRAMEBUFFER, s_fbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, s_out_tex, 0);
    GLenum fb_status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    if (fb_status != GL_FRAMEBUFFER_COMPLETE) {
        fprintf(stderr, "iosc_gl: output FBO incomplete 0x%x\n", fb_status);
        return -1;
    }

    const char *vs =
        "attribute vec2 pos; attribute vec2 uv; varying vec2 v;\n"
        "void main(){ v = uv; gl_Position = vec4(pos, 0.0, 1.0); }\n";
    const char *fs =
        "precision mediump float; varying vec2 v; uniform sampler2D t; uniform float opaque;\n"
        /* Windows (opaque=1): XRGB8888 wl_shm buffers have undefined alpha and windows
         * are opaque, so force alpha=1 to avoid transparent output. The cursor is an
         * ARGB8888 (premultiplied) wl_shm buffer with a real alpha channel, so it draws
         * with opaque=0 to keep its alpha (blended premultiplied by the caller). */
        "void main(){ vec4 c = texture2D(t, v); gl_FragColor = vec4(c.rgb, mix(c.a, 1.0, opaque)); }\n";
    s_prog = glCreateProgram();
    glAttachShader(s_prog, compile(GL_VERTEX_SHADER, vs));
    glAttachShader(s_prog, compile(GL_FRAGMENT_SHADER, fs));
    glLinkProgram(s_prog);
    GLint linked = 0; glGetProgramiv(s_prog, GL_LINK_STATUS, &linked);
    if (!linked) { fprintf(stderr, "iosc_gl: program link failed\n"); return -1; }
    s_a_pos = glGetAttribLocation(s_prog, "pos");
    s_a_uv  = glGetAttribLocation(s_prog, "uv");
    s_u_tex = glGetUniformLocation(s_prog, "t");
    s_u_opaque = glGetUniformLocation(s_prog, "opaque");

    glGenTextures(1, &s_shm_tex);

    /* Prefer a per-frame fence over glFinish for the present barrier. */
#ifdef EGL_KHR_fence_sync
    const char *egl_exts = eglQueryString(s_dpy, EGL_EXTENSIONS);
    if (egl_exts && strstr(egl_exts, "EGL_KHR_fence_sync")) {
        s_create_sync     = (PFNEGLCREATESYNCKHRPROC)eglGetProcAddress("eglCreateSyncKHR");
        s_client_wait_sync = (PFNEGLCLIENTWAITSYNCKHRPROC)eglGetProcAddress("eglClientWaitSyncKHR");
        s_destroy_sync    = (PFNEGLDESTROYSYNCKHRPROC)eglGetProcAddress("eglDestroySyncKHR");
        if (!s_create_sync || !s_client_wait_sync || !s_destroy_sync)
            s_create_sync = NULL;   /* partial: fall back to glFinish */
    }
    fprintf(stderr, "iosc_gl: frame barrier = %s\n", s_create_sync ? "EGL fence" : "glFinish");
#endif

    s_ok = 1;
    fprintf(stderr, "iosc_gl: GPU compositor ready (output %dx%d)\n", w, h);
    return 0;
}

int iosc_gl_ok(void) { return s_ok; }

int iosc_gl_resize(void *output_iosurface, int w, int h)
{
    if (!s_ok) return -1;
    EGLContext ctx = xios_egl_context(2);

    /* Bring up the NEW target first so a failure leaves the old one intact. */
    EGLSurface new_pb = xios_egl_create_iosurface_pbuffer(output_iosurface, w, h);
    if (new_pb == EGL_NO_SURFACE) {
        fprintf(stderr, "iosc_gl: resize pbuffer failed -> CPU fallback\n");
        s_ok = 0;
        return -1;
    }
    if (!eglMakeCurrent(s_dpy, new_pb, new_pb, ctx)) {
        fprintf(stderr, "iosc_gl: resize eglMakeCurrent failed 0x%x\n", eglGetError());
        xios_egl_destroy_pbuffer(new_pb);
        s_ok = 0;
        return -1;
    }
    GLuint new_tex = xios_egl_bind_pbuffer_texture(new_pb);

    /* Old target: GL objects belong to the (shared, still-current) context, so
     * they can be deleted with the new surface current. */
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    if (s_fbo) { glDeleteFramebuffers(1, &s_fbo); s_fbo = 0; }
    if (s_out_tex) { glDeleteTextures(1, &s_out_tex); s_out_tex = 0; }
    if (s_out_pb != EGL_NO_SURFACE) xios_egl_destroy_pbuffer(s_out_pb);

    s_out_pb = new_pb;
    s_out_tex = new_tex;
    glGenFramebuffers(1, &s_fbo);
    glBindFramebuffer(GL_FRAMEBUFFER, s_fbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, s_out_tex, 0);
    GLenum fb_status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    if (fb_status != GL_FRAMEBUFFER_COMPLETE) {
        fprintf(stderr, "iosc_gl: resize FBO incomplete 0x%x -> CPU fallback\n", fb_status);
        s_ok = 0;
        return -1;
    }
    s_ow = w; s_oh = h;
    fprintf(stderr, "iosc_gl: output rebound (%dx%d)\n", w, h);
    return 0;
}

void iosc_gl_begin(void)
{
    glBindFramebuffer(GL_FRAMEBUFFER, s_fbo);
    glViewport(0, 0, s_ow, s_oh);
    glClearColor(0.f, 0.f, 0.f, 1.f);
    glClear(GL_COLOR_BUFFER_BIT);
}

/* Draw the currently-bound texture as a quad covering output dest rect. Two vertical
 * conventions, both confirmed on-device 2026-06-30 by app-space readback:
 *
 *  1. PLACEMENT: the Xios app samples the output IOSurface VERTICALLY MIRRORED vs
 *     GL's framebuffer (GL NDC +1 / "top" lands at the app's BOTTOM — a window at
 *     dest-y[40..1000] showed up at app-y[620..1580]). So invert the dest-y -> clip-y
 *     mapping (dest-top -> NDC bottom) to cancel that mirror. Source-independent.
 *
 *  2. CONTENT (flip_v): a wl_shm buffer is top-left (row 0 = window top), so v=0 is
 *     its top (flip_v=0). A client IOSurface was itself rendered by ANGLE/GL and is
 *     pre-mirrored in its own memory (its v=0 is the BOTTOM of its image), so it must
 *     be sampled with V flipped (flip_v=1) to come out upright. Without this the GPU
 *     triangle showed apex-down (wide at top, narrow at bottom). */
static void draw_quad(int dx, int dy, int dw, int dh,
                      float u0, float v0, float u1, float v1, int flip_v)
{
    float x0 = (float)dx / s_ow * 2.f - 1.f;
    float x1 = (float)(dx + dw) / s_ow * 2.f - 1.f;
    float yt = (float)dy / s_oh * 2.f - 1.f;          /* dest top -> NDC bottom (app mirror) */
    float yb = (float)(dy + dh) / s_oh * 2.f - 1.f;   /* dest bottom -> NDC top              */
    float vt = flip_v ? v1 : v0;                      /* V sampled at the dest top  */
    float vb = flip_v ? v0 : v1;                      /* V sampled at the dest bottom */
    const GLfloat verts[] = {
        x0, yt, u0, vt,
        x0, yb, u0, vb,
        x1, yt, u1, vt,
        x1, yb, u1, vb,
    };
    glUseProgram(s_prog);
    glUniform1i(s_u_tex, 0);
    glUniform1f(s_u_opaque, s_opaque);
    glVertexAttribPointer(s_a_pos, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(GLfloat), verts);
    glEnableVertexAttribArray(s_a_pos);
    glVertexAttribPointer(s_a_uv, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(GLfloat), verts + 2);
    glEnableVertexAttribArray(s_a_uv);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
}

void iosc_gl_draw_iosurface(void *client_iosurface, int sw, int sh,
                            int sx, int sy, int src_w, int src_h,
                            int dx, int dy, int dw, int dh)
{
    GLuint tex = cache_get(client_iosurface, sw, sh);   /* texture sized to the surface */
    if (!tex) return;
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, tex);
    draw_quad(dx, dy, dw, dh,
              (float)sx / sw, (float)sy / sh,
              (float)(sx + src_w) / sw, (float)(sy + src_h) / sh,
              1);   /* ANGLE-rendered client IOSurface: flip V */
}

/* Per-key (per-surface) wl_shm texture cache. Without it, recomposite_all
 * re-uploads every window's whole buffer (e.g. 2160x1620x4 = 14MB) on EVERY
 * frame — including cursor-move repaints that changed no window content. With
 * it, a surface is uploaded only when it committed new content (its `dirty`
 * flag); an idle window under a moving cursor uploads nothing. */
#define MAXSHM 24
static struct { void *key; GLuint tex; int w, h; } s_shm_cache[MAXSHM];

/* Bind the texture for `key` (allocating one on first use), reporting whether
 * its storage must be (re)allocated at sw x sh. Returns 0 if the cache is full. */
static GLuint shm_cache_bind(void *key, int sw, int sh, int *need_alloc)
{
    int free_slot = -1;
    for (int i = 0; i < MAXSHM; i++) {
        if (s_shm_cache[i].key == key) {
            *need_alloc = (s_shm_cache[i].w != sw || s_shm_cache[i].h != sh);
            s_shm_cache[i].w = sw; s_shm_cache[i].h = sh;
            glBindTexture(GL_TEXTURE_2D, s_shm_cache[i].tex);
            return s_shm_cache[i].tex;
        }
        if (free_slot < 0 && s_shm_cache[i].key == NULL) free_slot = i;
    }
    if (free_slot < 0) return 0;   /* cache full: caller falls back to s_shm_tex */
    GLuint tex = 0;
    glGenTextures(1, &tex);
    glBindTexture(GL_TEXTURE_2D, tex);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    s_shm_cache[free_slot].key = key;
    s_shm_cache[free_slot].tex = tex;
    s_shm_cache[free_slot].w = sw;
    s_shm_cache[free_slot].h = sh;
    *need_alloc = 1;
    return tex;
}

/* Upload `data` into the currently-bound texture: (re)allocate at sw x sh when
 * need_alloc, otherwise update in place. GLES2 has no UNPACK_ROW_LENGTH, so a
 * padded stride goes row by row (most wl_shm buffers are tight). */
static void shm_upload(const void *data, int sw, int sh, int stride, int need_alloc)
{
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    int tight = (stride == sw * 4);
    if (need_alloc) {
        glTexImage2D(GL_TEXTURE_2D, 0, GL_BGRA_EXT, sw, sh, 0, GL_BGRA_EXT,
                     GL_UNSIGNED_BYTE, tight ? data : NULL);
        if (tight) return;
    } else if (tight) {
        glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, sw, sh, GL_BGRA_EXT,
                        GL_UNSIGNED_BYTE, data);
        return;
    }
    const unsigned char *p = data;
    for (int y = 0; y < sh; y++)
        glTexSubImage2D(GL_TEXTURE_2D, 0, 0, y, sw, 1, GL_BGRA_EXT,
                        GL_UNSIGNED_BYTE, p + (size_t)y * stride);
}

void iosc_gl_draw_shm(void *key, int dirty, const void *data, int sw, int sh, int stride,
                      int sx, int sy, int src_w, int src_h,
                      int dx, int dy, int dw, int dh)
{
    glActiveTexture(GL_TEXTURE0);
    int need_alloc = 1;
    if (key) {
        GLuint tex = shm_cache_bind(key, sw, sh, &need_alloc);
        if (tex) {
            if (dirty || need_alloc) shm_upload(data, sw, sh, stride, need_alloc);
        } else {
            key = NULL;   /* cache full: fall through to the shared upload texture */
        }
    }
    if (!key) {
        /* Uncached path (spb, named cursor, cache-full fallback): the shared
         * texture is reused across sizes/sources, so always (re)allocate + upload. */
        glBindTexture(GL_TEXTURE_2D, s_shm_tex);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        shm_upload(data, sw, sh, stride, 1);
    }
    draw_quad(dx, dy, dw, dh,
              (float)sx / sw, (float)sy / sh,
              (float)(sx + src_w) / sw, (float)(sy + src_h) / sh,
              0);   /* wl_shm is top-left (v=0 = top): no V flip */
}

void iosc_gl_forget_shm(void *key)
{
    for (int i = 0; i < MAXSHM; i++) {
        if (s_shm_cache[i].key == key) {
            if (s_shm_cache[i].tex) glDeleteTextures(1, &s_shm_cache[i].tex);
            s_shm_cache[i].key = NULL; s_shm_cache[i].tex = 0;
            s_shm_cache[i].w = s_shm_cache[i].h = 0;
            return;
        }
    }
}

void iosc_gl_end(void)
{
    /* Barrier before the (separate-process) Xios app presents the output IOSurface
     * via Metal: it must not sample a half-composited frame. A per-frame fence
     * blocks only on THIS frame's work instead of draining the whole pipeline the
     * way glFinish does, and drops the old per-frame center glReadPixels (a
     * synchronous GPU->CPU stall) — that readback now lives in the IOSC_DEBUG
     * path only. */
    glFlush();
#ifdef EGL_KHR_fence_sync
    if (s_create_sync) {
        EGLSyncKHR fence = s_create_sync(s_dpy, EGL_SYNC_FENCE_KHR, NULL);
        if (fence != EGL_NO_SYNC_KHR) {
            s_client_wait_sync(s_dpy, fence, EGL_SYNC_FLUSH_COMMANDS_BIT_KHR, EGL_FOREVER_KHR);
            s_destroy_sync(s_dpy, fence);
            return;
        }
    }
#endif
    glFinish();   /* fallback: no fence-sync extension */
}

uint32_t iosc_gl_read_center(void)
{
    uint32_t px = 0;   /* FBO center pixel (BGRA); validation only */
    glReadPixels(s_ow / 2, s_oh / 2, 1, 1, GL_BGRA_EXT, GL_UNSIGNED_BYTE, &px);
    return px;
}

uint32_t iosc_gl_read_at(int x, int y)
{
    if (x < 0 || y < 0 || x >= s_ow || y >= s_oh) return 0;
    uint32_t px = 0;
    /* The FBO is GL bottom-left origin; our coords are top-left. */
    glReadPixels(x, s_oh - 1 - y, 1, 1, GL_BGRA_EXT, GL_UNSIGNED_BYTE, &px);
    return px;
}

/* Blended composites (cursor, DnD icon, layer-shell chrome) wrap their draw in
 * premultiplied alpha blending: these are ARGB8888 buffers whose alpha channel is
 * real (transparent around the arrow, translucent panel); without this they would
 * draw opaque. Wayland SHM buffers are PREMULTIPLIED, so the blend is
 * (GL_ONE, GL_ONE_MINUS_SRC_ALPHA) and the shader emits the sampled color
 * unmodified (opaque=0 keeps c.a). Windows keep opaque=1 and blend disabled, so
 * their path is byte-identical to before. */
void iosc_gl_begin_blend(void)
{
    s_opaque = 0.f;
    glEnable(GL_BLEND);
    glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);   /* premultiplied-alpha over */
}

void iosc_gl_end_blend(void)
{
    glDisable(GL_BLEND);
    s_opaque = 1.f;
}

void iosc_gl_forget_iosurface(void *client_iosurface)
{
    for (int i = 0; i < MAXBUF; i++) {
        if (s_cache[i].surf == client_iosurface) {
            xios_egl_destroy_pbuffer(s_cache[i].pb);
            if (s_cache[i].tex) glDeleteTextures(1, &s_cache[i].tex);
            s_cache[i].surf = NULL; s_cache[i].pb = EGL_NO_SURFACE; s_cache[i].tex = 0;
            return;
        }
    }
}

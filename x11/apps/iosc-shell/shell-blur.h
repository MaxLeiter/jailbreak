/*
 * shell-blur.h — the shell's "material": a fast client-side blur used to build
 * frosted backdrops from a screen capture (overview, quick settings).
 *
 * iosc composites layer surfaces opaque today, so translucency can't come from
 * the compositor yet — instead we capture what is on screen (wlr-screencopy),
 * downscale it hard, blur the small image, and paint it scaled back up under a
 * dim scrim. The result reads as iPadOS-style frosted glass, costs milliseconds
 * (the blur runs on ~1/8-scale pixels), and — because these surfaces are
 * transient snapshots — looks identical to a live blur in practice. When iosc
 * gains layer-surface alpha blending this same code keeps working; the blend
 * only adds live translucency at the edges.
 *
 * Blur: three box-blur passes (running-sum, O(n) per pass) ≈ a gaussian.
 * Operates on cairo ARGB32/RGB24 data in place, per channel, ignoring alpha
 * (captures are opaque).
 *
 * Header-only, `static`, cairo-only — shared by the device clients and the
 * off-device preview (which is how the look gets iterated).
 */
#ifndef SHELL_BLUR_H
#define SHELL_BLUR_H

#include <cairo/cairo.h>
#include <stdint.h>
#include <stdlib.h>

/* One horizontal running-sum box pass over 32bpp rows (B,G,R each; A copied). */
static void sb__box_h(uint32_t *src, uint32_t *dst, int w, int h, int stride32, int r)
{
    if (r < 1) r = 1;
    int win = 2 * r + 1;
    for (int y = 0; y < h; y++) {
        uint32_t *s = src + (size_t)y * stride32;
        uint32_t *d = dst + (size_t)y * stride32;
        unsigned sb = 0, sg = 0, sr = 0;
        for (int x = -r; x <= r; x++) {
            uint32_t p = s[x < 0 ? 0 : (x >= w ? w - 1 : x)];
            sb += p & 0xff; sg += (p >> 8) & 0xff; sr += (p >> 16) & 0xff;
        }
        for (int x = 0; x < w; x++) {
            d[x] = 0xff000000u | ((sr / win) << 16) | ((sg / win) << 8) | (sb / win);
            uint32_t add = s[x + r + 1 >= w ? w - 1 : x + r + 1];
            uint32_t sub = s[x - r < 0 ? 0 : x - r];
            sb += (add & 0xff)         - (sub & 0xff);
            sg += ((add >> 8) & 0xff)  - ((sub >> 8) & 0xff);
            sr += ((add >> 16) & 0xff) - ((sub >> 16) & 0xff);
        }
    }
}

/* Transpose-free vertical pass (column running sums). */
static void sb__box_v(uint32_t *src, uint32_t *dst, int w, int h, int stride32, int r)
{
    if (r < 1) r = 1;
    int win = 2 * r + 1;
    for (int x = 0; x < w; x++) {
        unsigned sb = 0, sg = 0, sr = 0;
        for (int y = -r; y <= r; y++) {
            uint32_t p = src[(size_t)(y < 0 ? 0 : (y >= h ? h - 1 : y)) * stride32 + x];
            sb += p & 0xff; sg += (p >> 8) & 0xff; sr += (p >> 16) & 0xff;
        }
        for (int y = 0; y < h; y++) {
            dst[(size_t)y * stride32 + x] =
                0xff000000u | ((sr / win) << 16) | ((sg / win) << 8) | (sb / win);
            uint32_t add = src[(size_t)(y + r + 1 >= h ? h - 1 : y + r + 1) * stride32 + x];
            uint32_t sub = src[(size_t)(y - r < 0 ? 0 : y - r) * stride32 + x];
            sb += (add & 0xff)         - (sub & 0xff);
            sg += ((add >> 8) & 0xff)  - ((sub >> 8) & 0xff);
            sr += ((add >> 16) & 0xff) - ((sub >> 16) & 0xff);
        }
    }
}

/* Blur a cairo image surface in place (ARGB32/RGB24), radius in its own px. */
static void sb_blur_inplace(cairo_surface_t *s, int radius)
{
    cairo_surface_flush(s);
    int w = cairo_image_surface_get_width(s);
    int h = cairo_image_surface_get_height(s);
    int stride32 = cairo_image_surface_get_stride(s) / 4;
    uint32_t *px = (uint32_t *)cairo_image_surface_get_data(s);
    if (!px || w < 2 || h < 2) return;
    uint32_t *tmp = malloc((size_t)stride32 * h * 4);
    if (!tmp) return;
    /* 3 box passes ≈ gaussian; alternate buffers, end back in px. */
    for (int i = 0; i < 3; i++) {
        sb__box_h(px, tmp, w, h, stride32, radius);
        sb__box_v(tmp, px, w, h, stride32, radius);
    }
    free(tmp);
    cairo_surface_mark_dirty(s);
}

/*
 * Build a frosted backdrop from `capture` (any size, typically the physical
 * screen): downscale by `ds` (8 is right for a full screen), blur the small
 * image, return it. Draw it with sb_draw_cover() stretched over the target —
 * the upscale itself adds the final softness. Caller destroys the result.
 */
static cairo_surface_t *sb_backdrop_build(cairo_surface_t *capture, int ds, int blur_r)
{
    int cw = cairo_image_surface_get_width(capture);
    int ch = cairo_image_surface_get_height(capture);
    if (ds < 1) ds = 1;
    int sw = cw / ds > 1 ? cw / ds : 1;
    int sh = ch / ds > 1 ? ch / ds : 1;
    cairo_surface_t *small = cairo_image_surface_create(CAIRO_FORMAT_RGB24, sw, sh);
    cairo_t *cr = cairo_create(small);
    cairo_scale(cr, (double)sw / cw, (double)sh / ch);
    cairo_set_source_surface(cr, capture, 0, 0);
    cairo_pattern_set_filter(cairo_get_source(cr), CAIRO_FILTER_GOOD);
    cairo_paint(cr);
    cairo_destroy(cr);
    sb_blur_inplace(small, blur_r);
    return small;
}

/* Paint `src` scaled to exactly cover [x,y,w,h] in the current (logical) space. */
static void sb_draw_cover(cairo_t *cr, cairo_surface_t *src,
                          double x, double y, double w, double h)
{
    int sw = cairo_image_surface_get_width(src);
    int sh = cairo_image_surface_get_height(src);
    if (sw < 1 || sh < 1) return;
    cairo_save(cr);
    cairo_rectangle(cr, x, y, w, h);
    cairo_clip(cr);
    double k = w / sw > h / sh ? w / sw : h / sh;   /* cover, preserve aspect */
    cairo_translate(cr, x + (w - sw * k) / 2, y + (h - sh * k) / 2);
    cairo_scale(cr, k, k);
    cairo_set_source_surface(cr, src, 0, 0);
    cairo_pattern_set_filter(cairo_get_source(cr), CAIRO_FILTER_GOOD);
    cairo_paint(cr);
    cairo_restore(cr);
}

#endif /* SHELL_BLUR_H */

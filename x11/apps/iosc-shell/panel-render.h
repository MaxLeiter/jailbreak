/*
 * panel-render.h — cairo/pangocairo rendering primitives for the iosc shell.
 *
 * This replaces the original 5x7-bitmap + letter-square software renderer
 * (formerly in shell-draw.h, since deleted) with real vector drawing: San Francisco text via pangocairo, rounded surfaces,
 * gradients, and PNG app icons. It is deliberately WAYLAND-FREE so the exact same
 * draw code runs in two places:
 *
 *   - ioscbar/dock  : wraps a wl_shm buffer as a cairo ARGB32 surface (on device)
 *   - preview-host.c: renders to a PNG off-device for fast visual iteration
 *
 * Colour model: we author straight-alpha 0xAARRGGBB and let cairo premultiply.
 * The backing buffer is CAIRO_FORMAT_ARGB32 = native-endian premultiplied, which
 * on little-endian arm64 is B,G,R,A in memory — exactly iosc's IOSurface order.
 * (iosc currently composites layer surfaces opaque; when it blends them, the
 * premultiplied alpha we emit lights up translucency for free.)
 *
 * Header-only, all `static`. Depends on cairo + pangocairo only.
 */
#ifndef PANEL_RENDER_H
#define PANEL_RENDER_H

#include <cairo/cairo.h>
#include <pango/pangocairo.h>
#include <stdint.h>
#include <string.h>
#include <ctype.h>
#include <math.h>

/* -------------------------------------------------------------- colours --- */
/* Split 0xAARRGGBB into cairo's 0..1 straight-alpha components. */
static inline void pr_rgba(uint32_t c, double *r, double *g, double *b, double *a)
{
    *a = ((c >> 24) & 0xff) / 255.0;
    *r = ((c >> 16) & 0xff) / 255.0;
    *g = ((c >>  8) & 0xff) / 255.0;
    *b = ( c        & 0xff) / 255.0;
}
static inline void pr_set(cairo_t *cr, uint32_t c)
{
    double r,g,b,a; pr_rgba(c,&r,&g,&b,&a); cairo_set_source_rgba(cr,r,g,b,a);
}

/* Give an RGB base (no alpha byte) a runtime opacity. */
static inline uint32_t pr_with_alpha(uint32_t rgb, double a)
{
    uint32_t A = (uint32_t)(a * 255.0 + 0.5); if (A > 255) A = 255;
    return (A << 24) | (rgb & 0x00FFFFFFu);
}

/* ---------------------------------------------------------------- paths --- */

/* Append a rounded-rectangle subpath (radius clamped to half the short side). */
static void pr_rrect_path(cairo_t *cr, double x, double y, double w, double h, double rad)
{
    double m = (w < h ? w : h) / 2.0;
    if (rad > m) rad = m;
    if (rad < 0) rad = 0;
    const double k = M_PI / 180.0;
    cairo_new_sub_path(cr);
    cairo_arc(cr, x + w - rad, y + rad,     rad, -90*k,   0*k);
    cairo_arc(cr, x + w - rad, y + h - rad, rad,   0*k,  90*k);
    cairo_arc(cr, x + rad,     y + h - rad, rad,  90*k, 180*k);
    cairo_arc(cr, x + rad,     y + rad,     rad, 180*k, 270*k);
    cairo_close_path(cr);
}

static void pr_fill_rrect(cairo_t *cr, double x, double y, double w, double h,
                          double rad, uint32_t color)
{
    pr_rrect_path(cr, x, y, w, h, rad);
    pr_set(cr, color);
    cairo_fill(cr);
}

/* 1px (device) stroke inside a rounded rect — a hairline border. */
static void pr_stroke_rrect(cairo_t *cr, double x, double y, double w, double h,
                            double rad, uint32_t color, double line)
{
    pr_rrect_path(cr, x + line/2, y + line/2, w - line, h - line, rad);
    pr_set(cr, color);
    cairo_set_line_width(cr, line);
    cairo_stroke(cr);
}

/* A flat rect fill (logical coords). */
static void pr_fill_rect(cairo_t *cr, double x, double y, double w, double h, uint32_t color)
{
    cairo_rectangle(cr, x, y, w, h);
    pr_set(cr, color);
    cairo_fill(cr);
}

/* Vertical two-stop gradient fill over a rect (top -> bottom). */
static void pr_fill_vgrad(cairo_t *cr, double x, double y, double w, double h,
                          uint32_t top, uint32_t bot)
{
    cairo_pattern_t *p = cairo_pattern_create_linear(0, y, 0, y + h);
    double r,g,b,a;
    pr_rgba(top,&r,&g,&b,&a); cairo_pattern_add_color_stop_rgba(p, 0, r,g,b,a);
    pr_rgba(bot,&r,&g,&b,&a); cairo_pattern_add_color_stop_rgba(p, 1, r,g,b,a);
    cairo_rectangle(cr, x, y, w, h);
    cairo_set_source(cr, p);
    cairo_fill(cr);
    cairo_pattern_destroy(p);
}

/* ----------------------------------------------------------------- text --- */

/* One reusable Pango layout per canvas. Font strings are pango descriptions,
 * e.g. "Sans 13", "Sans Medium 13". Generic "Sans" resolves to Apple .SF UI via
 * the x11-fonts-sf fontconfig rule, so we get San Francisco with no font files. */
typedef struct {
    PangoLayout *lay;
    PangoFontDescription *fd;
    char font[64];
} pr_text_ctx;

static pr_text_ctx pr_text_ctx_new(cairo_t *cr)
{
    pr_text_ctx t;
    memset(&t, 0, sizeof t);
    t.lay = pango_cairo_create_layout(cr);
    return t;
}
static void pr_text_ctx_free(pr_text_ctx *t)
{
    if (t->fd) pango_font_description_free(t->fd);
    if (t->lay) g_object_unref(t->lay);
    memset(t, 0, sizeof *t);
}

static void pr_text_set_font(pr_text_ctx *t, const char *font)
{
    if (!font) font = "";
    if (!t->fd || strcmp(t->font, font)) {
        if (t->fd) pango_font_description_free(t->fd);
        t->fd = pango_font_description_from_string(font);
        snprintf(t->font, sizeof t->font, "%s", font);
    }
    pango_layout_set_font_description(t->lay, t->fd);
}

static void pr_text_measure(pr_text_ctx *t, const char *font, const char *s, int *w, int *h)
{
    pr_text_set_font(t, font);
    pango_layout_set_text(t->lay, s, -1);
    pango_layout_set_attributes(t->lay, NULL);
    pango_layout_set_width(t->lay, -1);
    pango_layout_set_ellipsize(t->lay, PANGO_ELLIPSIZE_NONE);
    pango_layout_set_single_paragraph_mode(t->lay, FALSE);
    int pw, ph; pango_layout_get_pixel_size(t->lay, &pw, &ph);
    if (w) *w = pw; if (h) *h = ph;
}

/* Draw `s` with its left edge at x and vertically centred on cy. If max_w>0 the
 * text is ellipsized to fit. Returns the drawn text width (px). */
static int pr_text(cairo_t *cr, pr_text_ctx *t, const char *font, const char *s,
                   double x, double cy, uint32_t color, int max_w)
{
    pr_text_set_font(t, font);
    pango_layout_set_text(t->lay, s, -1);
    if (max_w > 0) {
        pango_layout_set_width(t->lay, max_w * PANGO_SCALE);
        pango_layout_set_ellipsize(t->lay, PANGO_ELLIPSIZE_END);
        pango_layout_set_single_paragraph_mode(t->lay, TRUE);
    } else {
        pango_layout_set_width(t->lay, -1);
        pango_layout_set_ellipsize(t->lay, PANGO_ELLIPSIZE_NONE);
        pango_layout_set_single_paragraph_mode(t->lay, FALSE);
    }
    int pw, ph; pango_layout_get_pixel_size(t->lay, &pw, &ph);
    cairo_save(cr);
    pr_set(cr, color);
    cairo_move_to(cr, x, cy - ph / 2.0);
    pango_cairo_show_layout(cr, t->lay);
    cairo_restore(cr);
    return pw;
}

/* Draw `s` centred in [x0, x0+w], vertically centred on cy. */
static void pr_text_centered(cairo_t *cr, pr_text_ctx *t, const char *font,
                             const char *s, double x0, double w, double cy, uint32_t color)
{
    int pw, ph; pr_text_measure(t, font, s, &pw, &ph);
    double x = x0 + (w - pw) / 2.0;
    pr_text(cr, t, font, s, x, cy, color, 0);
}

/* --------------------------------------------------------------- icons ---- */

/* Load a PNG into a cairo image surface (premultiplied ARGB32). Caller keeps the
 * handle for reuse; destroy with cairo_surface_destroy. Returns NULL on failure
 * (including cairo's own "status != SUCCESS" surfaces, which we normalise to NULL). */
static cairo_surface_t *pr_icon_load(const char *path)
{
    if (!path || !*path) return NULL;
    cairo_surface_t *s = cairo_image_surface_create_from_png(path);
    if (cairo_surface_status(s) != CAIRO_STATUS_SUCCESS) {
        cairo_surface_destroy(s);
        return NULL;
    }
    return s;
}

/* Draw `icon` scaled to a `size`x`size` box at logical (x,y). If rad>0 the icon
 * is clipped to a rounded rect (a unified "tile" look — use 0 to draw the icon's
 * own silhouette, which suits already-shaped GNOME icons). */
static void pr_draw_icon(cairo_t *cr, cairo_surface_t *icon, double x, double y,
                         double size, double rad)
{
    if (!icon) return;
    int iw = cairo_image_surface_get_width(icon);
    int ih = cairo_image_surface_get_height(icon);
    if (iw <= 0 || ih <= 0) return;
    cairo_save(cr);
    if (rad > 0) { pr_rrect_path(cr, x, y, size, size, rad); cairo_clip(cr); }
    cairo_translate(cr, x, y);
    cairo_scale(cr, size / iw, size / ih);
    cairo_set_source_surface(cr, icon, 0, 0);
    cairo_pattern_set_filter(cairo_get_source(cr), CAIRO_FILTER_GOOD);
    cairo_paint(cr);
    cairo_restore(cr);
}

/* A clean monogram fallback tile: a subtle rounded backplate + the first letter
 * of `name` centred in the UI font. Used when no icon file resolves — never an
 * orange letter-square. */
static void pr_draw_monogram(cairo_t *cr, pr_text_ctx *t, const char *name,
                             double x, double y, double size, double rad,
                             uint32_t tile, uint32_t fg, const char *font)
{
    pr_fill_rrect(cr, x, y, size, size, rad, tile);
    pr_stroke_rrect(cr, x, y, size, size, rad, 0x14ffffffu, 1.0);
    char m[2] = { (char)(name && name[0] ? toupper((unsigned char)name[0]) : '?'), 0 };
    pr_text_centered(cr, t, font, m, x, size, y + size/2.0, fg);
}

#endif /* PANEL_RENDER_H */

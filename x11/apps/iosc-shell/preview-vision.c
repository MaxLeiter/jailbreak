/*
 * preview-vision.c — MOCKUPS for the hybrid tablet-DE vision (docs/iosc-shell.md
 * §0). Not shipping code: this renders the PROPOSED surfaces (slim status bar,
 * floating dock, Control Center) so Max can judge the direction before we split
 * ioscpanel into ioscbar + ioscdock and build for real.
 *
 * Uses the real render primitives (panel-render.h) + theme tokens
 * (shell-theme.h) at the 1440x1080 reference, scale 2, so the type + material
 * match the device. Output: design/vision-home.png, design/vision-control.png.
 */
#include "shell-theme.h"
#include "panel-render.h"
#include <stdio.h>
#include <stdlib.h>
#include <math.h>

static const int LW = 1440, LH = 1080, SCALE = 2;
static const int BAR_H = 36;          /* slim status bar */

static cairo_surface_t *load(const char *dir, const char *n)
{ char p[512]; snprintf(p, sizeof p, "%s/%s.png", dir, n); return pr_icon_load(p); }

/* ---- shared background: wallpaper gradient + soft glow ------------------- */
static void wallpaper(cairo_t *cr)
{
    pr_fill_vgrad(cr, 0, 0, LW, LH, TH_WALL_TOP, TH_WALL_BOT);
    cairo_pattern_t *g = cairo_pattern_create_radial(LW*0.28, 150, 40, LW*0.28, 150, 780);
    cairo_pattern_add_color_stop_rgba(g, 0, 0.36, 0.30, 0.58, 0.40);
    cairo_pattern_add_color_stop_rgba(g, 1, 0, 0, 0, 0);
    cairo_set_source(cr, g); cairo_paint(cr); cairo_pattern_destroy(g);
    cairo_pattern_t *g2 = cairo_pattern_create_radial(LW*0.82, LH*0.8, 60, LW*0.82, LH*0.8, 700);
    cairo_pattern_add_color_stop_rgba(g2, 0, 0.10, 0.40, 0.55, 0.30);
    cairo_pattern_add_color_stop_rgba(g2, 1, 0, 0, 0, 0);
    cairo_set_source(cr, g2); cairo_paint(cr); cairo_pattern_destroy(g2);
}

/* crisp vector battery (from panel-layout, standalone here) */
static void battery(cairo_t *cr, double x, double cy, int pct)
{
    double w = 26, h = 13, r = 3.5, y = cy - h/2;
    pr_stroke_rrect(cr, x, y, w, h, r, TH_FG_DIM, 1.4);
    pr_fill_rrect(cr, x+w+1.6, cy-2.6, 2.4, 5.2, 1.2, TH_FG_DIM);
    double inset = 2.4, lw = (w-2*inset)*pct/100.0;
    pr_fill_rrect(cr, x+inset, y+inset, lw, h-2*inset, 1.8, TH_FG);
}
static void wifi(cairo_t *cr, double cx, double cy, uint32_t col)
{
    cairo_save(cr); pr_set(cr, col); cairo_set_line_width(cr, 2.0);
    for (int i = 1; i <= 3; i++) {
        double r = i*4.2;
        cairo_new_sub_path(cr);
        cairo_arc(cr, cx, cy+6, r, -2.7, -0.44);
        cairo_stroke(cr);
    }
    cairo_arc(cr, cx, cy+6, 1.6, 0, 2*M_PI); cairo_fill(cr);
    cairo_restore(cr);
}
static void grid_glyph(cairo_t *cr, double cx, double cy, uint32_t col)
{
    double step = 9, r = 3.0;
    for (int gy=-1; gy<=1; gy++) for (int gx=-1; gx<=1; gx++) {
        cairo_new_sub_path(cr); cairo_arc(cr, cx+gx*step, cy+gy*step, r, 0, 2*M_PI);
    }
    pr_set(cr, col); cairo_fill(cr);
}

/* ---- slim status bar (translucent, glanceable) -------------------------- */
static void status_bar(cairo_t *cr, pr_text_ctx *t, const char *app)
{
    pr_fill_rect(cr, 0, 0, LW, BAR_H, 0x59000000u);        /* frosted-dark */
    pr_fill_rect(cr, 0, BAR_H-1, LW, 1, 0x14FFFFFFu);
    int cy = BAR_H/2;
    /* left: focused app name (desktop touch: context) */
    if (app) pr_text(cr, t, TH_FONT_LABEL_MED, app, 18, cy, TH_FG, 0);
    /* center: clock */
    pr_text_centered(cr, t, TH_FONT_CLOCK, "9:41", 0, LW, cy, TH_FG);
    /* right cluster: wifi + battery + % (tap = Control Center) */
    int x = LW - 18 - 30;
    battery(cr, x, cy, 82);
    pr_text(cr, t, TH_FONT_LABEL, "82%", x - 8 - 34, cy, TH_FG_DIM, 0);
    wifi(cr, x - 8 - 34 - 26, cy, TH_FG_DIM);
}

/* ---- the dock: favorites | running | apps, floating + translucent ------- */
struct dockitem { const char *label; cairo_surface_t *icon; const char *key; int running; };

static void dock(cairo_t *cr, pr_text_ctx *t, struct dockitem *fav, int nfav,
                 struct dockitem *run, int nrun)
{
    int ico = 56, pad = 16, gap = 14, sep = 22;
    int n = nfav + nrun;
    int inner = n*ico + (n-1)*gap + (nrun?2*sep:sep) /*dividers*/ + ico /*apps btn*/;
    int dw = inner + 2*pad;
    int dh = ico + 2*pad;
    int dx = (LW - dw)/2, dy = LH - dh - 20;

    /* shadow + frosted pill */
    pr_fill_rrect(cr, dx, dy+8, dw, dh, dh/2, 0x4D000000u);
    pr_fill_rrect(cr, dx, dy, dw, dh, dh/2, 0xB22C2C2Eu);      /* ~70% frosted */
    pr_stroke_rrect(cr, dx, dy, dw, dh, dh/2, TH_BORDER, 1.0);
    pr_fill_rrect(cr, dx+1, dy+1, dw-2, 2, dh/2, TH_HILITE);

    int x = dx + pad, iy = dy + pad;
    for (int i = 0; i < nfav; i++) {
        if (fav[i].icon) pr_draw_icon(cr, fav[i].icon, x, iy, ico, 0);
        else pr_draw_monogram(cr, t, fav[i].key, x, iy, ico, 14, TH_TILE, TH_FG, TH_FONT_TITLE);
        x += ico + gap;
    }
    /* divider */
    x = x - gap + (sep-gap)/2;
    pr_fill_rect(cr, x, dy+pad+6, 1.5, dh-2*pad-12, TH_SEP); x += (sep-gap)/2 + gap;
    /* running apps (dot under each) */
    for (int i = 0; i < nrun; i++) {
        if (run[i].icon) pr_draw_icon(cr, run[i].icon, x, iy, ico, 0);
        else pr_draw_monogram(cr, t, run[i].key, x, iy, ico, 14, TH_TILE, TH_FG, TH_FONT_TITLE);
        cairo_new_sub_path(cr);
        cairo_arc(cr, x + ico/2.0, dy + dh - 7, 3.0, 0, 2*M_PI);
        pr_set(cr, run[i].running ? TH_ACCENT : TH_FG_FAINT); cairo_fill(cr);
        x += ico + gap;
    }
    x = x - gap + (sep-gap)/2;
    pr_fill_rect(cr, x, dy+pad+6, 1.5, dh-2*pad-12, TH_SEP); x += (sep-gap)/2 + gap;
    /* apps / overview button */
    pr_fill_rrect(cr, x, iy, ico, ico, 14, 0x1FFFFFFFu);
    grid_glyph(cr, x + ico/2.0, iy + ico/2.0, TH_FG);

    /* home indicator */
    pr_fill_rrect(cr, LW/2 - 70, LH - 9, 140, 5, 2.5, 0x80FFFFFFu);
}

/* ---- a mock app window (fullscreen-ish) with touch chrome --------------- */
static void app_window(cairo_t *cr, pr_text_ctx *t, int x, int y, int w, int h,
                       const char *title)
{
    pr_fill_rrect(cr, x, y, w, h, 18, 0xFF1E1E20u);
    int bar = 52;
    pr_fill_rrect(cr, x, y, w, bar, 18, 0xFF2E2E32u);
    pr_fill_rect(cr, x, y+bar-18, w, 18, 0xFF2E2E32u);
    pr_fill_rrect(cr, x + w/2 - 24, y+9, 48, 5, 2.5, 0x40FFFFFFu);   /* grab handle */
    pr_text_centered(cr, t, TH_FONT_LABEL_MED, title, x, w, y+bar-19, TH_FG_DIM);
    cairo_new_sub_path(cr); cairo_arc(cr, x+w-30, y+bar/2.0, 17, 0, 2*M_PI);
    pr_set(cr, 0x2EFFFFFFu); cairo_fill(cr);
    pr_text_centered(cr, t, TH_FONT_LABEL, "×", x+w-30-17, 34, y+bar/2.0, TH_FG_DIM);
    /* mock content */
    pr_text(cr, t, "Monospace 15", "max@ipad ~ % iosc --status", x+22, y+bar+28, 0xFF8CE99Au, w-44);
    pr_text(cr, t, "Monospace 15", "compositor: running   clients: 3", x+22, y+bar+56, TH_FG_DIM, w-44);
}

/* ---- Control Center: swipe-down grid of tiles + sliders ----------------- */
static void cc_toggle(cairo_t *cr, pr_text_ctx *t, int x, int y, int d,
                      const char *label, int on)
{
    pr_fill_rrect(cr, x, y, d, d, d/2, on ? TH_ACCENT : 0x3A3A3Cu);
    /* a simple glyph: filled ring */
    cairo_save(cr); pr_set(cr, on ? TH_FG : TH_FG_DIM); cairo_set_line_width(cr, 3.0);
    cairo_arc(cr, x+d/2.0, y+d/2.0-2, d*0.22, 0, 2*M_PI); cairo_stroke(cr); cairo_restore(cr);
    pr_text_centered(cr, t, TH_FONT_SMALL, label, x-10, d+20, y+d+16, TH_FG_DIM);
}
static void cc_slider(cairo_t *cr, pr_text_ctx *t, int x, int y, int w, int h,
                      const char *label, double frac, const char *glyph)
{
    pr_fill_rrect(cr, x, y, w, h, w/2, 0x33FFFFFFu);           /* dark track */
    int fh = (int)(h*frac);
    if (fh > w) {                                             /* clip fill to track */
        cairo_save(cr); pr_rrect_path(cr, x, y, w, h, w/2); cairo_clip(cr);
        pr_fill_rect(cr, x, y+h-fh, w, fh, 0xF2FFFFFFu);
        cairo_restore(cr);
    }
    pr_text_centered(cr, t, "Sans 20", glyph, x, w, y+h-26, 0x99000000u);
    pr_text_centered(cr, t, TH_FONT_SMALL, label, x-14, w+28, y+h+18, TH_FG_DIM);
}
static void control_center(cairo_t *cr, pr_text_ctx *t)
{
    int cw = 470, ch = 548, cx = LW - cw - 20, cy = BAR_H + 12;
    pr_fill_rrect(cr, cx, cy+10, cw, ch, TH_R_CARD, 0x59000000u);
    pr_fill_rrect(cr, cx, cy, cw, ch, TH_R_CARD, 0xE62C2C2Eu);   /* frosted */
    pr_stroke_rrect(cr, cx, cy, cw, ch, TH_R_CARD, TH_BORDER, 1.0);

    int pad = 26, x = cx + pad, y = cy + pad;
    pr_text(cr, t, TH_FONT_TITLE, "Control Center", x, y+12, TH_FG, 0);
    y += 46;

    /* row of connectivity toggles */
    int d = 74, gap = (cw - 2*pad - 4*d)/3;
    const char *tn[] = {"Wi-Fi","Bluetooth","Airplane","Rotation"};
    int on[]  = {1,1,0,1};
    for (int i=0;i<4;i++) cc_toggle(cr, t, x + i*(d+gap), y, d, tn[i], on[i]);
    y += d + 40;

    /* two vertical sliders (brightness, volume) on the left */
    int sh = 190, sw = 76, sgap = 18;
    cc_slider(cr, t, x, y, sw, sh, "Brightness", 0.62, "☀");
    cc_slider(cr, t, x + sw + sgap, y, sw, sh, "Volume", 0.40, "▶");

    /* right column: dark mode + screenshot tiles + battery — fits in the card */
    int tx = x + 2*sw + sgap + 22;
    int tw = cx + cw - pad - tx;
    int th = 84, ty = y;
    pr_fill_rrect(cr, tx, ty, tw, th, TH_R_BUTTON, TH_ACCENT_DIM);
    pr_text(cr, t, TH_FONT_LABEL_MED, "Dark Mode", tx+18, ty+th/2, TH_ACCENT, 0);
    ty += th + 16;
    pr_fill_rrect(cr, tx, ty, tw, th, TH_R_BUTTON, 0x3A3A3Cu);
    pr_text(cr, t, TH_FONT_LABEL_MED, "Screenshot", tx+18, ty+th/2, TH_FG, 0);
    ty += th + 16;
    int bh = y + sh - ty;
    pr_fill_rrect(cr, tx, ty, tw, bh, TH_R_BUTTON, 0x3A3A3Cu);
    pr_text(cr, t, TH_FONT_LABEL, "Battery", tx+18, ty+24, TH_FG_DIM, 0);
    pr_text(cr, t, TH_FONT_TITLE, "82%", tx+18, ty+54, TH_FG, 0);
    battery(cr, tx+90, ty+54, 82);
}

static int save(cairo_surface_t *s, const char *dir, const char *n)
{ char p[512]; snprintf(p, sizeof p, "%s/%s", dir, n); cairo_surface_flush(s);
  cairo_status_t st = cairo_surface_write_to_png(s, p);
  printf("wrote %s %s\n", p, cairo_status_to_string(st)); return st==0; }

static cairo_surface_t *canvas(cairo_t **cr)
{ cairo_surface_t *s = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, LW*SCALE, LH*SCALE);
  *cr = cairo_create(s); cairo_scale(*cr, SCALE, SCALE); return s; }

int main(int argc, char **argv)
{
    const char *out = argc > 1 ? argv[1] : "design";
    const char *icons = getenv("IOSC_SHELL_ICONS"); if (!icons) icons = "design/preview-icons";
    cairo_surface_t *i_files = load(icons, "files"), *i_text = load(icons, "text-editor"),
                    *i_term = load(icons, "console"), *i_calc = load(icons, "calculator");

    struct dockitem fav[] = {
        {"Files", i_files, "F", 0}, {"Text Editor", i_text, "T", 0},
        {"Console", i_term, "C", 0}, {"Calculator", i_calc, "C", 0},
    };
    struct dockitem run[] = {
        {"Text Editor", i_text, "T", 1}, {"Console", i_term, "C", 1},
    };
    int ok = 1;

    /* Scene 1: HOME / in-app — wallpaper, slim bar, split windows, dock */
    { cairo_t *cr; cairo_surface_t *s = canvas(&cr);
      pr_text_ctx t = pr_text_ctx_new(cr);
      wallpaper(cr);
      int top = BAR_H + 14, bot = LH - 130;
      app_window(cr, &t, 40, top, 800, bot-top, "Text Editor");
      app_window(cr, &t, 860, top, LW-860-40, bot-top, "Console");
      status_bar(cr, &t, "Text Editor");
      dock(cr, &t, fav, 4, run, 2);
      pr_text_ctx_free(&t); cairo_destroy(cr);
      ok &= save(s, out, "vision-home.png"); cairo_surface_destroy(s); }

    /* Scene 2: CONTROL CENTER over the desktop */
    { cairo_t *cr; cairo_surface_t *s = canvas(&cr);
      pr_text_ctx t = pr_text_ctx_new(cr);
      wallpaper(cr);
      int top = BAR_H + 14, bot = LH - 130;
      app_window(cr, &t, 40, top, 800, bot-top, "Text Editor");
      app_window(cr, &t, 860, top, LW-860-40, bot-top, "Console");
      pr_fill_rect(cr, 0, 0, LW, LH, 0x66000000u);      /* dim behind CC */
      status_bar(cr, &t, "Text Editor");
      dock(cr, &t, fav, 4, run, 2);
      control_center(cr, &t);
      pr_text_ctx_free(&t); cairo_destroy(cr);
      ok &= save(s, out, "vision-control.png"); cairo_surface_destroy(s); }

    return ok ? 0 : 1;
}

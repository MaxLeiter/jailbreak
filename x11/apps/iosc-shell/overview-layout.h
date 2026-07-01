/*
 * overview-layout.h — the iosc overview scene (launcher + window switcher), as
 * a wayland-free draw function shared by ioscoverview.c and preview-host.c.
 *
 * The look: the live desktop, captured and frosted (shell-blur.h), under a dim
 * scrim; a centered search pill; a row of open-window chips; and the app grid.
 * Tap an app to launch, a chip to raise, its × to close, anywhere else (or
 * Esc) to dismiss. Type to filter apps — while searching, the windows row
 * hides (typing means launching intent).
 *
 * The caller owns the data: it passes apps ALREADY filtered by the query (hit
 * indices refer to that filtered array) and maps them back to its own list.
 * All coordinates are LOGICAL px (cairo scale set by the caller).
 */
#ifndef OVERVIEW_LAYOUT_H
#define OVERVIEW_LAYOUT_H

#include "shell-theme.h"
#include "panel-render.h"
#include "shell-blur.h"

/* -------------------------------------------------------------- metrics --- */
#define OV_MARGIN       64      /* scene side margin */
#define OV_TOP          56      /* search pill top */
#define OV_SEARCH_H     44
#define OV_SEARCH_MAXW  520
#define OV_SECT_TOP     140     /* first section top */
#define OV_SECT_GAP     30      /* between sections */
#define OV_CHIP_W       260     /* open-window chip */
#define OV_CHIP_H       56
#define OV_CHIP_ICON    28
#define OV_CHIP_CLOSE   40      /* close zone width at chip right */
#define OV_CELL_W       112     /* app tile cell */
#define OV_CELL_H       118
#define OV_TILE_ICON    64
#define OV_GAP          14

#define OV_MAX_APPS     128
#define OV_MAX_WINS     32

/* -------------------------------------------------------------- model ----- */
struct ov_item {
    char  label[96];
    char  key[64];               /* monogram source */
    cairo_surface_t *icon;
    int   active;                /* windows: currently focused */
};
struct ov_model {
    struct ov_item apps[OV_MAX_APPS]; int napps;   /* filtered by the caller */
    struct ov_item wins[OV_MAX_WINS]; int nwins;
    char   query[64];
    int    searching;            /* query[0] != 0 (windows row hides) */
    cairo_surface_t *backdrop;   /* pre-blurred capture (or NULL -> gradient) */
    int    px, py, have_ptr;
    int    press_kind, press_idx;
    int    scroll_y;             /* app-grid scroll offset (>= 0) */
    double anim_t;               /* 0..1 entrance fade (1 = settled) */
};

enum {
    OV_HIT_BG = 1, OV_HIT_APP = 2, OV_HIT_WIN = 3, OV_HIT_WINCLOSE = 4,
};
struct ov_hit  { int x, y, w, h, kind, idx; };
struct ov_hits { struct ov_hit v[OV_MAX_APPS + OV_MAX_WINS * 2 + 2]; int n; };

static inline int ov_hit_test(const struct ov_hits *hits, int x, int y)
{
    for (int i = hits->n - 1; i >= 0; i--) {
        const struct ov_hit *r = &hits->v[i];
        if (x >= r->x && x < r->x + r->w && y >= r->y && y < r->y + r->h)
            return i;
    }
    return -1;
}
static inline int ov__hover(const struct ov_model *m, int x, int y, int w, int h)
{
    return m->have_ptr && m->px >= x && m->px < x + w && m->py >= y && m->py < y + h;
}

/* Content height (logical px) below OV_SECT_TOP for the given model — the
 * client clamps scroll_y to max(0, content - (H - OV_SECT_TOP)). */
static int ov_content_height(const struct ov_model *m, int W)
{
    int cols = (W - 2 * OV_MARGIN + OV_GAP) / (OV_CELL_W + OV_GAP);
    if (cols < 1) cols = 1;
    int h = 0;
    if (m->nwins > 0 && !m->searching) {
        int ccols = (W - 2 * OV_MARGIN + OV_GAP) / (OV_CHIP_W + OV_GAP);
        if (ccols < 1) ccols = 1;
        int crows = (m->nwins + ccols - 1) / ccols;
        h += 24 + crows * (OV_CHIP_H + OV_GAP) + OV_SECT_GAP;
    }
    int arows = (m->napps + cols - 1) / cols;
    h += 24 + arows * (OV_CELL_H + OV_GAP);
    return h;
}

/* ---------------------------------------------------------- sub-draws ----- */

static void ov__search_pill(cairo_t *cr, pr_text_ctx *t, const struct ov_model *m, int W)
{
    int w = W - 2 * OV_MARGIN < OV_SEARCH_MAXW ? W - 2 * OV_MARGIN : OV_SEARCH_MAXW;
    double x = (W - w) / 2.0, y = OV_TOP, h = OV_SEARCH_H, cy = y + h / 2;

    pr_fill_rrect(cr, x, y, w, h, h / 2, 0x2EFFFFFFu);
    pr_stroke_rrect(cr, x, y, w, h, h / 2, TH_BORDER, 1.0);

    /* magnifier: circle + handle */
    double mx = x + 22, myy = cy - 2;
    cairo_save(cr);
    pr_set(cr, TH_FG_DIM);
    cairo_set_line_width(cr, 1.8);
    cairo_new_sub_path(cr);
    cairo_arc(cr, mx, myy, 6.5, 0, 2 * M_PI);
    cairo_stroke(cr);
    cairo_move_to(cr, mx + 4.8, myy + 4.8);
    cairo_line_to(cr, mx + 9.5, myy + 9.5);
    cairo_stroke(cr);
    cairo_restore(cr);

    double tx = x + 40;
    if (m->query[0]) {
        int qw = pr_text(cr, t, TH_FONT_SEARCH, m->query, tx, cy, TH_FG, w - 56);
        pr_fill_rect(cr, tx + qw + 3, cy - 9, 1.5, 18, TH_ACCENT);   /* caret */
    } else {
        pr_text(cr, t, TH_FONT_SEARCH, "Search", tx, cy, TH_FG_FAINT, w - 56);
        pr_fill_rect(cr, tx - 2, cy - 9, 1.5, 18, TH_ACCENT);
    }
}

static void ov__chip(cairo_t *cr, pr_text_ctx *t, const struct ov_model *m,
                     struct ov_hits *hits, const struct ov_item *it,
                     int x, int y, int idx)
{
    int aw = OV_CHIP_W - OV_CHIP_CLOSE;
    int hov = ov__hover(m, x, y, aw, OV_CHIP_H);
    int prs = (m->press_kind == OV_HIT_WIN && m->press_idx == idx);

    pr_fill_rrect(cr, x, y, OV_CHIP_W, OV_CHIP_H, 14,
                  it->active ? TH_ACCENT_BG : (prs ? TH_PRESS : (hov ? 0x33FFFFFFu : 0x26FFFFFFu)));
    if (it->active)
        pr_stroke_rrect(cr, x, y, OV_CHIP_W, OV_CHIP_H, 14, 0x800A84FFu, 1.5);
    else
        pr_stroke_rrect(cr, x, y, OV_CHIP_W, OV_CHIP_H, 14, TH_BORDER, 1.0);

    double iy = y + (OV_CHIP_H - OV_CHIP_ICON) / 2.0;
    if (it->icon)
        pr_draw_icon(cr, it->icon, x + 14, iy, OV_CHIP_ICON, 0);
    else
        pr_draw_monogram(cr, t, it->key, x + 14, iy, OV_CHIP_ICON,
                         TH_R_MONO, TH_TILE, TH_FG, TH_FONT_LABEL);

    pr_text(cr, t, TH_FONT_LABEL_MED, it->label[0] ? it->label : "Window",
            x + 14 + OV_CHIP_ICON + 10, y + OV_CHIP_H / 2.0,
            it->active ? TH_FG : TH_FG_DIM, aw - (14 + OV_CHIP_ICON + 10) - 4);
    hits->v[hits->n++] = (struct ov_hit){ x, y, aw, OV_CHIP_H, OV_HIT_WIN, idx };

    /* close × in its own zone */
    int cx = x + OV_CHIP_W - OV_CHIP_CLOSE;
    int chov = ov__hover(m, cx, y, OV_CHIP_CLOSE, OV_CHIP_H);
    if (chov)
        pr_fill_rrect(cr, cx + 6, y + (OV_CHIP_H - 26) / 2.0, 26, 26, 13, TH_HOVER);
    pr_text_centered(cr, t, TH_FONT_LABEL, "×", cx + 6, 26, y + OV_CHIP_H / 2.0,
                     chov ? TH_FG : TH_FG_FAINT);
    hits->v[hits->n++] = (struct ov_hit){ cx, y, OV_CHIP_CLOSE, OV_CHIP_H, OV_HIT_WINCLOSE, idx };
}

static void ov__tile(cairo_t *cr, pr_text_ctx *t, const struct ov_model *m,
                     struct ov_hits *hits, const struct ov_item *it,
                     int x, int y, int idx)
{
    int hov = ov__hover(m, x, y, OV_CELL_W, OV_CELL_H);
    int prs = (m->press_kind == OV_HIT_APP && m->press_idx == idx);
    if (hov || prs)
        pr_fill_rrect(cr, x, y, OV_CELL_W, OV_CELL_H, TH_R_TILE,
                      prs ? TH_PRESS : TH_HOVER);

    double ix = x + (OV_CELL_W - OV_TILE_ICON) / 2.0, iy = y + 10;
    if (it->icon)
        pr_draw_icon(cr, it->icon, ix, iy, OV_TILE_ICON, 0);
    else
        pr_draw_monogram(cr, t, it->key, ix, iy, OV_TILE_ICON,
                         TH_R_TILE - 4, TH_TILE, TH_FG, TH_FONT_TITLE);

    pr_text_centered(cr, t, TH_FONT_TILE, it->label, x + 4, OV_CELL_W - 8,
                     y + OV_CELL_H - 20, TH_FG_DIM);
    hits->v[hits->n++] = (struct ov_hit){ x, y, OV_CELL_W, OV_CELL_H, OV_HIT_APP, idx };
}

/* ------------------------------------------------------------ the scene --- */

static void ov_draw(cairo_t *cr, pr_text_ctx *t, int W, int H,
                    const struct ov_model *m, struct ov_hits *hits)
{
    hits->n = 0;
    double at = m->anim_t <= 0 ? 1.0 : (m->anim_t > 1 ? 1.0 : m->anim_t);

    /* frosted desktop (or the wallpaper gradient) + dim scrim */
    if (m->backdrop) sb_draw_cover(cr, m->backdrop, 0, 0, W, H);
    else             pr_fill_vgrad(cr, 0, 0, W, H, TH_WALL_TOP, TH_WALL_BOT);
    pr_fill_rect(cr, 0, 0, W, H,
                 pr_with_alpha(0x000000, (TH_SCRIM >> 24) / 255.0 * at));

    /* whole scene is a dismiss target; tiles/chips are appended after and win */
    hits->v[hits->n++] = (struct ov_hit){ 0, 0, W, H, OV_HIT_BG, 0 };

    /* entrance: fade + a slight upward settle for the content */
    cairo_save(cr);
    if (at < 1.0) {
        cairo_push_group(cr);
        cairo_translate(cr, 0, (1.0 - at) * 10.0);
    }

    ov__search_pill(cr, t, m, W);

    int cols = (W - 2 * OV_MARGIN + OV_GAP) / (OV_CELL_W + OV_GAP);
    if (cols < 1) cols = 1;
    int grid_w = cols * OV_CELL_W + (cols - 1) * OV_GAP;
    int x0 = (W - grid_w) / 2;
    int y = OV_SECT_TOP - m->scroll_y;

    /* clip the scrollable sections under the search area */
    cairo_rectangle(cr, 0, OV_SECT_TOP - 26, W, H - (OV_SECT_TOP - 26));
    cairo_clip(cr);

    if (m->nwins > 0 && !m->searching) {
        int ccols = (W - 2 * OV_MARGIN + OV_GAP) / (OV_CHIP_W + OV_GAP);
        if (ccols < 1) ccols = 1;
        int chips_w = (m->nwins < ccols ? m->nwins : ccols) * (OV_CHIP_W + OV_GAP) - OV_GAP;
        int cx0 = (W - chips_w) / 2;
        pr_text(cr, t, TH_FONT_SECTION, "Open Windows", cx0, y + 8, TH_FG_FAINT, 0);
        y += 24;
        for (int i = 0; i < m->nwins; i++) {
            int cx = cx0 + (i % ccols) * (OV_CHIP_W + OV_GAP);
            int cyy = y + (i / ccols) * (OV_CHIP_H + OV_GAP);
            ov__chip(cr, t, m, hits, &m->wins[i], cx, cyy, i);
        }
        y += ((m->nwins + ccols - 1) / ccols) * (OV_CHIP_H + OV_GAP) + OV_SECT_GAP;
    }

    pr_text(cr, t, TH_FONT_SECTION,
            m->searching ? "Results" : "Applications", x0, y + 8, TH_FG_FAINT, 0);
    y += 24;
    if (m->napps == 0 && m->searching) {
        pr_text_centered(cr, t, TH_FONT_LABEL, "No results", 0, W, y + 30, TH_FG_FAINT);
    }
    for (int i = 0; i < m->napps; i++) {
        int tx = x0 + (i % cols) * (OV_CELL_W + OV_GAP);
        int ty = y + (i / cols) * (OV_CELL_H + OV_GAP);
        if (ty > H) break;                          /* below the fold */
        if (ty + OV_CELL_H < OV_SECT_TOP - 26) continue;   /* above it  */
        ov__tile(cr, t, m, hits, &m->apps[i], tx, ty, i);
    }

    if (at < 1.0) {
        cairo_pop_group_to_source(cr);
        cairo_paint_with_alpha(cr, at);
    }
    cairo_restore(cr);
}

#endif /* OVERVIEW_LAYOUT_H */

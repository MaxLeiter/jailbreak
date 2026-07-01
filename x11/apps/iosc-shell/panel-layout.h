/*
 * panel-layout.h — the iosc panel's visual language + arrangement, as ONE
 * wayland-free draw function shared by ioscpanel.c (wl_shm) and preview-host.c
 * (PNG). Keeping the arrangement here (a thin layer over panel-render.h) is what
 * makes switching between the top-bar / dock / status-bar layouts cheap: only
 * this file changes, never the compositor plumbing.
 *
 * All coordinates are LOGICAL px; the caller sets a cairo scale so 1 unit = 1pt.
 */
#ifndef PANEL_LAYOUT_H
#define PANEL_LAYOUT_H

#include "panel-render.h"

/* ------------------------------------------------------------- palette ---- */
/* Dark, cohesive, ONE blue accent (not orange). RGB bases take the panel's
 * bg_alpha; interactive overlays carry their own alpha in the high byte. */
#define COL_BASE_TOP   0x26262Au        /* subtle lighter top edge          */
#define COL_BASE_BOT   0x1C1C1Eu        /* iOS systemGray6 dark             */
#define COL_HILITE     0x14FFFFFFu      /* 1px inner top highlight  (~8%)   */
#define COL_SHADOW     0x40000000u      /* 1px bottom hairline      (~25%)  */
#define COL_SEP        0x1AFFFFFFu      /* vertical separators      (~10%)  */
#define COL_FG         0xFFF5F5F7u      /* primary text                     */
#define COL_FG_DIM     0xA6EBEBF5u      /* secondary text           (~65%)  */
#define COL_ACCENT     0xFF0A84FFu      /* iOS systemBlue                   */
#define COL_ACCENT_BG  0x4C0A84FFu      /* active pill fill         (~30%)  */
#define COL_HOVER      0x1FFFFFFFu      /* hover backplate          (~12%)  */
#define COL_TILE       0x24FFFFFFu      /* monogram backplate       (~14%)  */

#define FONT_LABEL     "Sans 13"
#define FONT_CLOCK     "Sans Medium 14"
#define FONT_MONO      "Sans 15"

/* -------------------------------------------------------------- metrics --- */
#define LO_PAD          10
#define LO_ICON         26     /* launcher icon box */
#define LO_ICON_PADX    7      /* half the hover cell padding around an icon */
#define LO_PILL_H       28
#define LO_PILL_MAXW    180
#define LO_PILL_MINW    46
#define LO_PILL_GAP     8
#define LO_PILL_ICON    18
#define LO_PILL_R       9
#define LO_HOVER_R      8
#define LO_TILE_R       7
#define LO_CLOSE_W      22     /* the close-× hit zone at a pill's right edge */

/* -------------------------------------------------------------- model ----- */
#define PL_MAX_LAUNCH   12
#define PL_MAX_TASK     16

struct panel_item {
    char  label[96];             /* display text (app name / window title) */
    char  key[64];               /* monogram letter source */
    cairo_surface_t *icon;       /* pre-loaded icon, or NULL -> monogram */
    int   active;                /* taskbar: this window is focused */
};
struct panel_model {
    struct panel_item launch[PL_MAX_LAUNCH]; int nlaunch;
    struct panel_item tasks[PL_MAX_TASK];    int ntasks;
    char   clock[16];
    int    px, py, have_ptr;     /* pointer, logical px */
    double bg_alpha;             /* 0..1 base opacity (1 today; <1 when iosc blends) */
};

/* hit kinds */
enum { PL_HIT_LAUNCH = 1, PL_HIT_ACTIVATE = 2, PL_HIT_CLOSE = 3 };
struct panel_hit  { int x, w, kind, idx; };
struct panel_hits { struct panel_hit v[PL_MAX_LAUNCH + PL_MAX_TASK*2]; int n; };

static inline uint32_t pl_with_alpha(uint32_t rgb, double a)
{
    uint32_t A = (uint32_t)(a * 255.0 + 0.5); if (A > 255) A = 255;
    return (A << 24) | (rgb & 0x00FFFFFFu);
}
static inline int pl_in(const struct panel_model *m, int x, int w)
{
    return m->have_ptr && m->px >= x && m->px < x + w;
}

/* ------------------------------------------------------------ top bar ----- */
/* Draw the single refined top bar. W,H are logical; hits filled in logical px. */
static void panel_draw_topbar(cairo_t *cr, pr_text_ctx *t, int W, int H,
                              const struct panel_model *m, struct panel_hits *hits)
{
    hits->n = 0;
    double ba = m->bg_alpha > 0 ? m->bg_alpha : 1.0;
    int cy = H / 2;

    /* base: soft vertical gradient + inner highlight + bottom hairline */
    pr_fill_vgrad(cr, 0, 0, W, H, pl_with_alpha(COL_BASE_TOP, ba),
                                   pl_with_alpha(COL_BASE_BOT, ba));
    pr_fill_rect(cr, 0, 0, W, 1, COL_HILITE);
    pr_fill_rect(cr, 0, H - 1, W, 1, COL_SHADOW);

    /* -- launcher strip (left): real icons, subtle hover backplate -- */
    int x = LO_PAD;
    for (int i = 0; i < m->nlaunch; i++) {
        int cell = LO_ICON + LO_ICON_PADX * 2;
        int iy = (H - LO_ICON) / 2;
        if (pl_in(m, x, cell))
            pr_fill_rrect(cr, x, (H - (LO_ICON + 8)) / 2, cell, LO_ICON + 8, LO_HOVER_R, COL_HOVER);
        if (m->launch[i].icon)
            pr_draw_icon(cr, m->launch[i].icon, x + LO_ICON_PADX, iy, LO_ICON, 0);
        else
            pr_draw_monogram(cr, t, m->launch[i].key, x + LO_ICON_PADX, iy,
                             LO_ICON, LO_TILE_R, COL_TILE, COL_FG, FONT_MONO);
        hits->v[hits->n++] = (struct panel_hit){ x, cell, PL_HIT_LAUNCH, i };
        x += cell;
    }
    x += LO_PAD - LO_ICON_PADX;
    if (m->nlaunch) { pr_fill_rect(cr, x, (H - (H - 16)) / 2, 1, H - 16, COL_SEP); x += LO_PAD; }

    /* -- clock (right) -- */
    int clkw = 0, clkh = 0;
    pr_text_measure(t, FONT_CLOCK, m->clock[0] ? m->clock : "00:00", &clkw, &clkh);
    int clk_x = W - LO_PAD - clkw;
    pr_text(cr, t, FONT_CLOCK, m->clock, clk_x, cy, COL_FG, 0);

    /* -- taskbar pills (center) -- */
    int task_left = x, task_right = clk_x - LO_PAD;
    int avail = task_right - task_left;
    if (m->ntasks > 0 && avail > 0) {
        int pw = LO_PILL_MAXW;
        int need = m->ntasks * (pw + LO_PILL_GAP);
        if (need > avail) pw = avail / m->ntasks - LO_PILL_GAP;
        if (pw < LO_PILL_MINW) pw = LO_PILL_MINW;
        int py = (H - LO_PILL_H) / 2;
        for (int i = 0; i < m->ntasks; i++) {
            int bx = task_left + i * (pw + LO_PILL_GAP);
            if (bx + pw > task_right + 2) break;
            const struct panel_item *it = &m->tasks[i];
            int show_close = pw >= 96;
            int aw = show_close ? pw - LO_CLOSE_W : pw;   /* activate-zone width */
            int hover = pl_in(m, bx, aw);

            if (it->active) {
                pr_fill_rrect(cr, bx, py, pw, LO_PILL_H, LO_PILL_R, COL_ACCENT_BG);
                pr_fill_rrect(cr, bx + 4, py + LO_PILL_H - 2, pw - 8, 2, 1, COL_ACCENT);
            } else if (hover) {
                pr_fill_rrect(cr, bx, py, pw, LO_PILL_H, LO_PILL_R, COL_HOVER);
            }

            int ix = bx + 9;
            if (it->icon)
                pr_draw_icon(cr, it->icon, ix, py + (LO_PILL_H - LO_PILL_ICON) / 2, LO_PILL_ICON, 0);
            else
                pr_draw_monogram(cr, t, it->key, ix, py + (LO_PILL_H - LO_PILL_ICON) / 2,
                                 LO_PILL_ICON, LO_TILE_R - 2, COL_TILE, COL_FG, FONT_LABEL);

            int tx = ix + LO_PILL_ICON + 8;
            int tw = aw - (tx - bx) - 6;
            pr_text(cr, t, FONT_LABEL, it->label[0] ? it->label : "Window",
                    tx, cy, it->active ? COL_FG : COL_FG_DIM, tw > 8 ? tw : 8);
            hits->v[hits->n++] = (struct panel_hit){ bx, aw, PL_HIT_ACTIVATE, i };

            if (show_close) {
                int cx = bx + pw - LO_CLOSE_W;
                int chover = pl_in(m, cx, LO_CLOSE_W);
                if (chover)
                    pr_fill_rrect(cr, cx + 2, py + 4, LO_CLOSE_W - 4, LO_PILL_H - 8,
                                  (LO_PILL_H - 8) / 2, COL_HOVER);
                pr_text_centered(cr, t, FONT_LABEL, "×", cx, LO_CLOSE_W, cy,
                                 chover ? COL_FG : COL_FG_DIM);
                hits->v[hits->n++] = (struct panel_hit){ cx, LO_CLOSE_W, PL_HIT_CLOSE, i };
            }
        }
    }
}

#endif /* PANEL_LAYOUT_H */

/*
 * panel-layout.h — the iosc panel's visual language + arrangement, as
 * wayland-free draw functions shared by ioscpanel.c (wl_shm) and preview-host.c
 * (PNG). Tokens live in shell-theme.h; primitives in panel-render.h. Keeping
 * the arrangement here is what makes design iteration cheap: only this file
 * changes, never the compositor plumbing.
 *
 * Two surfaces are drawn from here:
 *   panel_draw_topbar() — the 44pt bar:
 *     [ ⊞ apps | launcher icons | taskbar pills … | battery date time ]
 *   panel_draw_qs()     — the quick-settings card (a second layer surface the
 *     panel maps under the status cluster): device name, date, battery gauge,
 *     Overview / Screenshot actions, over a frosted screencopy backdrop.
 *
 * All coordinates are LOGICAL px; the caller sets a cairo scale so 1 unit = 1pt.
 */
#ifndef PANEL_LAYOUT_H
#define PANEL_LAYOUT_H

#include "shell-theme.h"
#include "panel-render.h"
#include "shell-blur.h"

/* -------------------------------------------------------------- metrics --- */
#define LO_PAD          TH_PAD
#define LO_ICON         26     /* launcher icon box */
#define LO_ICON_PADX    7      /* half the hover cell padding around an icon */
#define LO_PILL_H       28
#define LO_PILL_MAXW    180
#define LO_PILL_MINW    46
#define LO_PILL_GAP     TH_GAP
#define LO_PILL_ICON    18
#define LO_CLOSE_W      22     /* the close-× hit zone at a pill's right edge */
#define LO_GRID_BTN     36     /* app-grid button cell */

#define QS_W            320    /* quick-settings card, logical */
#define QS_MARGIN       6      /* gap between panel edge and the card */

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
    char   date[32];             /* "Tue Jul 1" ("" hides) */
    int    batt_pct;             /* 0..100, or -1 to hide the indicator */
    int    batt_charging;
    int    qs_open;              /* status cluster stays lit while QS is up */
    int    px, py, have_ptr;     /* pointer, logical px */
    int    press_kind, press_idx;/* finger-down hit (touch feedback); 0 = none */
    double bg_alpha;             /* 0..1 base opacity (1 until iosc blends layers) */
};

/* quick-settings card model (independent surface) */
struct qs_model {
    char   device[128];          /* "Max's iPad" */
    char   date_long[48];        /* "Tuesday, July 1" */
    int    batt_pct, batt_charging;
    cairo_surface_t *backdrop;   /* pre-blurred capture of what's behind, or NULL */
    int    px, py, have_ptr;
    int    press_kind, press_idx;
};

/* hit kinds (shared by both surfaces; idx is per-kind) */
enum {
    PL_HIT_LAUNCH = 1, PL_HIT_ACTIVATE = 2, PL_HIT_CLOSE = 3,
    PL_HIT_APPGRID = 4, PL_HIT_STATUS = 5,
    QS_HIT_OVERVIEW = 6, QS_HIT_SHOT = 7,
};
struct panel_hit  { int x, y, w, h, kind, idx; };
struct panel_hits { struct panel_hit v[PL_MAX_LAUNCH + PL_MAX_TASK*2 + 4]; int n; };

#define pl_with_alpha pr_with_alpha
static inline int pl_hit_test(const struct panel_hits *hits, int x, int y)
{
    for (int i = hits->n - 1; i >= 0; i--) {   /* last drawn wins */
        const struct panel_hit *r = &hits->v[i];
        if (x >= r->x && x < r->x + r->w && y >= r->y && y < r->y + r->h)
            return i;
    }
    return -1;
}
static inline int pl__hover(const struct panel_model *m, int x, int y, int w, int h)
{
    return m->have_ptr && m->px >= x && m->px < x + w && m->py >= y && m->py < y + h;
}
static inline int pl__pressed(int pk, int pi, int kind, int idx)
{
    return pk == kind && pi == idx;
}

/* ------------------------------------------------------ battery glyph ----- */
/* A crisp vector battery at (x, cy): 24x12 body + cap, level fill, bolt while
 * charging. Colors: green charging, red <= 20%, primary otherwise. */
static void pl_draw_battery(cairo_t *cr, double x, double cy, int pct, int charging)
{
    double w = 24, h = 12, r = 3.5, y = cy - h / 2;
    uint32_t fill = charging ? TH_GREEN : (pct <= 20 ? 0xFFFF453Au : TH_FG);

    pr_stroke_rrect(cr, x, y, w, h, r, TH_FG_DIM, 1.2);
    /* cap */
    pr_fill_rrect(cr, x + w + 1.5, cy - 2.5, 2.2, 5, 1.1, TH_FG_DIM);
    /* level */
    double inset = 2.2, lw = (w - 2 * inset) * (pct < 0 ? 0 : pct) / 100.0;
    if (lw > 0.5)
        pr_fill_rrect(cr, x + inset, y + inset, lw, h - 2 * inset, 1.6, fill);
    if (charging) {
        /* bolt, centered on the body */
        double cx = x + w / 2;
        cairo_save(cr);
        cairo_move_to(cr, cx + 1.5, y - 1.5);
        cairo_line_to(cr, cx - 2.5, y + h / 2 + 1);
        cairo_line_to(cr, cx - 0.5, y + h / 2 + 1);
        cairo_line_to(cr, cx - 1.5, y + h + 1.5);
        cairo_line_to(cr, cx + 2.5, y + h / 2 - 1);
        cairo_line_to(cr, cx + 0.5, y + h / 2 - 1);
        cairo_close_path(cr);
        pr_set(cr, TH_FG);
        cairo_set_line_width(cr, 1.4);
        cairo_stroke_preserve(cr);
        pr_set(cr, TH_GREEN);
        cairo_fill(cr);
        cairo_restore(cr);
    }
}

/* --------------------------------------------------- app-grid glyph ------- */
/* 3x3 rounded dots — the "all apps" affordance. */
static void pl_draw_appgrid_glyph(cairo_t *cr, double cx, double cy, uint32_t color)
{
    double step = 6.5, r = 2.1;
    for (int gy = -1; gy <= 1; gy++)
        for (int gx = -1; gx <= 1; gx++) {
            cairo_new_sub_path(cr);
            cairo_arc(cr, cx + gx * step, cy + gy * step, r, 0, 2 * M_PI);
        }
    pr_set(cr, color);
    cairo_fill(cr);
}

/* ------------------------------------------------------------ top bar ----- */
/* Draw the refined top bar. W,H logical; hits filled in logical px. */
static void panel_draw_topbar(cairo_t *cr, pr_text_ctx *t, int W, int H,
                              const struct panel_model *m, struct panel_hits *hits)
{
    hits->n = 0;
    double ba = m->bg_alpha > 0 ? m->bg_alpha : 1.0;
    int cy = H / 2;
    int pk = m->press_kind, pi = m->press_idx;

    /* base: soft vertical gradient + inner highlight + bottom hairline */
    pr_fill_vgrad(cr, 0, 0, W, H, pl_with_alpha(TH_BASE_TOP, ba),
                                   pl_with_alpha(TH_BASE_BOT, ba));
    pr_fill_rect(cr, 0, 0, W, 1, TH_HILITE);
    pr_fill_rect(cr, 0, H - 1, W, 1, TH_SHADOW);

    /* -- app-grid button (far left) -- */
    int x = LO_PAD;
    {
        int by = (H - LO_GRID_BTN) / 2;
        int hov = pl__hover(m, x, 0, LO_GRID_BTN, H);
        int prs = pl__pressed(pk, pi, PL_HIT_APPGRID, 0);
        if (hov || prs)
            pr_fill_rrect(cr, x, by, LO_GRID_BTN, LO_GRID_BTN, TH_R_HOVER,
                          prs ? TH_PRESS : TH_HOVER);
        pl_draw_appgrid_glyph(cr, x + LO_GRID_BTN / 2.0, cy,
                              (hov || prs) ? TH_FG : TH_FG_DIM);
        hits->v[hits->n++] = (struct panel_hit){ x, 0, LO_GRID_BTN, H, PL_HIT_APPGRID, 0 };
        x += LO_GRID_BTN + LO_PAD - 2;
    }
    pr_fill_rect(cr, x, 8, 1, H - 16, TH_SEP);
    x += LO_PAD;

    /* -- launcher strip: real icons, subtle hover backplate -- */
    for (int i = 0; i < m->nlaunch; i++) {
        int cell = LO_ICON + LO_ICON_PADX * 2;
        int iy = (H - LO_ICON) / 2;
        int hov = pl__hover(m, x, 0, cell, H);
        int prs = pl__pressed(pk, pi, PL_HIT_LAUNCH, i);
        if (hov || prs)
            pr_fill_rrect(cr, x, (H - (LO_ICON + 8)) / 2, cell, LO_ICON + 8,
                          TH_R_HOVER, prs ? TH_PRESS : TH_HOVER);
        if (m->launch[i].icon)
            pr_draw_icon(cr, m->launch[i].icon, x + LO_ICON_PADX, iy, LO_ICON, 0);
        else
            pr_draw_monogram(cr, t, m->launch[i].key, x + LO_ICON_PADX, iy,
                             LO_ICON, TH_R_MONO, TH_TILE, TH_FG, TH_FONT_MONO);
        hits->v[hits->n++] = (struct panel_hit){ x, 0, cell, H, PL_HIT_LAUNCH, i };
        x += cell;
    }
    if (m->nlaunch) {
        x += LO_PAD - LO_ICON_PADX;
        pr_fill_rect(cr, x, 8, 1, H - 16, TH_SEP);
        x += LO_PAD;
    }

    /* -- status cluster (right): battery · date · time; one QS hit -- */
    int right = W - LO_PAD;
    int clkw, clkh, datew = 0, dh, pctw = 0, ph2;
    pr_text_measure(t, TH_FONT_CLOCK, m->clock[0] ? m->clock : "00:00", &clkw, &clkh);
    if (m->date[0]) pr_text_measure(t, TH_FONT_LABEL, m->date, &datew, &dh);
    char pct[8] = "";
    if (m->batt_pct >= 0) {
        snprintf(pct, sizeof pct, "%d%%", m->batt_pct);
        pr_text_measure(t, TH_FONT_LABEL, pct, &pctw, &ph2);
    }
    int batt_w = m->batt_pct >= 0 ? (24 + 4 + 6 + pctw) : 0;   /* glyph+cap+gap+% */
    int cluster_w = batt_w + (datew ? datew + 12 : 0) + clkw + 2 * 8;
    int cx0 = right - cluster_w;
    {
        int hov = pl__hover(m, cx0, 0, cluster_w, H);
        int prs = pl__pressed(pk, pi, PL_HIT_STATUS, 0);
        if (m->qs_open || hov || prs)
            pr_fill_rrect(cr, cx0, (H - 32) / 2, cluster_w, 32, TH_R_HOVER,
                          (prs || m->qs_open) ? TH_PRESS : TH_HOVER);
        int tx = cx0 + 8;
        if (m->batt_pct >= 0) {
            pl_draw_battery(cr, tx, cy, m->batt_pct, m->batt_charging);
            tx += 24 + 4 + 6;
            pr_text(cr, t, TH_FONT_LABEL, pct, tx, cy, TH_FG_DIM, 0);
            tx += pctw + 12;
        }
        if (m->date[0]) {
            pr_text(cr, t, TH_FONT_LABEL, m->date, tx, cy, TH_FG_DIM, 0);
            tx += datew + 12;
        }
        pr_text(cr, t, TH_FONT_CLOCK, m->clock, tx, cy, TH_FG, 0);
        hits->v[hits->n++] = (struct panel_hit){ cx0, 0, cluster_w, H, PL_HIT_STATUS, 0 };
    }

    /* -- taskbar pills (center, between launcher strip and status) -- */
    int task_left = x, task_right = cx0 - LO_PAD;
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
            int hov = pl__hover(m, bx, 0, aw, H);
            int prs = pl__pressed(pk, pi, PL_HIT_ACTIVATE, i);

            if (it->active) {
                pr_fill_rrect(cr, bx, py, pw, LO_PILL_H, TH_R_PILL, TH_ACCENT_BG);
                pr_fill_rrect(cr, bx + 4, py + LO_PILL_H - 2, pw - 8, 2, 1, TH_ACCENT);
            } else if (hov || prs) {
                pr_fill_rrect(cr, bx, py, pw, LO_PILL_H, TH_R_PILL,
                              prs ? TH_PRESS : TH_HOVER);
            }

            int ix = bx + 9;
            if (it->icon)
                pr_draw_icon(cr, it->icon, ix, py + (LO_PILL_H - LO_PILL_ICON) / 2, LO_PILL_ICON, 0);
            else
                pr_draw_monogram(cr, t, it->key, ix, py + (LO_PILL_H - LO_PILL_ICON) / 2,
                                 LO_PILL_ICON, TH_R_MONO - 2, TH_TILE, TH_FG, TH_FONT_LABEL);

            int tx = ix + LO_PILL_ICON + 8;
            int tw = aw - (tx - bx) - 6;
            pr_text(cr, t, TH_FONT_LABEL, it->label[0] ? it->label : "Window",
                    tx, cy, it->active ? TH_FG : TH_FG_DIM, tw > 8 ? tw : 8);
            hits->v[hits->n++] = (struct panel_hit){ bx, 0, aw, H, PL_HIT_ACTIVATE, i };

            if (show_close) {
                int cxx = bx + pw - LO_CLOSE_W;
                int chov = pl__hover(m, cxx, 0, LO_CLOSE_W, H);
                if (chov)
                    pr_fill_rrect(cr, cxx + 2, py + 4, LO_CLOSE_W - 4, LO_PILL_H - 8,
                                  (LO_PILL_H - 8) / 2, TH_HOVER);
                pr_text_centered(cr, t, TH_FONT_LABEL, "×", cxx, LO_CLOSE_W, cy,
                                 chov ? TH_FG : TH_FG_DIM);
                hits->v[hits->n++] = (struct panel_hit){ cxx, 0, LO_CLOSE_W, H, PL_HIT_CLOSE, i };
            }
        }
    }
}

/* ---------------------------------------------------- quick settings ------ */

/* A rounded action button; records a hit. */
static void qs__button(cairo_t *cr, pr_text_ctx *t, const struct qs_model *m,
                       struct panel_hits *hits, double x, double y, double w, double h,
                       const char *label, uint32_t fill, uint32_t fg, int kind)
{
    int hov = m->have_ptr && m->px >= x && m->px < x + w && m->py >= y && m->py < y + h;
    int prs = pl__pressed(m->press_kind, m->press_idx, kind, 0);
    pr_fill_rrect(cr, x, y, w, h, TH_R_BUTTON, fill);
    if (hov || prs)
        pr_fill_rrect(cr, x, y, w, h, TH_R_BUTTON, prs ? TH_PRESS : TH_HOVER);
    pr_text_centered(cr, t, TH_FONT_LABEL_MED, label, x, w, y + h / 2, fg);
    hits->v[hits->n++] = (struct panel_hit){ (int)x, (int)y, (int)w, (int)h, kind, 0 };
}

/* The card's total logical height for a given model (charging adds a line). */
static int panel_qs_height(const struct qs_model *m)
{
    return 186 + (m->batt_charging ? 16 : 0);
}

/* Draw the quick-settings card filling the whole (W,H) surface. */
static void panel_draw_qs(cairo_t *cr, pr_text_ctx *t, int W, int H,
                          const struct qs_model *m, struct panel_hits *hits)
{
    hits->n = 0;

    /* frosted backdrop clipped to the card, else opaque card fill */
    cairo_save(cr);
    pr_rrect_path(cr, 0, 0, W, H, TH_R_CARD);
    cairo_clip(cr);
    if (m->backdrop) {
        sb_draw_cover(cr, m->backdrop, 0, 0, W, H);
        pr_fill_rect(cr, 0, 0, W, H, 0xC21C1C1Eu);      /* tint over the blur */
    } else {
        pr_fill_rect(cr, 0, 0, W, H, TH_CARD);
    }
    cairo_restore(cr);
    pr_stroke_rrect(cr, 0, 0, W, H, TH_R_CARD, TH_BORDER, 1.0);

    double x = TH_CARD_PAD, y = TH_CARD_PAD;
    double cw = W - 2 * TH_CARD_PAD;

    /* device name + long date */
    pr_text(cr, t, TH_FONT_TITLE, m->device[0] ? m->device : "iPad", x, y + 10, TH_FG, (int)cw);
    y += 24;
    pr_text(cr, t, TH_FONT_LABEL, m->date_long, x, y + 8, TH_FG_DIM, (int)cw);
    y += 26;
    pr_fill_rect(cr, x, y, cw, 1, TH_SEP);
    y += 14;

    /* battery block: label row + gauge track */
    if (m->batt_pct >= 0) {
        char pct[8]; snprintf(pct, sizeof pct, "%d%%", m->batt_pct);
        int pw, ph;
        pr_text_measure(t, TH_FONT_LABEL_MED, pct, &pw, &ph);
        pr_text(cr, t, TH_FONT_LABEL, "Battery", x, y + 8, TH_FG_DIM, 0);
        pr_text(cr, t, TH_FONT_LABEL_MED, pct, x + cw - pw, y + 8, TH_FG, 0);
        y += 22;
        pr_fill_rrect(cr, x, y, cw, 6, 3, pl_with_alpha(TH_CARD_INNER, 1.0));
        double lw = cw * m->batt_pct / 100.0;
        if (lw > 2)
            pr_fill_rrect(cr, x, y, lw, 6, 3,
                          m->batt_charging ? TH_GREEN
                          : (m->batt_pct <= 20 ? 0xFFFF453Au : TH_ACCENT));
        y += 12;
        if (m->batt_charging) {
            pr_text(cr, t, TH_FONT_SMALL, "Charging", x, y + 6, TH_GREEN, 0);
            y += 16;
        }
        y += 8;
    } else {
        y += 42;   /* keep the card balanced without a battery source */
    }

    /* actions */
    double bw = (cw - TH_GAP) / 2, bh = 40;
    qs__button(cr, t, m, hits, x, y, bw, bh, "Overview",
               TH_ACCENT_DIM, TH_ACCENT, QS_HIT_OVERVIEW);
    qs__button(cr, t, m, hits, x + bw + TH_GAP, y, bw, bh, "Screenshot",
               pl_with_alpha(TH_CARD_INNER, 1.0), TH_FG, QS_HIT_SHOT);
}

#endif /* PANEL_LAYOUT_H */

/*
 * panel-layout.h — the iosc panel's visual language + arrangement, as
 * wayland-free draw functions shared by the shell clients (wl_shm) and preview-host.c
 * (PNG). Tokens live in shell-theme.h; primitives in panel-render.h. Keeping
 * the arrangement here is what makes design iteration cheap: only this file
 * changes, never the compositor plumbing.
 *
 * Three surface families are drawn from here:
 *   panel_draw_topbar() — the 44pt bar:
 *     [ ⊞ apps | launcher icons | taskbar pills … | battery date time ]
 *   panel_draw_statusbar() — the tablet-DE slim top status bar:
 *     [ focused app | clock | wifi battery ]
 *   panel_draw_dock() — the tablet-DE floating bottom dock:
 *     [ favorites | running apps | apps ]
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
/* Touch-first: every hit zone spans the panel's full height (>= TH_TOUCH), and
 * in-row zones (close ×, grid button) are >= TH_TOUCH wide too. Visible pills
 * are drawn smaller than their hit zones for breathing room. */
#define LO_PAD          TH_PAD
#define LO_ICON         36     /* launcher icon box */
#define LO_ICON_PADX    12     /* half the hit cell padding around an icon */
#define LO_PILL_H       48
#define LO_PILL_MAXW    248
#define LO_PILL_MINW    64
#define LO_PILL_GAP     TH_GAP
#define LO_PILL_ICON    26
#define LO_CLOSE_W      60     /* the close-× hit zone at a pill's right edge */
#define LO_GRID_BTN     52     /* app-grid button cell (hit = full height)    */

/* Responsive breakpoints (logical output width). */
#define LO_BP_DATE      900    /* below this the panel drops the date  */
#define LO_BP_PCT       680    /* below this it drops the battery %    */

/* Right-side space reserved from the launcher strip for the status cluster +
 * a minimum taskbar (safety cap so the strip can never run off the edge). */
#define LO_LAUNCH_RESERVE  360

#define BAR_REF_H       36     /* tablet-DE slim status bar */
#define DOCK_REF_H      116    /* surface height; dock pill floats within it */
#define DOCK_ICON       56
#define DOCK_PAD_X      16
#define DOCK_GAP        14
#define DOCK_SEP        22
#define DOCK_BOTTOM     20
#define DOCK_MIN_CELL   TH_TOUCH

#define QS_MAXW         380    /* quick-settings card width cap */
#define QS_MARGIN       10     /* gap between panel/screen edge and the card */
/* The card fills the output minus margins on narrow screens, capped wide. */
static inline int panel_qs_width(int outw)
{
    int w = outw - 2 * QS_MARGIN;
    return w < QS_MAXW ? w : QS_MAXW;
}

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
    int    wifi_on;              /* legacy preview knob: 1 = Wi-Fi glyph */
    int    net_kind;             /* 0 none, 1 Wi-Fi, 2 cellular bars */
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
    PL_HIT_APPNAME = 8,
    WM_HIT_CLOSE = 9, WM_HIT_MINIMIZE = 10, WM_HIT_MAXIMIZE = 11,
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
/* A crisp vector battery at (x, cy): 32x16 body + cap, level fill, bolt while
 * charging. Colors: green charging, red <= 20%, primary otherwise. */
#define PL_BATT_W  32          /* body width (glyph total adds the cap) */
static void pl_draw_battery(cairo_t *cr, double x, double cy, int pct, int charging)
{
    double w = PL_BATT_W, h = 16, r = 4.5, y = cy - h / 2;
    uint32_t fill = charging ? TH_GREEN : (pct <= 20 ? 0xFFFF453Au : TH_FG);

    pr_stroke_rrect(cr, x, y, w, h, r, TH_FG_DIM, 1.5);
    /* cap */
    pr_fill_rrect(cr, x + w + 2, cy - 3.5, 3, 7, 1.5, TH_FG_DIM);
    /* level */
    double inset = 3, lw = (w - 2 * inset) * (pct < 0 ? 0 : pct) / 100.0;
    if (lw > 0.5)
        pr_fill_rrect(cr, x + inset, y + inset, lw, h - 2 * inset, 2.2, fill);
    if (charging) {
        /* bolt, centered on the body */
        double cx = x + w / 2;
        cairo_save(cr);
        cairo_move_to(cr, cx + 2.0, y - 2.0);
        cairo_line_to(cr, cx - 3.3, y + h / 2 + 1.3);
        cairo_line_to(cr, cx - 0.7, y + h / 2 + 1.3);
        cairo_line_to(cr, cx - 2.0, y + h + 2.0);
        cairo_line_to(cr, cx + 3.3, y + h / 2 - 1.3);
        cairo_line_to(cr, cx + 0.7, y + h / 2 - 1.3);
        cairo_close_path(cr);
        pr_set(cr, TH_FG);
        cairo_set_line_width(cr, 1.8);
        cairo_stroke_preserve(cr);
        pr_set(cr, TH_GREEN);
        cairo_fill(cr);
        cairo_restore(cr);
    }
}

/* Compact status-bar battery: bumped slightly and carries percent inside the
 * body so the slim bar does not need a separate, tall percent label. */
static void pl_draw_battery_small(cairo_t *cr, double x, double cy, int pct, int charging)
{
    double w = 36, h = 16, r = 4.2, y = cy - h / 2;
    uint32_t fill = charging ? TH_GREEN : (pct <= 20 ? 0xFFFF453Au : TH_FG);
    pr_stroke_rrect(cr, x, y, w, h, r, TH_FG_DIM, 1.2);
    pr_fill_rrect(cr, x + w + 1.8, cy - 3.0, 2.8, 6.0, 1.4, TH_FG_DIM);
    double inset = 2.6, lw = (w - 2 * inset) * (pct < 0 ? 0 : pct) / 100.0;
    if (lw > 0.5)
        pr_fill_rrect(cr, x + inset, y + inset, lw, h - 2 * inset, 1.8, fill);
    if (charging) {
        double cx = x + w / 2.0;
        cairo_save(cr);
        cairo_move_to(cr, cx + 1.8, y + 2.0);
        cairo_line_to(cr, cx - 3.0, cy + 1.0);
        cairo_line_to(cr, cx - 0.6, cy + 1.0);
        cairo_line_to(cr, cx - 1.8, y + h - 2.0);
        cairo_line_to(cr, cx + 3.2, cy - 1.0);
        cairo_line_to(cr, cx + 0.6, cy - 1.0);
        cairo_close_path(cr);
        pr_set(cr, 0xF0000000u);
        cairo_fill(cr);
        cairo_restore(cr);
    } else if (pct >= 0) {
        char s[5];
        snprintf(s, sizeof s, "%d", pct);
        pr_text_ctx t = pr_text_ctx_new(cr);
        pr_text_centered(cr, &t, "Sans Bold 9", s, x, w, cy + 0.2, 0xE0000000u);
        pr_text_ctx_free(&t);
    }
}

static void pl_draw_wifi_glyph(cairo_t *cr, double cx, double cy, uint32_t color)
{
    cairo_save(cr);
    pr_set(cr, color);
    cairo_set_line_width(cr, 1.8);
    cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND);
    for (int i = 1; i <= 3; i++) {
        double r = i * 3.5;
        cairo_new_sub_path(cr);
        cairo_arc(cr, cx, cy + 5, r, -2.70, -0.44);
        cairo_stroke(cr);
    }
    cairo_new_sub_path(cr);
    cairo_arc(cr, cx, cy + 5, 1.3, 0, 2 * M_PI);
    cairo_fill(cr);
    cairo_restore(cr);
}

static void pl_draw_cell_glyph(cairo_t *cr, double x, double cy, uint32_t color)
{
    double bw = 3.2, gap = 2.4, base = cy + 6;
    cairo_save(cr);
    pr_set(cr, color);
    for (int i = 0; i < 4; i++) {
        double h = 4 + i * 3.0;
        pr_fill_rrect(cr, x + i * (bw + gap), base - h, bw, h, 1.3, color);
    }
    cairo_restore(cr);
}

/* --------------------------------------------------- app-grid glyph ------- */
/* 3x3 rounded dots — the "all apps" affordance. */
static void pl_draw_appgrid_glyph(cairo_t *cr, double cx, double cy, uint32_t color)
{
    double step = 8.5, r = 2.8;
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
    pr_fill_rect(cr, x, 10, 1, H - 20, TH_SEP);
    x += LO_PAD;

    /* -- launcher strip: real icons, subtle hover backplate -- */
    /* Safety: never let the strip run into the status cluster / off the right
     * edge. Reserve room on the right; stop drawing launchers past it. (At
     * realistic app counts the strip is far shorter, so this is a no-op guard.) */
    int launch_limit = W - LO_LAUNCH_RESERVE;
    for (int i = 0; i < m->nlaunch; i++) {
        int cell = LO_ICON + LO_ICON_PADX * 2;
        if (x + cell > launch_limit) break;
        int iy = (H - LO_ICON) / 2;
        int hov = pl__hover(m, x, 0, cell, H);
        int prs = pl__pressed(pk, pi, PL_HIT_LAUNCH, i);
        if (hov || prs)
            pr_fill_rrect(cr, x, (H - (LO_ICON + 12)) / 2, cell, LO_ICON + 12,
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
        pr_fill_rect(cr, x, 10, 1, H - 20, TH_SEP);
        x += LO_PAD;
    }

    /* -- status cluster (right): battery · date · time; one QS hit -- */
    /* Responsive: the date drops below LO_BP_DATE, the battery % below
     * LO_BP_PCT, so the cluster stays compact on narrow outputs. */
    int right = W - LO_PAD;
    int show_date = m->date[0] && W >= LO_BP_DATE;
    int show_pct  = m->batt_pct >= 0 && W >= LO_BP_PCT;
    int clkw, clkh, datew = 0, dh, pctw = 0, ph2;
    pr_text_measure(t, TH_FONT_CLOCK, m->clock[0] ? m->clock : "00:00", &clkw, &clkh);
    if (show_date) pr_text_measure(t, TH_FONT_LABEL, m->date, &datew, &dh);
    char pct[8] = "";
    if (show_pct) {
        snprintf(pct, sizeof pct, "%d%%", m->batt_pct);
        pr_text_measure(t, TH_FONT_LABEL, pct, &pctw, &ph2);
    }
    int batt_w = m->batt_pct >= 0
                 ? (PL_BATT_W + 5 + (show_pct ? 8 + pctw : 0)) : 0;
    int cluster_w = batt_w + (datew ? datew + 16 : (batt_w ? 16 : 0))
                    + clkw + 2 * 12;
    int cx0 = right - cluster_w;
    {
        int hov = pl__hover(m, cx0, 0, cluster_w, H);
        int prs = pl__pressed(pk, pi, PL_HIT_STATUS, 0);
        if (m->qs_open || hov || prs)
            pr_fill_rrect(cr, cx0, (H - 44) / 2, cluster_w, 44, TH_R_HOVER,
                          (prs || m->qs_open) ? TH_PRESS : TH_HOVER);
        int tx = cx0 + 12;
        if (m->batt_pct >= 0) {
            pl_draw_battery(cr, tx, cy, m->batt_pct, m->batt_charging);
            tx += PL_BATT_W + 5;
            if (show_pct) {
                tx += 8;
                pr_text(cr, t, TH_FONT_LABEL, pct, tx, cy, TH_FG_DIM, 0);
                tx += pctw;
            }
            tx += 16;
        }
        if (datew) {
            pr_text(cr, t, TH_FONT_LABEL, m->date, tx, cy, TH_FG_DIM, 0);
            tx += datew + 16;
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
            int show_close = pw >= 132;   /* close zone only when it stays >= TH_TOUCH */
            int aw = show_close ? pw - LO_CLOSE_W : pw;   /* activate-zone width */
            int hov = pl__hover(m, bx, 0, aw, H);
            int prs = pl__pressed(pk, pi, PL_HIT_ACTIVATE, i);

            if (it->active) {
                pr_fill_rrect(cr, bx, py, pw, LO_PILL_H, TH_R_PILL, TH_ACCENT_BG);
                pr_fill_rrect(cr, bx + 6, py + LO_PILL_H - 3, pw - 12, 3, 1.5, TH_ACCENT);
            } else if (hov || prs) {
                pr_fill_rrect(cr, bx, py, pw, LO_PILL_H, TH_R_PILL,
                              prs ? TH_PRESS : TH_HOVER);
            }

            /* below ~2 chars of label a truncated title is noise: center the
             * icon alone (the active underline still marks focus) */
            int icon_only = aw < 96;
            int ix = icon_only ? bx + (aw - LO_PILL_ICON) / 2 : bx + 12;
            if (it->icon)
                pr_draw_icon(cr, it->icon, ix, py + (LO_PILL_H - LO_PILL_ICON) / 2, LO_PILL_ICON, 0);
            else
                pr_draw_monogram(cr, t, it->key, ix, py + (LO_PILL_H - LO_PILL_ICON) / 2,
                                 LO_PILL_ICON, TH_R_MONO - 2, TH_TILE, TH_FG, TH_FONT_LABEL);

            if (!icon_only) {
                int tx = ix + LO_PILL_ICON + 10;
                int tw = aw - (tx - bx) - 8;
                pr_text(cr, t, TH_FONT_LABEL, it->label[0] ? it->label : "Window",
                        tx, cy, it->active ? TH_FG : TH_FG_DIM, tw > 8 ? tw : 8);
            }
            hits->v[hits->n++] = (struct panel_hit){ bx, 0, aw, H, PL_HIT_ACTIVATE, i };

            if (show_close) {
                int cxx = bx + pw - LO_CLOSE_W;
                int chov = pl__hover(m, cxx, 0, LO_CLOSE_W, H);
                if (chov)
                    pr_fill_rrect(cr, cxx + (LO_CLOSE_W - 36) / 2,
                                  py + (LO_PILL_H - 36) / 2, 36, 36, 18, TH_HOVER);
                pr_text_centered(cr, t, TH_FONT_LABEL, "×", cxx, LO_CLOSE_W, cy,
                                 chov ? TH_FG : TH_FG_DIM);
                hits->v[hits->n++] = (struct panel_hit){ cxx, 0, LO_CLOSE_W, H, PL_HIT_CLOSE, i };
            }
        }
    }
}

/* ------------------------------------------------------- tablet status bar */
static void panel_draw_statusbar(cairo_t *cr, pr_text_ctx *t, int W, int H,
                                 const struct panel_model *m, struct panel_hits *hits)
{
    hits->n = 0;
    double ba = m->bg_alpha > 0 ? m->bg_alpha : 1.0;
    int cy = H / 2;

    pr_fill_rect(cr, 0, 0, W, H, pl_with_alpha(0x000000u, ba * 0.35));
    pr_fill_rect(cr, 0, H - 1, W, 1, TH_HILITE);

    const char *focused = NULL;
    for (int i = 0; i < m->ntasks; i++) {
        if (m->tasks[i].active && m->tasks[i].label[0]) { focused = m->tasks[i].label; break; }
    }
    if (!focused && m->ntasks > 0 && m->tasks[0].label[0]) focused = m->tasks[0].label;
    if (focused) {
        int fw = pr_text(cr, t, TH_FONT_STATUS, focused, 18, cy, TH_FG_DIM, W / 3);
        hits->v[hits->n++] = (struct panel_hit){ 12, 0, fw + 12, H, PL_HIT_APPNAME, 0 };
    }

    pr_text_centered(cr, t, TH_FONT_STATUS_CLOCK, m->clock[0] ? m->clock : "00:00", 0, W, cy, TH_FG_DIM);

    int right = W - 18;
    int net_kind = m->net_kind ? m->net_kind : (m->wifi_on ? 1 : 0);
    int cluster_w = 58;                 /* battery body + cap + breathing room */
    if (net_kind) cluster_w += 30;
    int x0 = right - cluster_w;
    int hov = pl__hover(m, x0, 0, cluster_w + 18, H);
    int prs = pl__pressed(m->press_kind, m->press_idx, PL_HIT_STATUS, 0);
    if (m->qs_open || hov || prs)
        pr_fill_rrect(cr, x0 - 8, 2, cluster_w + 16, H - 4, (H - 4) / 2,
                      (prs || m->qs_open) ? TH_PRESS : TH_HOVER);

    int x = right - 41;
    if (m->batt_pct >= 0) {
        pl_draw_battery_small(cr, x, cy, m->batt_pct, m->batt_charging);
        x -= 15;
    }
    if (net_kind == 1)
        pl_draw_wifi_glyph(cr, x - 13, cy, TH_FG_DIM);
    else if (net_kind == 2)
        pl_draw_cell_glyph(cr, x - 24, cy, TH_FG_DIM);
    hits->v[hits->n++] = (struct panel_hit){ x0 - 8, 0, cluster_w + 16, H, PL_HIT_STATUS, 0 };
}

/* --------------------------------------------------------------- dock ----- */
static void dock__draw_item(cairo_t *cr, pr_text_ctx *t, const struct panel_item *it,
                            int x, int y, int size, int active)
{
    if (it->icon)
        pr_draw_icon(cr, it->icon, x, y, size, 0);
    else
        pr_draw_monogram(cr, t, it->key, x, y, size, 14, TH_TILE, TH_FG, TH_FONT_TITLE);
    if (active) {
        cairo_new_sub_path(cr);
        cairo_arc(cr, x + size / 2.0, y + size + 9, 3.2, 0, 2 * M_PI);
        pr_set(cr, TH_ACCENT);
        cairo_fill(cr);
    }
}

/* Hairline divider between dock segments: draws centered in the DOCK_SEP band
 * and advances *x past it.  Callers must emit exactly as many of these as the
 * width math reserves. */
static void dock__sep(cairo_t *cr, int *x, int iy, int icon, int gap)
{
    *x = *x - gap + (DOCK_SEP - gap) / 2;
    pr_fill_rect(cr, *x, iy + 6, 1.5, icon - 12, TH_SEP);
    *x += (DOCK_SEP - gap) / 2 + gap;
}

static void panel_draw_dock(cairo_t *cr, pr_text_ctx *t, int W, int H,
                            const struct panel_model *m, struct panel_hits *hits)
{
    hits->n = 0;
    double ba = m->bg_alpha > 0 ? m->bg_alpha : 1.0;
    int icon = DOCK_ICON, pad = DOCK_PAD_X, gap = DOCK_GAP;
    int nfav = m->nlaunch, nrun = m->ntasks;
    if (nfav < 0) nfav = 0;
    if (nrun < 0) nrun = 0;
    /* one divider after each non-empty segment (favorites, running) */
    int nsep = (nfav ? 1 : 0) + (nrun ? 1 : 0);

    int max_items = nfav + nrun + 1;
    int inner = max_items * icon + (max_items > 1 ? (max_items - 1) * gap : 0);
    inner += DOCK_SEP * nsep;
    int dw = inner + 2 * pad;
    int max_dw = W - 2 * TH_PAD;
    if (dw > max_dw) {
        int avail = max_dw - 2 * pad - DOCK_SEP * nsep
                    - (max_items > 1 ? (max_items - 1) * gap : 0);
        icon = avail / (max_items > 0 ? max_items : 1);
        if (icon < 40) icon = 40;
        inner = max_items * icon + (max_items > 1 ? (max_items - 1) * gap : 0);
        inner += DOCK_SEP * nsep;
        dw = inner + 2 * pad;
    }

    int dh = icon + 2 * pad;
    int dx = (W - dw) / 2;
    int dy = H - dh - DOCK_BOTTOM;
    int pk = m->press_kind, pi = m->press_idx;

    pr_fill_rrect(cr, dx, dy + 8, dw, dh, dh / 2, 0x4D000000u);
    cairo_save(cr);
    pr_rrect_path(cr, dx, dy, dw, dh, dh / 2);
    cairo_clip(cr);
    pr_fill_rrect(cr, dx, dy, dw, dh, dh / 2, pl_with_alpha(TH_CARD, ba * 0.78));
    pr_fill_rect(cr, dx + 18, dy + 1, dw - 36, 1.5, TH_HILITE);
    pr_fill_rect(cr, dx + 24, dy + dh - 1.0, dw - 48, 1.0, 0x22000000u);
    cairo_restore(cr);
    pr_stroke_rrect(cr, dx, dy, dw, dh, dh / 2, TH_BORDER, 1.0);

    int x = dx + pad, iy = dy + pad;
    for (int i = 0; i < nfav; i++) {
        int hov = pl__hover(m, x - 2, iy - 2, icon + 4, icon + 16);
        int prs = pl__pressed(pk, pi, PL_HIT_LAUNCH, i);
        if (hov || prs) pr_fill_rrect(cr, x - 4, iy - 4, icon + 8, icon + 8, 16, prs ? TH_PRESS : TH_HOVER);
        dock__draw_item(cr, t, &m->launch[i], x, iy, icon, 0);
        hits->v[hits->n++] = (struct panel_hit){ x - 4, iy - 8, icon + 8, icon + 22, PL_HIT_LAUNCH, i };
        x += icon + gap;
    }

    if (nfav) dock__sep(cr, &x, iy, icon, gap);

    for (int i = 0; i < nrun; i++) {
        int hov = pl__hover(m, x - 2, iy - 2, icon + 4, icon + 16);
        int prs = pl__pressed(pk, pi, PL_HIT_ACTIVATE, i);
        if (hov || prs) pr_fill_rrect(cr, x - 4, iy - 4, icon + 8, icon + 8, 16, prs ? TH_PRESS : TH_HOVER);
        dock__draw_item(cr, t, &m->tasks[i], x, iy, icon, 1);
        hits->v[hits->n++] = (struct panel_hit){ x - 4, iy - 8, icon + 8, icon + 22, PL_HIT_ACTIVATE, i };
        x += icon + gap;
    }

    if (nrun) dock__sep(cr, &x, iy, icon, gap);

    int hov = pl__hover(m, x - 2, iy - 2, icon + 4, icon + 4);
    int prs = pl__pressed(pk, pi, PL_HIT_APPGRID, 0);
    pr_fill_rrect(cr, x, iy, icon, icon, 14, (hov || prs) ? (prs ? TH_PRESS : TH_HOVER) : 0x1FFFFFFFu);
    pl_draw_appgrid_glyph(cr, x + icon / 2.0, iy + icon / 2.0, TH_FG);
    hits->v[hits->n++] = (struct panel_hit){ x - 4, iy - 8, icon + 8, icon + 22, PL_HIT_APPGRID, 0 };

    pr_fill_rrect(cr, W / 2 - 44, H - 8, 88, 4, 2, 0x70FFFFFFu);
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

/* The card's total logical height for a given model (charging adds a line).
 * Must mirror the y-advances in panel_draw_qs below. */
static int panel_qs_height(const struct qs_model *m)
{
    return 250 + (m->batt_charging ? 20 : 0);
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
    pr_text(cr, t, TH_FONT_TITLE, m->device[0] ? m->device : "iPad", x, y + 13, TH_FG, (int)cw);
    y += 32;
    pr_text(cr, t, TH_FONT_LABEL, m->date_long, x, y + 11, TH_FG_DIM, (int)cw);
    y += 34;
    pr_fill_rect(cr, x, y, cw, 1, TH_SEP);
    y += 20;

    /* battery block: label row + gauge track */
    if (m->batt_pct >= 0) {
        char pct[8]; snprintf(pct, sizeof pct, "%d%%", m->batt_pct);
        int pw, ph;
        pr_text_measure(t, TH_FONT_LABEL_MED, pct, &pw, &ph);
        pr_text(cr, t, TH_FONT_LABEL, "Battery", x, y + 11, TH_FG_DIM, 0);
        pr_text(cr, t, TH_FONT_LABEL_MED, pct, x + cw - pw, y + 11, TH_FG, 0);
        y += 30;
        pr_fill_rrect(cr, x, y, cw, 8, 4, pl_with_alpha(TH_CARD_INNER, 1.0));
        double lw = cw * m->batt_pct / 100.0;
        if (lw > 2)
            pr_fill_rrect(cr, x, y, lw, 8, 4,
                          m->batt_charging ? TH_GREEN
                          : (m->batt_pct <= 20 ? 0xFFFF453Au : TH_ACCENT));
        y += 20;
        if (m->batt_charging) {
            pr_text(cr, t, TH_FONT_SMALL, "Charging", x, y + 8, TH_GREEN, 0);
            y += 20;
        }
        y += 10;
    } else {
        y += 60;   /* keep the card balanced without a battery source */
    }

    /* actions: full touch-height buttons */
    double bw = (cw - TH_GAP) / 2, bh = TH_TOUCH;
    qs__button(cr, t, m, hits, x, y, bw, bh, "Overview",
               TH_ACCENT_DIM, TH_ACCENT, QS_HIT_OVERVIEW);
    qs__button(cr, t, m, hits, x + bw + TH_GAP, y, bw, bh, "Screenshot",
               pl_with_alpha(TH_CARD_INNER, 1.0), TH_FG, QS_HIT_SHOT);
}

/* ----------------------------------------------------------- window menu --- */

#define WM_W 180
#define WM_H 140
#define WM_BTN_H 40

static void panel_draw_window_menu(cairo_t *cr, pr_text_ctx *t, int W, int H,
                                   struct panel_hits *hits)
{
    hits->n = 0;
    pr_fill_rrect(cr, 0, 0, W, H, TH_R_CARD, TH_CARD);
    pr_stroke_rrect(cr, 0, 0, W, H, TH_R_CARD, TH_BORDER, 1.0);

    const struct { const char *label; int kind; uint32_t color; } items[] = {
        { "Minimize",  WM_HIT_MINIMIZE,  TH_FG },
        { "Maximize",  WM_HIT_MAXIMIZE,  TH_FG },
        { "Close",     WM_HIT_CLOSE,     0xFFFF453Au },
    };
    for (size_t i = 0; i < sizeof(items)/sizeof(items[0]); i++) {
        double by = TH_GAP + i * (WM_BTN_H + TH_GAP);
        pr_fill_rrect(cr, TH_GAP, by, W - 2 * TH_GAP, WM_BTN_H, TH_R_BUTTON, TH_CARD_INNER);
        pr_text(cr, t, TH_FONT_LABEL_MED, items[i].label,
                TH_GAP * 2, by + WM_BTN_H / 2, items[i].color, W - 4 * TH_GAP);
        hits->v[hits->n++] = (struct panel_hit){
            (int)(TH_GAP), (int)by, (int)(W - 2 * TH_GAP), WM_BTN_H,
            items[i].kind, 0
        };
    }
}

#endif /* PANEL_LAYOUT_H */

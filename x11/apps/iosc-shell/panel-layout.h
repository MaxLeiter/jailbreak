/*
 * panel-layout.h — the iosc panel's visual language + arrangement, as
 * wayland-free draw functions shared by the shell clients (wl_shm) and preview-host.c
 * (PNG). Tokens live in shell-theme.h; primitives in panel-render.h. Keeping
 * the arrangement here is what makes design iteration cheap: only this file
 * changes, never the compositor plumbing.
 *
 * The surfaces drawn from here:
 *   panel_draw_statusbar() — the tablet-DE slim top status bar:
 *     [ focused app | clock | wifi battery ]
 *   panel_draw_dock() — the tablet-DE floating bottom dock:
 *     [ favorites | running apps | apps ]
 *   panel_draw_qs()     — the quick-settings card (a second layer surface the
 *     panel maps under the status cluster): device name, date, battery gauge,
 *     Overview / Screenshot actions, over a frosted screencopy backdrop.
 *   panel_draw_window_menu(): Minimize / Maximize / Close for the focused app.
 *
 * All coordinates are LOGICAL px; the caller sets a cairo scale so 1 unit = 1pt.
 */
#ifndef PANEL_LAYOUT_H
#define PANEL_LAYOUT_H

#include "shell-theme.h"
#include "panel-render.h"
#include "shell-blur.h"

/* -------------------------------------------------------------- metrics --- */
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
    double bg_alpha;             /* 0..1 base opacity (iosc blends layers) */
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
    PL_HIT_LAUNCH = 1, PL_HIT_ACTIVATE = 2,
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
#define WM_H 152
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

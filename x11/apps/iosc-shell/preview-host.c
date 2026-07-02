/*
 * preview-host.c — render the REAL shell draw code to PNGs, off-device.
 *
 * The fast visual-iteration loop for the shell-polish work: it composes full
 * desktop scenes through the exact code the device clients run
 * (panel-layout.h, overview-layout.h, shell-blur.h) — same cairo/pango
 * primitives, same layout, same blur — over a mock wallpaper + windows.
 *
 * Scenes target Max's iPad 7 at the 1.5 default effective scale
 * (1440x1080 logical = 2160x1620 physical), plus a compact 720-wide scene
 * that proves the responsive behavior (panel sheds the date, QS card and
 * overview reflow) for Xios-in-Split-View style outputs. Nothing in the
 * layout code knows these numbers — W/H flow in like a compositor configure.
 *
 * Outputs (basenames under the out dir given as argv[1], default "design"):
 *   preview-desktop.png        wallpaper + split-view windows + status bar + dock
 *   preview-quicksettings.png  ... + Control Center card over a frosted crop
 *   preview-overview.png       the overview over the frosted desktop (real blur)
 *   preview-compact.png        720x1080 half-screen output: responsive proof
 *
 * Build (Linux container with cairo + pangocairo + SF, see build-preview.sh):
 *   cc preview-host.c $(pkg-config --cflags --libs cairo pangocairo) -lm -o preview-host
 * Run:
 *   IOSC_SHELL_ICONS=./design/preview-icons ./preview-host design
 */
#include "shell-theme.h"
#include "panel-render.h"
#include "panel-layout.h"
#include "overview-layout.h"
#include "shell-blur.h"
#include <stdio.h>
#include <stdlib.h>

/* iPad 7 logical canvas at the 1.5 default effective scale. */
static const int    LW = 1440, LH = 1080;
static const double SCALE = 1.5;
/* compact scene: half-screen (Split View-ish) output */
static const int CW = 720, CH = 1080;

static cairo_surface_t *load(const char *dir, const char *name)
{
    char p[512]; snprintf(p, sizeof p, "%s/%s.png", dir, name);
    return pr_icon_load(p);
}

static void set_item(struct panel_item *it, const char *label, const char *key,
                     cairo_surface_t *icon, int active)
{
    snprintf(it->label, sizeof it->label, "%s", label);
    snprintf(it->key, sizeof it->key, "%s", key);
    it->icon = icon; it->active = active;
}
static void set_ov(struct ov_item *it, const char *label, cairo_surface_t *icon, int active)
{
    snprintf(it->label, sizeof it->label, "%s", label);
    snprintf(it->key, sizeof it->key, "%s", label);
    it->icon = icon; it->active = active;
}

/*
 * A tablet-native app window: rounded body with a touch title bar — a centered
 * grab-handle pill (drag affordance) over the title, and ONE big close target
 * (36px circle in a 44px zone) at the right. No mouse-sized traffic lights.
 * This is the window chrome model we're speccing for iosc's server-side
 * decorations; the preview mocks it so the whole desktop reads tablet-first.
 */
#define WIN_BAR 56
static void mock_window(cairo_t *cr, pr_text_ctx *t, double x, double y, double w, double h,
                        int dark, const char *title)
{
    pr_fill_rrect(cr, x + 3, y + 7, w, h, 20, 0x59000000u);           /* soft shadow */
    pr_fill_rrect(cr, x, y, w, h, 18, dark ? 0xFF232326u : 0xFFEFEFF1u);
    pr_fill_rrect(cr, x, y, w, WIN_BAR, 18, dark ? 0xFF2E2E32u : 0xFFE2E2E6u);
    pr_fill_rect(cr, x, y + WIN_BAR - 18, w, 18, dark ? 0xFF2E2E32u : 0xFFE2E2E6u);

    /* grab handle: the drag affordance, centered near the top edge */
    pr_fill_rrect(cr, x + w / 2 - 24, y + 9, 48, 5, 2.5,
                  dark ? 0x40FFFFFFu : 0x33000000u);
    /* title, centered in the bar's lower half */
    pr_text_centered(cr, t, TH_FONT_LABEL_MED, title, x, w, y + WIN_BAR - 21,
                     dark ? TH_FG_DIM : 0xB3333336u);
    /* close: one large touch circle at the bar's right */
    {
        double cxx = x + w - 32, cyy = y + WIN_BAR / 2.0;
        cairo_new_sub_path(cr);
        cairo_arc(cr, cxx, cyy, 18, 0, 2 * M_PI);
        pr_set(cr, dark ? 0x2EFFFFFFu : 0x1F000000u);
        cairo_fill(cr);
        pr_text_centered(cr, t, TH_FONT_LABEL, "×", cxx - 18, 36, cyy,
                         dark ? TH_FG_DIM : 0x8C333336u);
    }

    if (dark) {
        pr_text(cr, t, "Monospace 15", "max@ipad ~ % iosc --status",
                x + 22, y + WIN_BAR + 26, 0xFF8CE99Au, (int)w - 44);
        pr_text(cr, t, "Monospace 15", "compositor: running   clients: 3",
                x + 22, y + WIN_BAR + 54, TH_FG_DIM, (int)w - 44);
    } else {
        for (int i = 0; i < 6; i++)
            pr_fill_rrect(cr, x + 22, y + WIN_BAR + 18 + i * 30,
                          (w - 70) * (i == 5 ? 0.4 : 0.86), 12, 6, 0x1A000000u);
    }
}

/* Wallpaper + windows for a W x H output. Tablet model: windows fill the work
 * area as a split view (nwin==2) or fullscreen (nwin==1) — not a pile of
 * little floating rectangles. */
static void draw_desktop_base(cairo_t *cr, pr_text_ctx *t, int W, int H, int nwin)
{
    pr_fill_vgrad(cr, 0, 0, W, H, TH_WALL_TOP, TH_WALL_BOT);
    cairo_pattern_t *g = cairo_pattern_create_radial(W * 0.3, 120, 40, W * 0.3, 120, 700);
    cairo_pattern_add_color_stop_rgba(g, 0, 0.35, 0.30, 0.55, 0.35);
    cairo_pattern_add_color_stop_rgba(g, 1, 0, 0, 0, 0);
    cairo_set_source(cr, g);
    cairo_paint(cr);
    cairo_pattern_destroy(g);

    int gap = 12, top = BAR_REF_H + gap, bot = H - DOCK_REF_H + 4;
    if (nwin >= 2) {
        int split = (int)(W * 0.56);
        mock_window(cr, t, gap, top, split - gap - gap / 2, bot - top, 0, "Text Editor");
        mock_window(cr, t, split + gap / 2, top, W - split - gap - gap / 2, bot - top,
                    1, "Console");
    } else {
        mock_window(cr, t, gap, top, W - 2 * gap, bot - top, 1, "Console");
    }
}

static cairo_surface_t *new_canvas(cairo_t **out_cr, int lw, int lh)
{
    cairo_surface_t *s = cairo_image_surface_create(CAIRO_FORMAT_ARGB32,
                                                    (int)(lw * SCALE), (int)(lh * SCALE));
    cairo_t *cr = cairo_create(s);
    cairo_scale(cr, SCALE, SCALE);
    *out_cr = cr;
    return s;
}

static int save(cairo_surface_t *s, const char *dir, const char *name)
{
    char p[512]; snprintf(p, sizeof p, "%s/%s", dir, name);
    cairo_surface_flush(s);
    cairo_status_t st = cairo_surface_write_to_png(s, p);
    printf("wrote %s status=%s\n", p, cairo_status_to_string(st));
    return st == CAIRO_STATUS_SUCCESS;
}

int main(int argc, char **argv)
{
    const char *outdir = argc > 1 ? argv[1] : "design";
    const char *icons = getenv("IOSC_SHELL_ICONS");
    if (!icons) icons = "design/preview-icons";

    cairo_surface_t *i_files = load(icons, "files");
    cairo_surface_t *i_text  = load(icons, "text-editor");
    cairo_surface_t *i_term  = load(icons, "console");
    cairo_surface_t *i_calc  = load(icons, "calculator");

    /* ---- shared panel model ------------------------------------------- */
    struct panel_model pm; memset(&pm, 0, sizeof pm);
    pm.bg_alpha = 0.85;   /* iosc blends layers since e11aa52 */
    pm.have_ptr = 1; pm.px = 700; pm.py = BAR_REF_H / 2;
    snprintf(pm.clock, sizeof pm.clock, "9:41");
    snprintf(pm.date, sizeof pm.date, "Tue Jul 1");
    pm.batt_pct = 82; pm.batt_charging = 0;
    pm.nlaunch = 4;
    set_item(&pm.launch[0], "Files",       "F", i_files, 0);
    set_item(&pm.launch[1], "Text Editor", "T", i_text,  0);
    set_item(&pm.launch[2], "Console",     "C", i_term,  0);
    set_item(&pm.launch[3], "Calculator",  "C", i_calc,  0);
    pm.ntasks = 2;
    set_item(&pm.tasks[0], "Text Editor", "T", i_text,  1);
    set_item(&pm.tasks[1], "Console",     "C", i_term,  0);

    struct panel_hits hits;
    int ok = 1;

    /* ---- 1: desktop (split view + panel) ------------------------------ */
    cairo_t *cr; cairo_surface_t *desk = new_canvas(&cr, LW, LH);
    pr_text_ctx t = pr_text_ctx_new(cr);
    draw_desktop_base(cr, &t, LW, LH, 2);
    panel_draw_statusbar(cr, &t, LW, BAR_REF_H, &pm, &hits);
    cairo_save(cr);
    cairo_translate(cr, 0, LH - DOCK_REF_H);
    panel_draw_dock(cr, &t, LW, DOCK_REF_H, &pm, &hits);
    cairo_restore(cr);
    pr_text_ctx_free(&t);
    cairo_destroy(cr);
    ok &= save(desk, outdir, "preview-desktop.png");

    /* ---- 2: quick settings over a frosted crop ------------------------ */
    {
        struct qs_model qm; memset(&qm, 0, sizeof qm);
        snprintf(qm.device, sizeof qm.device, "Max's iPad");
        snprintf(qm.date_long, sizeof qm.date_long, "Tuesday, July 1");
        qm.batt_pct = 82; qm.batt_charging = 1;
        int qw = panel_qs_width(LW);
        int qh = panel_qs_height(&qm);
        qm.have_ptr = 1; qm.px = 90; qm.py = qh - TH_CARD_PAD - 30; /* hover "Overview" */
        int qx = LW - QS_MARGIN - qw, qy = BAR_REF_H + QS_MARGIN;

        /* crop the card region from the desktop (physical px) and frost it —
         * the exact path ioscpanel runs via screencopy */
        cairo_surface_t *crop = cairo_image_surface_create(CAIRO_FORMAT_RGB24,
                                    (int)(qw * SCALE), (int)(qh * SCALE));
        cairo_t *cc = cairo_create(crop);
        cairo_set_source_surface(cc, desk, -qx * SCALE, -qy * SCALE);
        cairo_paint(cc);
        cairo_destroy(cc);
        qm.backdrop = sb_backdrop_build(crop, 4, 6);
        cairo_surface_destroy(crop);

        cairo_t *c2; cairo_surface_t *qs = new_canvas(&c2, LW, LH);
        cairo_save(c2);
        cairo_identity_matrix(c2);
        cairo_set_source_surface(c2, desk, 0, 0);
        cairo_paint(c2);
        cairo_restore(c2);

        pr_text_ctx t2 = pr_text_ctx_new(c2);
        cairo_save(c2);
        cairo_translate(c2, qx, qy);
        struct panel_hits qhits;
        panel_draw_qs(c2, &t2, qw, qh, &qm, &qhits);
        cairo_restore(c2);
        pr_text_ctx_free(&t2);
        cairo_destroy(c2);
        ok &= save(qs, outdir, "preview-quicksettings.png");
        cairo_surface_destroy(qs);
        cairo_surface_destroy(qm.backdrop);
    }

    /* ---- 3: the overview over the frosted desktop --------------------- */
    {
        struct ov_model om; memset(&om, 0, sizeof om);
        om.backdrop = sb_backdrop_build(desk, 8, 12);  /* the client's exact path */
        om.have_ptr = 1; om.px = 700; om.py = 460;     /* hover an app tile */
        om.anim_t = 1.0;
        om.nwins = 2;
        set_ov(&om.wins[0], "Text Editor", i_text, 1);
        set_ov(&om.wins[1], "Console",     i_term, 0);
        om.napps = 8;
        set_ov(&om.apps[0], "Files",        i_files, 0);
        set_ov(&om.apps[1], "Text Editor",  i_text,  0);
        set_ov(&om.apps[2], "Console",      i_term,  0);
        set_ov(&om.apps[3], "Calculator",   i_calc,  0);
        set_ov(&om.apps[4], "Image Viewer", NULL,    0);
        set_ov(&om.apps[5], "Hitori",       NULL,    0);
        set_ov(&om.apps[6], "Web",          NULL,    0);
        set_ov(&om.apps[7], "Settings",     NULL,    0);

        cairo_t *c3; cairo_surface_t *ov = new_canvas(&c3, LW, LH);
        pr_text_ctx t3 = pr_text_ctx_new(c3);
        struct ov_hits ohits;
        ov_draw(c3, &t3, LW, LH, &om, &ohits);
        pr_text_ctx_free(&t3);
        cairo_destroy(c3);
        ok &= save(ov, outdir, "preview-overview.png");
        cairo_surface_destroy(ov);
        cairo_surface_destroy(om.backdrop);
    }

    /* ---- 4: compact half-screen output — the responsive proof --------- */
    {
        cairo_t *c4; cairo_surface_t *cmp = new_canvas(&c4, CW, CH);
        pr_text_ctx t4 = pr_text_ctx_new(c4);
        draw_desktop_base(c4, &t4, CW, CH, 1);
        struct panel_model cpm = pm;
        cpm.have_ptr = 0;
        cpm.nlaunch = 3;                     /* tighter strip on narrow outputs */
        struct panel_hits chits;
        panel_draw_statusbar(c4, &t4, CW, BAR_REF_H, &cpm, &chits);
        cairo_save(c4);
        cairo_translate(c4, 0, CH - DOCK_REF_H);
        panel_draw_dock(c4, &t4, CW, DOCK_REF_H, &cpm, &chits);
        cairo_restore(c4);
        pr_text_ctx_free(&t4);
        cairo_destroy(c4);
        ok &= save(cmp, outdir, "preview-compact.png");
        cairo_surface_destroy(cmp);
    }

    cairo_surface_destroy(desk);
    return ok ? 0 : 1;
}

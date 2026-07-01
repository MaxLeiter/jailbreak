/*
 * preview-host.c — render the REAL shell draw code to PNGs, off-device.
 *
 * The fast visual-iteration loop for the shell-polish work: it composes full
 * desktop scenes through the exact code the device clients run
 * (panel-layout.h, overview-layout.h, shell-blur.h) — same cairo/pango
 * primitives, same layout, same blur — over a mock wallpaper + windows.
 *
 * Outputs (basenames under the out dir given as argv[1], default "design"):
 *   preview-desktop.png        wallpaper + windows + the panel (hover on a pill)
 *   preview-quicksettings.png  ... + the QS card over a frosted crop (real blur)
 *   preview-overview.png       the overview over the frosted desktop (real blur)
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

/* iPad-shaped logical canvas (2732x2048 physical at SCALE 2). */
static const int LW = 1366, LH = 1024, SCALE = 2;
static const int PANEL_H = 44;

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

/* A plausible app window: shadow, rounded body, header bar with traffic dots. */
static void mock_window(cairo_t *cr, pr_text_ctx *t, double x, double y, double w, double h,
                        int dark, const char *title)
{
    pr_fill_rrect(cr, x + 3, y + 6, w, h, 14, 0x59000000u);           /* soft shadow */
    pr_fill_rrect(cr, x, y, w, h, 12, dark ? 0xFF232326u : 0xFFEFEFF1u);
    pr_fill_rrect(cr, x, y, w, 38, 12, dark ? 0xFF2E2E32u : 0xFFE2E2E6u);
    pr_fill_rect(cr, x, y + 26, w, 12, dark ? 0xFF2E2E32u : 0xFFE2E2E6u);
    static const uint32_t dots[] = { 0xFFFF5F57u, 0xFFFEBC2Eu, 0xFF28C840u };
    for (int i = 0; i < 3; i++) {
        cairo_new_sub_path(cr);
        cairo_arc(cr, x + 20 + i * 20, y + 19, 6, 0, 2 * M_PI);
        pr_set(cr, dots[i]);
        cairo_fill(cr);
    }
    pr_text_centered(cr, t, TH_FONT_LABEL_MED, title, x, w, y + 19,
                     dark ? TH_FG_DIM : 0xB3333336u);
    if (dark) {
        pr_text(cr, t, "Monospace 12", "max@ipad ~ % iosc --status",
                x + 18, y + 60, 0xFF8CE99Au, (int)w - 36);
        pr_text(cr, t, "Monospace 12", "compositor: running   clients: 3",
                x + 18, y + 82, TH_FG_DIM, (int)w - 36);
    } else {
        for (int i = 0; i < 5; i++)
            pr_fill_rrect(cr, x + 18, y + 58 + i * 24, (w - 60) * (i == 4 ? 0.4 : 0.86),
                          10, 5, 0x1A000000u);
    }
}

/* The desktop base: wallpaper gradient + two windows (panel drawn separately). */
static void draw_desktop_base(cairo_t *cr, pr_text_ctx *t)
{
    pr_fill_vgrad(cr, 0, 0, LW, LH, TH_WALL_TOP, TH_WALL_BOT);
    /* a soft glow up top so the "wallpaper" isn't flat */
    cairo_pattern_t *g = cairo_pattern_create_radial(LW * 0.3, 120, 40, LW * 0.3, 120, 700);
    cairo_pattern_add_color_stop_rgba(g, 0, 0.35, 0.30, 0.55, 0.35);
    cairo_pattern_add_color_stop_rgba(g, 1, 0, 0, 0, 0);
    cairo_set_source(cr, g);
    cairo_paint(cr);
    cairo_pattern_destroy(g);

    mock_window(cr, t, 90,  120, 640, 500, 0, "Text Editor");
    mock_window(cr, t, 780, 170, 500, 420, 1, "Console");
}

static cairo_surface_t *new_canvas(cairo_t **out_cr)
{
    cairo_surface_t *s = cairo_image_surface_create(CAIRO_FORMAT_ARGB32,
                                                    LW * SCALE, LH * SCALE);
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
    pm.bg_alpha = 1.0;
    pm.have_ptr = 1; pm.px = 700; pm.py = PANEL_H / 2;   /* hover the 2nd pill */
    snprintf(pm.clock, sizeof pm.clock, "9:41");
    snprintf(pm.date, sizeof pm.date, "Tue Jul 1");
    pm.batt_pct = 82; pm.batt_charging = 0;
    pm.nlaunch = 4;
    set_item(&pm.launch[0], "Files",       "F", i_files, 0);
    set_item(&pm.launch[1], "Text Editor", "T", i_text,  0);
    set_item(&pm.launch[2], "Console",     "C", i_term,  0);
    set_item(&pm.launch[3], "Calculator",  "C", i_calc,  0);
    pm.ntasks = 3;
    set_item(&pm.tasks[0], "Text Editor", "T", i_text,  1);
    set_item(&pm.tasks[1], "Files",       "F", i_files, 0);
    set_item(&pm.tasks[2], "Console",     "C", i_term,  0);

    struct panel_hits hits;
    int ok = 1;

    /* ---- 1: desktop --------------------------------------------------- */
    cairo_t *cr; cairo_surface_t *desk = new_canvas(&cr);
    pr_text_ctx t = pr_text_ctx_new(cr);
    draw_desktop_base(cr, &t);
    panel_draw_topbar(cr, &t, LW, PANEL_H, &pm, &hits);
    pr_text_ctx_free(&t);
    cairo_destroy(cr);
    ok &= save(desk, outdir, "preview-desktop.png");

    /* ---- 2: quick settings over a frosted crop ------------------------ */
    {
        struct qs_model qm; memset(&qm, 0, sizeof qm);
        snprintf(qm.device, sizeof qm.device, "Max's iPad");
        snprintf(qm.date_long, sizeof qm.date_long, "Tuesday, July 1");
        qm.batt_pct = 82; qm.batt_charging = 1;
        qm.have_ptr = 1; qm.px = 80; qm.py = 150;        /* hover "Overview" */
        int qh = panel_qs_height(&qm);
        int qx = LW - QS_MARGIN - QS_W, qy = PANEL_H + QS_MARGIN;

        /* crop the card region from the desktop (physical px) and frost it —
         * the exact path ioscpanel runs via screencopy */
        cairo_surface_t *crop = cairo_image_surface_create(CAIRO_FORMAT_RGB24,
                                    QS_W * SCALE, qh * SCALE);
        cairo_t *cc = cairo_create(crop);
        cairo_set_source_surface(cc, desk, -qx * SCALE, -qy * SCALE);
        cairo_paint(cc);
        cairo_destroy(cc);
        qm.backdrop = sb_backdrop_build(crop, 4, 6);
        cairo_surface_destroy(crop);

        cairo_t *c2; cairo_surface_t *qs = new_canvas(&c2);
        cairo_save(c2);
        cairo_identity_matrix(c2);
        cairo_set_source_surface(c2, desk, 0, 0);
        cairo_paint(c2);
        cairo_restore(c2);

        pr_text_ctx t2 = pr_text_ctx_new(c2);
        cairo_save(c2);
        cairo_translate(c2, qx, qy);
        struct panel_hits qhits;
        panel_draw_qs(c2, &t2, QS_W, qh, &qm, &qhits);
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
        om.have_ptr = 1; om.px = LW / 2 - 160; om.py = 560; /* hover an app tile */
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

        cairo_t *c3; cairo_surface_t *ov = new_canvas(&c3);
        pr_text_ctx t3 = pr_text_ctx_new(c3);
        struct ov_hits ohits;
        ov_draw(c3, &t3, LW, LH, &om, &ohits);
        pr_text_ctx_free(&t3);
        cairo_destroy(c3);
        ok &= save(ov, outdir, "preview-overview.png");
        cairo_surface_destroy(ov);
        cairo_surface_destroy(om.backdrop);
    }

    cairo_surface_destroy(desk);
    return ok ? 0 : 1;
}

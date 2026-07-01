/*
 * preview-host.c — render the REAL panel draw code (panel-layout.h) to a PNG,
 * off-device. This is the fast visual-iteration loop: it produces exactly what
 * ioscpanel will draw (same cairo/pango primitives, same layout), composited
 * over a sample wallpaper + a couple of windows so translucency reads.
 *
 * Build (native Linux, needs cairo + pangocairo dev):
 *   cc preview-host.c $(pkg-config --cflags --libs cairo pangocairo) -lm -o preview-host
 * Run:
 *   IOSC_SHELL_ICONS=./design/preview-icons ./preview-host out.png
 *
 * The icon dir must contain <key>.png for each item below (files.png etc.).
 */
#include "panel-layout.h"
#include <stdio.h>
#include <stdlib.h>

static int LW = 1360;      /* logical bar width  */
static int BARH = 40;      /* logical bar height */
static int DESKH = 150;    /* logical desktop strip shown below the bar */
static int SCALE = 2;

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

int main(int argc, char **argv)
{
    const char *out = argc > 1 ? argv[1] : "panel-preview.png";
    const char *icons = getenv("IOSC_SHELL_ICONS");
    if (!icons) icons = "design/preview-icons";

    int CW = LW * SCALE, CH = (BARH + DESKH) * SCALE;
    cairo_surface_t *surf = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, CW, CH);
    cairo_t *cr = cairo_create(surf);
    cairo_scale(cr, SCALE, SCALE);

    /* wallpaper: deep blue->indigo gradient across the whole canvas */
    pr_fill_vgrad(cr, 0, 0, LW, BARH + DESKH, 0xFF141824u, 0xFF241832u);
    /* two windows peeking under the bar so blend is visible */
    pr_fill_rrect(cr, 60, 30, 460, 320, 14, 0xFFECECEEu);
    pr_fill_rrect(cr, 560, 26, 480, 320, 14, 0xFF2C2E36u);

    pr_text_ctx t = pr_text_ctx_new(cr);

    struct panel_model m; memset(&m, 0, sizeof m);
    m.bg_alpha = 0.72;
    m.have_ptr = 1; m.px = 620; m.py = BARH/2;   /* hover the 2nd pill */
    snprintf(m.clock, sizeof m.clock, "%s", "9:41");

    cairo_surface_t *i_files = load(icons, "files");
    cairo_surface_t *i_text  = load(icons, "text-editor");
    cairo_surface_t *i_term  = load(icons, "console");
    cairo_surface_t *i_calc  = load(icons, "calculator");

    m.nlaunch = 4;
    set_item(&m.launch[0], "Files",       "F", i_files, 0);
    set_item(&m.launch[1], "Text Editor", "T", i_text,  0);
    set_item(&m.launch[2], "Console",     "C", i_term,  0);
    set_item(&m.launch[3], "Calculator",  "C", i_calc,  0);

    m.ntasks = 3;
    set_item(&m.tasks[0], "Text Editor", "T", i_text,  1);
    set_item(&m.tasks[1], "Files",       "F", i_files, 0);
    set_item(&m.tasks[2], "Calculator",  "C", i_calc,  0);

    struct panel_hits hits;
    panel_draw_topbar(cr, &t, LW, BARH, &m, &hits);

    pr_text_ctx_free(&t);
    cairo_surface_flush(surf);
    cairo_status_t st = cairo_surface_write_to_png(surf, out);
    printf("wrote %s (%dx%d) status=%s\n", out, CW, CH, cairo_status_to_string(st));

    cairo_destroy(cr);
    cairo_surface_destroy(surf);
    return st == CAIRO_STATUS_SUCCESS ? 0 : 1;
}

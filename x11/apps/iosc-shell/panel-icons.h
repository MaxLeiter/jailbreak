/*
 * panel-icons.h — resolve a .desktop Icon= name to an image file on disk.
 *
 * Runtime loading goes through GdkPixbuf. PNGs remain the fast path, but when
 * librsvg2-common is installed the same loader path also handles SVG theme
 * icons. Resolution order:
 *
 *   1. shipped set   $IOSC_SHELL_ICONS or <jbroot>/usr/share/iosc-shell/icons
 *                    (<name>.svg preferred, then PNG/@2x/@3x fallbacks)
 *   2. hicolor SVGs  <root>/icons/hicolor/scalable/apps/<name>.svg
 *   3. hicolor PNGs  <root>/icons/hicolor/<size>/apps/<name>.png (largest first)
 *   4. flat pixmaps  <root>/pixmaps/<name>.png or .svg
 *
 * Returns 1 and fills out[] with a path on success, else 0 (caller draws a
 * monogram tile).
 */
#ifndef PANEL_ICONS_H
#define PANEL_ICONS_H

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "panel-render.h"

static const char *PI_HICOLOR_SIZES[] = {
    "512x512", "256x256", "192x192", "128x128", "96x96", "64x64", "48x48",
};

static int pi_is_file(const char *p) { return access(p, R_OK) == 0; }

static int pi_try(char *out, size_t outsz, const char *fmt,
                  const char *a, const char *b, const char *c)
{
    snprintf(out, outsz, fmt, a, b, c);
    return pi_is_file(out);
}

/* Pick the best shipped variant for the current scale (@3x >= 3, @2x >= 2). */
static int pi_shipped(const char *assets, const char *name, int scale,
                      char *out, size_t outsz)
{
    snprintf(out, outsz, "%s/%s.svg", assets, name);
    if (pi_is_file(out)) return 1;
    if (scale >= 3) {
        snprintf(out, outsz, "%s/%s@3x.png", assets, name);
        if (pi_is_file(out)) return 1;
    }
    if (scale >= 2) {
        snprintf(out, outsz, "%s/%s@2x.png", assets, name);
        if (pi_is_file(out)) return 1;
    }
    snprintf(out, outsz, "%s/%s.png", assets, name);
    if (pi_is_file(out)) return 1;
    return 0;
}

/* Resolve `name` to an SVG/PNG path. `name` is a .desktop Icon= value: a bare
 * theme name (org.gnome.Calculator), or an absolute path, possibly with an
 * extension. */
static int pi_resolve(const char *name, int scale, char *out, size_t outsz)
{
    if (!name || !*name) return 0;

    /* absolute path in the .desktop (Icon=/path/to/foo.svg or .png) */
    if (name[0] == '/') {
        if (pi_is_file(name)) { snprintf(out, outsz, "%s", name); return 1; }
        return 0;
    }

    /* strip a trailing extension if the .desktop gave one */
    char base[256];
    snprintf(base, sizeof base, "%s", name);
    size_t bl = strlen(base);
    if (bl > 4) {
        char *dot = strrchr(base, '.');
        if (dot && (!strcmp(dot, ".png") || !strcmp(dot, ".svg") || !strcmp(dot, ".xpm")))
            *dot = 0;
    }

    const char *assets = getenv("IOSC_SHELL_ICONS");
    char default_assets[256];
    if (!assets || !*assets) {
        sd_join_path(default_assets, sizeof default_assets, sd_jbroot(),
                     "/usr/share/iosc-shell/icons");
        assets = default_assets;
    }
    if (pi_shipped(assets, base, scale, out, outsz)) return 1;

    /* Prefer scalable theme SVGs now that librsvg2-common is part of the shell
     * install; fall back to rasters for apps that only ship PNG icons. */
    char share_roots[2][256];
    sd_join_path(share_roots[0], sizeof share_roots[0], sd_jbroot(), "/usr/share");
    sd_join_path(share_roots[1], sizeof share_roots[1], sd_jbroot(), "/usr/local/share");
    for (size_t r = 0; r < sizeof(share_roots)/sizeof(share_roots[0]); r++) {
        if (pi_try(out, outsz, "%s/icons/hicolor/%s/apps/%s.svg",
                   share_roots[r], "scalable", base)) return 1;
        for (size_t s = 0; s < sizeof(PI_HICOLOR_SIZES)/sizeof(PI_HICOLOR_SIZES[0]); s++) {
            if (pi_try(out, outsz, "%s/icons/hicolor/%s/apps/%s.png",
                       share_roots[r], PI_HICOLOR_SIZES[s], base)) return 1;
        }
        if (pi_try(out, outsz, "%s/pixmaps/%s.%s", share_roots[r], base, "png")) return 1;
        if (pi_try(out, outsz, "%s/pixmaps/%s.%s", share_roots[r], base, "svg")) return 1;
    }
    return 0;
}

static cairo_surface_t *pi_load_surface(const char *name, int scale)
{
    char path[512];
    if (!pi_resolve(name, scale, path, sizeof path)) return NULL;
    return pr_icon_load(path);
}

#endif /* PANEL_ICONS_H */

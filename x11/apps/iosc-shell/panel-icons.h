/*
 * panel-icons.h — resolve a .desktop Icon= name to a PNG file on disk.
 *
 * There is no librsvg / gdk-pixbuf SVG loader on device, so we never rasterise
 * SVG at runtime. Instead the build pre-rasterises each app's hicolor/scalable
 * SVG into a shipped PNG set (see gen-shell-icons.sh), and here we resolve to a
 * PNG only, in this order:
 *
 *   1. shipped set   $IOSC_SHELL_ICONS or /var/jb/usr/share/iosc-shell/icons
 *                    (<name>.png, or <name>@2x.png / @3x.png for hidpi)
 *   2. hicolor PNGs  <root>/icons/hicolor/<size>/apps/<name>.png (largest first)
 *   3. flat pixmaps  <root>/pixmaps/<name>.png
 *
 * Returns 1 and fills out[] with a path on success, else 0 (caller draws a
 * monogram tile). cairo's built-in PNG reader loads the result — no extra deps.
 */
#ifndef PANEL_ICONS_H
#define PANEL_ICONS_H

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define PI_ASSETS_DEFAULT "/var/jb/usr/share/iosc-shell/icons"

/* freedesktop share roots to search for hicolor/pixmaps (largest raster wins). */
static const char *PI_SHARE_ROOTS[] = {
    "/var/jb/usr/share",
    "/var/jb/usr/local/share",
};
static const char *PI_HICOLOR_SIZES[] = {
    "512x512", "256x256", "192x192", "128x128", "96x96", "64x64", "48x48",
};

static int pi_is_file(const char *p) { return access(p, R_OK) == 0; }

/* Pick the best shipped variant for the current scale (@3x >= 3, @2x >= 2). */
static int pi_shipped(const char *assets, const char *name, int scale,
                      char *out, size_t outsz)
{
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

/* Resolve `name` to a PNG path. `name` is a .desktop Icon= value: a bare theme
 * name (org.gnome.Calculator), or an absolute path, possibly with an extension. */
static int pi_resolve(const char *name, int scale, char *out, size_t outsz)
{
    if (!name || !*name) return 0;

    /* absolute path in the .desktop (Icon=/path/to/foo.png) */
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
    if (!assets || !*assets) assets = PI_ASSETS_DEFAULT;
    if (pi_shipped(assets, base, scale, out, outsz)) return 1;

    /* hicolor rasters, largest first */
    for (size_t r = 0; r < sizeof(PI_SHARE_ROOTS)/sizeof(PI_SHARE_ROOTS[0]); r++) {
        for (size_t s = 0; s < sizeof(PI_HICOLOR_SIZES)/sizeof(PI_HICOLOR_SIZES[0]); s++) {
            snprintf(out, outsz, "%s/icons/hicolor/%s/apps/%s.png",
                     PI_SHARE_ROOTS[r], PI_HICOLOR_SIZES[s], base);
            if (pi_is_file(out)) return 1;
        }
        snprintf(out, outsz, "%s/pixmaps/%s.png", PI_SHARE_ROOTS[r], base);
        if (pi_is_file(out)) return 1;
    }
    return 0;
}

#endif /* PANEL_ICONS_H */

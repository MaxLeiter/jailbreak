/*
 * shell-draw.h — shared wl_shm software renderer for the iosc shell clients
 * (ioscpanel, ioscoverview). Header-only, all `static`: each binary compiles its
 * own copy (they are separate executables, so no link conflict). Keeps the panel
 * and overview on ONE renderer instead of divergent copies.
 *
 * Provides: a 5x7 bitmap font, a `shell_canvas` (an mmap'd ARGB8888 wl_shm buffer
 * scaled logical->physical), fill/glyph/text draw primitives in logical px, a
 * .desktop launcher scan, and the fork+exec launch used by both clients.
 *
 * Colors are BGRA-in-memory (iosc's IOSurface order): write 0xAARRGGBB and the
 * little-endian bytes land as B,G,R,A. Alpha is currently ignored by iosc (it
 * forces opaque), so backgrounds should be fully opaque (A=0xff).
 */
#ifndef SHELL_DRAW_H
#define SHELL_DRAW_H

#include <wayland-client.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <fcntl.h>
#include <dirent.h>
#include <sys/mman.h>

/* An anonymous, unlinked, sized fd for a wl_shm pool (shared by the bitmap
 * canvas below AND ioscpanel's cairo-backed buffer). Kept outside SD_NO_DRAW so
 * the cairo panel can reuse it without pulling in the bitmap renderer. */
static int sd_create_anon_fd(size_t size)
{
    static const char *dirs[] = { "/var/jb/tmp", "/tmp" };
    for (size_t i = 0; i < sizeof(dirs)/sizeof(dirs[0]); i++) {
        char tmpl[64];
        snprintf(tmpl, sizeof tmpl, "%s/ioscshell-XXXXXX", dirs[i]);
        int fd = mkstemp(tmpl);
        if (fd < 0) continue;
        unlink(tmpl);
        if (ftruncate(fd, (off_t)size) < 0) { close(fd); continue; }
        return fd;
    }
    return -1;
}

/* Everything from here to the matching #endif is the legacy 5x7-bitmap software
 * renderer, still used by ioscoverview. ioscpanel now draws with cairo/pango
 * (panel-render.h) and defines SD_NO_DRAW to skip this block. */
#ifndef SD_NO_DRAW
/* ------------------------------------------------------------- 5x7 font ---
 * Column-major, 5 columns/glyph, LSB = top row. Digits, ':', space, A-Z, and a
 * few punctuation; lowercase folds to uppercase at draw time. */
struct sd_glyph { char c; uint8_t col[5]; };
static const struct sd_glyph SD_FONT[] = {
    {' ', {0x00,0x00,0x00,0x00,0x00}},
    {'0', {0x3E,0x51,0x49,0x45,0x3E}}, {'1', {0x00,0x42,0x7F,0x40,0x00}},
    {'2', {0x42,0x61,0x51,0x49,0x46}}, {'3', {0x21,0x41,0x45,0x4B,0x31}},
    {'4', {0x18,0x14,0x12,0x7F,0x10}}, {'5', {0x27,0x45,0x45,0x45,0x39}},
    {'6', {0x3C,0x4A,0x49,0x49,0x30}}, {'7', {0x01,0x71,0x09,0x05,0x03}},
    {'8', {0x36,0x49,0x49,0x49,0x36}}, {'9', {0x06,0x49,0x49,0x29,0x1E}},
    {':', {0x00,0x36,0x36,0x00,0x00}}, {'.', {0x00,0x60,0x60,0x00,0x00}},
    {'-', {0x08,0x08,0x08,0x08,0x08}}, {'/', {0x20,0x10,0x08,0x04,0x02}},
    {'%', {0x23,0x13,0x08,0x64,0x62}}, {'+', {0x08,0x08,0x3E,0x08,0x08}},
    {'A', {0x7E,0x11,0x11,0x11,0x7E}}, {'B', {0x7F,0x49,0x49,0x49,0x36}},
    {'C', {0x3E,0x41,0x41,0x41,0x22}}, {'D', {0x7F,0x41,0x41,0x22,0x1C}},
    {'E', {0x7F,0x49,0x49,0x49,0x41}}, {'F', {0x7F,0x09,0x09,0x09,0x01}},
    {'G', {0x3E,0x41,0x49,0x49,0x7A}}, {'H', {0x7F,0x08,0x08,0x08,0x7F}},
    {'I', {0x00,0x41,0x7F,0x41,0x00}}, {'J', {0x20,0x40,0x41,0x3F,0x01}},
    {'K', {0x7F,0x08,0x14,0x22,0x41}}, {'L', {0x7F,0x40,0x40,0x40,0x40}},
    {'M', {0x7F,0x02,0x0C,0x02,0x7F}}, {'N', {0x7F,0x04,0x08,0x10,0x7F}},
    {'O', {0x3E,0x41,0x41,0x41,0x3E}}, {'P', {0x7F,0x09,0x09,0x09,0x06}},
    {'Q', {0x3E,0x41,0x51,0x21,0x5E}}, {'R', {0x7F,0x09,0x19,0x29,0x46}},
    {'S', {0x46,0x49,0x49,0x49,0x31}}, {'T', {0x01,0x01,0x7F,0x01,0x01}},
    {'U', {0x3F,0x40,0x40,0x40,0x3F}}, {'V', {0x1F,0x20,0x40,0x20,0x1F}},
    {'W', {0x7F,0x20,0x18,0x20,0x7F}}, {'X', {0x63,0x14,0x08,0x14,0x63}},
    {'Y', {0x07,0x08,0x70,0x08,0x07}}, {'Z', {0x61,0x51,0x49,0x45,0x43}},
};

static const struct sd_glyph *sd_glyph_for(char c)
{
    if (c >= 'a' && c <= 'z') c = (char)(c - 'a' + 'A');
    for (size_t i = 0; i < sizeof(SD_FONT)/sizeof(SD_FONT[0]); i++)
        if (SD_FONT[i].c == c) return &SD_FONT[i];
    return NULL; /* -> hollow box */
}

/* --------------------------------------------------------------- canvas --- */

struct shell_canvas {
    uint32_t *px;        /* mmap'd ARGB8888 pixels */
    int bw, bh;          /* physical buffer dims (logical * scale) */
    int scale;           /* logical -> physical */
};

/* Allocate a fresh wl_shm buffer sized logical_w*logical_h*scale; fills *cv with
 * the mmap'd pixels. Returns the wl_buffer (attach it, destroy on release). */
static struct wl_buffer *sd_canvas_alloc(struct wl_shm *shm, int logical_w,
                                         int logical_h, int scale,
                                         struct shell_canvas *cv)
{
    int s = scale > 0 ? scale : 1;
    int bw = logical_w * s, bh = logical_h * s;
    int stride = bw * 4;
    size_t size = (size_t)stride * bh;
    int fd = sd_create_anon_fd(size);
    if (fd < 0) return NULL;
    uint32_t *px = mmap(NULL, size, PROT_READ|PROT_WRITE, MAP_SHARED, fd, 0);
    if (px == MAP_FAILED) { close(fd); return NULL; }
    struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, (int32_t)size);
    struct wl_buffer *buf = wl_shm_pool_create_buffer(pool, 0, bw, bh, stride,
                                                      WL_SHM_FORMAT_ARGB8888);
    wl_shm_pool_destroy(pool);
    close(fd);
    cv->px = px; cv->bw = bw; cv->bh = bh; cv->scale = s;
    return buf;
}

/* fill a logical rect with color (BGRA-in-memory). */
static void sd_fill_rect(struct shell_canvas *cv, int x, int y, int w, int h, uint32_t c)
{
    int s = cv->scale;
    int px0 = x*s, py0 = y*s, px1 = (x+w)*s, py1 = (y+h)*s;
    if (px0 < 0) px0 = 0; if (py0 < 0) py0 = 0;
    if (px1 > cv->bw) px1 = cv->bw; if (py1 > cv->bh) py1 = cv->bh;
    for (int yy = py0; yy < py1; yy++) {
        uint32_t *row = cv->px + (size_t)yy * cv->bw;
        for (int xx = px0; xx < px1; xx++) row[xx] = c;
    }
}

/* draw one glyph at logical (x,y) top-left, scaled. */
static void sd_draw_glyph(struct shell_canvas *cv, const struct sd_glyph *g,
                          int x, int y, uint32_t c)
{
    int s = cv->scale;
    if (!g) { sd_fill_rect(cv, x, y, 5, 7, c); return; }
    for (int col = 0; col < 5; col++) {
        uint8_t bits = g->col[col];
        for (int row = 0; row < 7; row++) {
            if (!(bits & (1u << row))) continue;
            int bx = (x+col)*s, by = (y+row)*s;
            for (int dy = 0; dy < s; dy++) {
                if (by+dy >= cv->bh) break;
                uint32_t *p = cv->px + (size_t)(by+dy) * cv->bw + bx;
                for (int dx = 0; dx < s; dx++)
                    if (bx+dx < cv->bw) p[dx] = c;
            }
        }
    }
}

/* draw a string; returns logical x advance. 6 logical px/char (5 + 1 gap). */
static int sd_draw_text(struct shell_canvas *cv, const char *str, int x, int y, uint32_t c)
{
    for (; *str; str++) { sd_draw_glyph(cv, sd_glyph_for(*str), x, y, c); x += 6; }
    return x;
}
static int sd_text_w(const char *s) { return (int)strlen(s) * 6; }

/* ellipsize src into dst so it fits maxchars (with a trailing '.'). */
static void sd_fit_label(char *dst, size_t dstsz, const char *src, int maxchars)
{
    int n = (int)strlen(src);
    if (maxchars < 2) maxchars = 2;
    if (n <= maxchars) { snprintf(dst, dstsz, "%s", src); return; }
    snprintf(dst, dstsz, "%.*s.", maxchars-1, src);
}

/* draw a string centered horizontally in [x0,x0+w] at logical y. */
static void sd_draw_text_centered(struct shell_canvas *cv, const char *s,
                                  int x0, int w, int y, uint32_t c)
{
    int tw = sd_text_w(s);
    int x = x0 + (w - tw) / 2;
    if (x < x0) x = x0;
    sd_draw_text(cv, s, x, y, c);
}

#endif /* SD_NO_DRAW — end of the legacy bitmap renderer */

/* ------------------------------------------------------- .desktop scan ---- */

#define SD_APPS_DIR "/var/jb/usr/share/applications"

struct sd_app { char name[64]; char exec[256]; char icon[128]; };

static void sd_strip_field_codes(char *exec)
{
    char *w = exec;
    for (char *r = exec; *r; r++) {
        if (r[0] == '%' && r[1]) { r++; continue; }
        *w++ = *r;
    }
    *w = 0;
    while (w > exec && w[-1] == ' ') *--w = 0;
}

/* scan SD_APPS_DIR for Type=Application, !NoDisplay entries; fill apps[], return count. */
static int sd_scan_apps(struct sd_app *apps, int max)
{
    DIR *d = opendir(SD_APPS_DIR);
    if (!d) return 0;
    int n = 0;
    struct dirent *e;
    while ((e = readdir(d)) && n < max) {
        size_t len = strlen(e->d_name);
        if (len < 9 || strcmp(e->d_name + len - 8, ".desktop")) continue;
        char path[512]; snprintf(path, sizeof path, "%s/%s", SD_APPS_DIR, e->d_name);
        FILE *f = fopen(path, "r"); if (!f) continue;
        char line[512], name[64] = {0}, exec[256] = {0}, icon[128] = {0};
        int nodisplay = 0, in_entry = 0;
        while (fgets(line, sizeof line, f)) {
            if (line[0] == '[') { in_entry = !strncmp(line, "[Desktop Entry]", 15); continue; }
            if (!in_entry) continue;
            if (!strncmp(line, "Name=", 5) && !name[0]) sscanf(line + 5, "%63[^\n]", name);
            else if (!strncmp(line, "Exec=", 5) && !exec[0]) sscanf(line + 5, "%255[^\n]", exec);
            else if (!strncmp(line, "Icon=", 5) && !icon[0]) sscanf(line + 5, "%127[^\n]", icon);
            else if (!strncmp(line, "NoDisplay=true", 14)) nodisplay = 1;
        }
        fclose(f);
        if (nodisplay || !exec[0]) continue;
        sd_strip_field_codes(exec);
        if (!name[0]) snprintf(name, sizeof name, "%.*s", (int)(len-8), e->d_name);
        snprintf(apps[n].name, 64, "%s", name);
        snprintf(apps[n].exec, 256, "%s", exec);
        snprintf(apps[n].icon, 128, "%s", icon);
        n++;
    }
    closedir(d);
    return n;
}

/* fork+exec a .desktop Exec under the same Wayland/dbus env run-kgx.sh proved
 * good. The shell clients run outside the iOS app sandbox (started by ioscd or a
 * run-script), so this is the direct path. */
static void sd_launch(const char *exec)
{
    pid_t pid = fork();
    if (pid != 0) return;
    setsid();
    setenv("WAYLAND_DISPLAY", "/var/jb/tmp/wayland-0", 1);
    setenv("XDG_RUNTIME_DIR", "/var/jb/tmp", 1);
    setenv("GDK_BACKEND", "wayland", 1);
    setenv("GSK_RENDERER", "cairo", 1);
    setenv("GSETTINGS_BACKEND", "memory", 1);
    setenv("GTK_A11Y", "none", 1);
    if (!getenv("HOME")) setenv("HOME", "/var/jb/var/root", 1);
    execl("/var/jb/usr/bin/dbus-run-session", "dbus-run-session", "--",
          "/bin/sh", "-lc", exec, (char*)NULL);
    execl("/bin/sh", "sh", "-lc", exec, (char*)NULL);
    _exit(127);
}

#endif /* SHELL_DRAW_H */

/*
 * ioscbg — the wallpaper client for the iosc desktop shell.
 *
 * A minimal zwlr_layer_shell_v1 client with two BACKGROUND-layer surfaces:
 * an inert wallpaper surface and a transparent desktop-items surface for pins,
 * widgets, and context menus. Wallpaper and widgets repaint independently.
 *
 * Wallpaper path: $IOSC_WALLPAPER, else the xios-desktop-theme default
 * <jbroot>/usr/share/backgrounds/xios/xios-default.jpg.
 *
 * It also owns the desktop widget layer: minimalist system cards (disk, RAM,
 * load, uptime) that live on the wallpaper, can be repositioned by long-press
 * drag, and persist their layout locally. Build: build-panel.sh. Needs iosc's
 * zwlr_layer_shell_v1.
 */
#define _GNU_SOURCE
#define SD_DESKTOP_PINS
#define SD_CAIRO
#include "shell-draw.h"
#include "shell-theme.h"
#include "panel-render.h"
#include "panel-icons.h"
#include "wlr-layer-shell-unstable-v1-client-protocol.h"

#include <poll.h>
#include <errno.h>
#include <signal.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <time.h>

#ifdef __APPLE__
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <ImageIO/ImageIO.h>
#include <mach/mach.h>
#endif

#define WIDGET_MAX       4
#define WIDGET_W         214
#define WIDGET_H         94
#define WIDGET_HOLD_MS   540
#define WIDGET_SLOP      10
#define PIN_MAX          64
#define PIN_W            92
#define PIN_H            110
#define PIN_ICON         62
#define PIN_CHECK_MS     1000
#define MENU_W           184
#define MENU_ROW_H       42
#define MENU_PAD         8
#define MENU_IDLE_MS     7000

enum bg_press_kind {
    BG_PRESS_NONE = 0,
    BG_PRESS_WIDGET = 1,
    BG_PRESS_PIN = 2,
};

enum bg_surface_kind {
    BG_SURF_WALL = 1,
    BG_SURF_DESK = 2,
};

struct bg_layer_ref {
    int kind;
};

static struct bg_layer_ref wall_ref = { BG_SURF_WALL };
static struct bg_layer_ref desk_ref = { BG_SURF_DESK };

enum bg_menu_action {
    MENU_ACT_NONE = 0,
    MENU_ACT_OPEN = 1,
    MENU_ACT_REMOVE_PIN = 2,
    MENU_ACT_HIDE_WIDGET = 3,
    MENU_ACT_REFRESH = 4,
    MENU_ACT_NEW_FOLDER = 5,
    MENU_ACT_OPEN_DOCUMENTS = 6,
    MENU_ACT_SET_WALLPAPER = 7,
    MENU_ACT_RESET_WALLPAPER = 8,
};

struct widget {
    const char *key;
    const char *title;
    char value[32];
    char detail[64];
    double frac;
    int x, y, w, h, visible;
};

struct desktop_pin {
    char type[16];       /* app | file */
    char name[64];
    char icon[128];
    char target[256];    /* app Exec or file path */
    int x, y, visible;
    cairo_surface_t *icon_surf;
};

static struct {
    struct wl_display    *dpy;
    struct wl_compositor *comp;
    struct wl_shm        *shm;
    struct wl_seat       *seat;
    struct wl_pointer    *ptr;
    struct wl_touch      *touch;
    struct wl_output     *output;
    struct zwlr_layer_shell_v1 *layer_shell;
    struct wl_surface    *wall_surf, *desk_surf;
    struct zwlr_layer_surface_v1 *wall_layer, *desk_layer;
    struct sd_cairo_pool wall_pool, desk_pool;
    int   width, height, scale, scale_env, running;
    int   wall_configured, desk_configured;
    uint32_t *base_pixels;             /* cached wallpaper/gradient at current physical size */
    size_t base_size;
    int   base_w, base_h, base_stride;
    struct widget widgets[WIDGET_MAX];
    struct desktop_pin pins[PIN_MAX];
    int   npins, pins_loaded, pin_drag_idx, pin_drag_dx, pin_drag_dy;
    time_t pins_mtime;
    off_t  pins_size;
    uint64_t last_pins_check_ms;
    int   widgets_loaded, edit_mode, drag_idx, drag_dx, drag_dy;
    int   menu_open, menu_x, menu_y, menu_kind, menu_idx;
    uint64_t menu_opened_ms;
    int   ptr_down, ptr_kind, ptr_idx, ptr_x, ptr_y, ptr_x0, ptr_y0, ptr_moved;
    int   touch_active, touch_id, touch_kind, touch_idx, touch_x, touch_y, touch_x0, touch_y0, touch_moved;
    uint64_t press_ms, last_stats_ms;
#ifdef __APPLE__
    CGImageRef image;
#endif
} B;

static void render_wallpaper(void);
static void render_desktop(void);
static void render_desktop_widgets(int mask);
static void rerender(void);
static void pin_clamp(struct desktop_pin *p);
static void pin_place_without_overlap(struct desktop_pin *p, int self_idx);
static int pins_resolve_collisions(void);
#ifdef __APPLE__
static CGImageRef load_wallpaper(const char *path);
#endif

static int abs_i(int v)
{
    return v < 0 ? -v : v;
}

static int moved_past_slop(int dx, int dy)
{
    return abs_i(dx) > WIDGET_SLOP || abs_i(dy) > WIDGET_SLOP;
}

static void base_cache_clear(void)
{
    free(B.base_pixels);
    B.base_pixels = NULL;
    B.base_size = 0;
    B.base_w = B.base_h = B.base_stride = 0;
}

static uint64_t now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000u + (uint64_t)ts.tv_nsec / 1000000u;
}

static void bg_config_path(char *out, size_t n)
{
    const char *env = getenv("IOSC_WIDGET_CONFIG");
    if (env && *env) { snprintf(out, n, "%s", env); return; }
    snprintf(out, n, "/var/mobile/Library/Preferences/com.max.iosc-widgets.conf");
}

static void wallpaper_config_path(char *out, size_t n)
{
    const char *env = getenv("IOSC_WALLPAPER_CONFIG");
    if (env && *env) { snprintf(out, n, "%s", env); return; }
    snprintf(out, n, "/var/mobile/Library/Preferences/com.max.iosc-wallpaper");
}

static void wallpaper_default_path(char *out, size_t n)
{
    sd_join_path(out, n, sd_jbroot(), "/usr/share/backgrounds/xios/xios-default.jpg");
}

static void wallpaper_current_path(char *out, size_t n)
{
    const char *wp = getenv("IOSC_WALLPAPER");
    if (wp && *wp) { snprintf(out, n, "%s", wp); return; }
    char cfg[256];
    wallpaper_config_path(cfg, sizeof cfg);
    FILE *f = fopen(cfg, "r");
    if (f) {
        if (fgets(out, (int)n, f)) {
            out[strcspn(out, "\r\n")] = 0;
            fclose(f);
            if (out[0]) return;
        } else fclose(f);
    }
    wallpaper_default_path(out, n);
}

static void widgets_default(void)
{
    B.widgets[0] = (struct widget){ "storage", "Storage", "", "", 0, 42, 92, WIDGET_W, WIDGET_H, 1 };
    B.widgets[1] = (struct widget){ "memory",  "Memory",  "", "", 0, 42, 202, WIDGET_W, WIDGET_H, 1 };
    B.widgets[2] = (struct widget){ "load",    "Load",    "", "", 0, 42, 312, WIDGET_W, WIDGET_H, 1 };
    B.widgets[3] = (struct widget){ "uptime",  "Session", "", "", 0, 42, 422, WIDGET_W, WIDGET_H, 1 };
}

static void widgets_load(void)
{
    widgets_default();
    char path[256]; bg_config_path(path, sizeof path);
    FILE *f = fopen(path, "r");
    if (!f) { B.widgets_loaded = 1; return; }
    char key[32]; int x, y, vis;
    while (fscanf(f, "%31s %d %d %d", key, &x, &y, &vis) == 4) {
        for (int i = 0; i < WIDGET_MAX; i++) if (!strcmp(B.widgets[i].key, key)) {
            B.widgets[i].x = x; B.widgets[i].y = y; B.widgets[i].visible = !!vis;
        }
    }
    fclose(f);
    B.widgets_loaded = 1;
}

static void widgets_save(void)
{
    char path[256]; bg_config_path(path, sizeof path);
    FILE *f = fopen(path, "w");
    if (!f) return;
    for (int i = 0; i < WIDGET_MAX; i++)
        fprintf(f, "%s %d %d %d\n", B.widgets[i].key, B.widgets[i].x, B.widgets[i].y, B.widgets[i].visible);
    fclose(f);
}

static void pin_destroy(struct desktop_pin *p)
{
    if (p->icon_surf) cairo_surface_destroy(p->icon_surf);
    memset(p, 0, sizeof *p);
}

static void pins_save(void)
{
    char path[256]; sd_desktop_pins_path(path, sizeof path);
    FILE *f = fopen(path, "w");
    if (!f) return;
    for (int i = 0; i < B.npins; i++) {
        struct desktop_pin *p = &B.pins[i];
        if (!p->visible) continue;
        fprintf(f, "%s\t%s\t%s\t%s\t%d\t%d\n",
                p->type[0] ? p->type : "app", p->name, p->icon, p->target, p->x, p->y);
    }
    fclose(f);
}

static void pin_load_icon(struct desktop_pin *p)
{
    if (p->icon_surf) { cairo_surface_destroy(p->icon_surf); p->icon_surf = NULL; }
    char path[512];
    const char *name = p->icon[0] ? p->icon : p->name;
    if (pi_resolve(name, B.scale, path, sizeof path))
        p->icon_surf = pr_icon_load(path);
}

static int is_image_path(const char *path)
{
    const char *dot = path ? strrchr(path, '.') : NULL;
    if (!dot) return 0;
    return !strcasecmp(dot, ".jpg") || !strcasecmp(dot, ".jpeg") ||
           !strcasecmp(dot, ".png") || !strcasecmp(dot, ".heic") ||
           !strcasecmp(dot, ".tif") || !strcasecmp(dot, ".tiff");
}

static void pin_add_file(const char *name, const char *target, const char *icon, int x, int y)
{
    if (!name || !*name || !target || !*target || B.npins >= PIN_MAX) return;
    for (int i = 0; i < B.npins; i++)
        if (!strcmp(B.pins[i].type, "file") && !strcmp(B.pins[i].target, target))
            return;
    struct desktop_pin *p = &B.pins[B.npins++];
    snprintf(p->type, sizeof p->type, "file");
    snprintf(p->name, sizeof p->name, "%s", name);
    snprintf(p->icon, sizeof p->icon, "%s", icon && *icon ? icon : "folder");
    snprintf(p->target, sizeof p->target, "%s", target);
    p->x = x; p->y = y; p->visible = 1;
    pin_clamp(p);
    pin_place_without_overlap(p, B.npins - 1);
    pin_load_icon(p);
    pins_save();
}

static void pins_load(void)
{
    for (int i = 0; i < B.npins; i++) pin_destroy(&B.pins[i]);
    B.npins = 0;
    char path[256]; sd_desktop_pins_path(path, sizeof path);
    struct stat st;
    if (stat(path, &st) == 0) {
        B.pins_mtime = st.st_mtime;
        B.pins_size = st.st_size;
    } else {
        B.pins_mtime = 0;
        B.pins_size = 0;
    }
    FILE *f = fopen(path, "r");
    if (!f) { B.pins_loaded = 1; return; }
    char line[768];
    while (fgets(line, sizeof line, f) && B.npins < PIN_MAX) {
        char *save = NULL;
        char *type = strtok_r(line, "\t\r\n", &save);
        char *name = strtok_r(NULL, "\t\r\n", &save);
        char *icon = strtok_r(NULL, "\t\r\n", &save);
        char *target = strtok_r(NULL, "\t\r\n", &save);
        char *xs = strtok_r(NULL, "\t\r\n", &save);
        char *ys = strtok_r(NULL, "\t\r\n", &save);
        if (!type || !name || !target || !xs || !ys) continue;
        struct desktop_pin *p = &B.pins[B.npins++];
        snprintf(p->type, sizeof p->type, "%s", type);
        snprintf(p->name, sizeof p->name, "%s", name);
        snprintf(p->icon, sizeof p->icon, "%s", icon ? icon : "");
        snprintf(p->target, sizeof p->target, "%s", target);
        p->x = atoi(xs); p->y = atoi(ys); p->visible = 1;
        pin_clamp(p);
        pin_load_icon(p);
    }
    fclose(f);
    if (pins_resolve_collisions()) pins_save();
    B.pins_loaded = 1;
}

static int pins_reload_if_changed(void)
{
    B.last_pins_check_ms = now_ms();
    char path[256]; sd_desktop_pins_path(path, sizeof path);
    struct stat st;
    time_t mt = 0;
    off_t sz = 0;
    if (stat(path, &st) == 0) {
        mt = st.st_mtime;
        sz = st.st_size;
    }
    int changed = !B.pins_loaded || mt != B.pins_mtime || sz != B.pins_size;
    if (changed) pins_load();
    return changed;
}

static int pins_reload_if_due(uint64_t now)
{
    if (B.pins_loaded && now - B.last_pins_check_ms < PIN_CHECK_MS)
        return 0;
    return pins_reload_if_changed();
}

static void fmt_bytes(char *out, size_t n, uint64_t bytes)
{
    const char *u[] = { "B", "KB", "MB", "GB", "TB" };
    double v = (double)bytes;
    int i = 0;
    while (i < 4 && v >= 1024.0) { v /= 1024.0; i++; }
    snprintf(out, n, i == 0 ? "%.0f %s" : "%.1f %s", v, u[i]);
}

static int widgets_update_stats(void)
{
    char old_value[WIDGET_MAX][32];
    char old_detail[WIDGET_MAX][64];
    double old_frac[WIDGET_MAX];
    int changed = 0;
    for (int i = 0; i < WIDGET_MAX; i++) {
        memcpy(old_value[i], B.widgets[i].value, sizeof old_value[i]);
        memcpy(old_detail[i], B.widgets[i].detail, sizeof old_detail[i]);
        old_frac[i] = B.widgets[i].frac;
    }

    size_t sz;
    char root[256];
    snprintf(root, sizeof root, "%s", sd_jbroot());
    struct statfs fs;
    if (statfs(root[0] ? root : "/", &fs) == 0 && fs.f_blocks > 0) {
        uint64_t total = (uint64_t)fs.f_blocks * (uint64_t)fs.f_bsize;
        uint64_t freeb = (uint64_t)fs.f_bavail * (uint64_t)fs.f_bsize;
        uint64_t used = total > freeb ? total - freeb : 0;
        char used_s[24], total_s[24];
        fmt_bytes(used_s, sizeof used_s, used);
        fmt_bytes(total_s, sizeof total_s, total);
        snprintf(B.widgets[0].value, sizeof B.widgets[0].value, "%d%%", total ? (int)(used * 100 / total) : 0);
        snprintf(B.widgets[0].detail, sizeof B.widgets[0].detail, "%s of %s used", used_s, total_s);
        B.widgets[0].frac = total ? (double)used / (double)total : 0;
    }

#ifdef __APPLE__
    uint64_t mem_total = 0;
    sz = sizeof mem_total;
    if (sysctlbyname("hw.memsize", &mem_total, &sz, NULL, 0) == 0 && mem_total > 0) {
        vm_statistics64_data_t vm;
        mach_msg_type_number_t cnt = HOST_VM_INFO64_COUNT;
        uint64_t used = 0;
        if (host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&vm, &cnt) == KERN_SUCCESS) {
            uint64_t ps = (uint64_t)sysconf(_SC_PAGESIZE);
            used = (uint64_t)(vm.active_count + vm.wire_count + vm.compressor_page_count) * ps;
        }
        char used_s[24], total_s[24];
        fmt_bytes(used_s, sizeof used_s, used);
        fmt_bytes(total_s, sizeof total_s, mem_total);
        snprintf(B.widgets[1].value, sizeof B.widgets[1].value, "%d%%",
                 used ? (int)(used * 100 / mem_total) : 0);
        snprintf(B.widgets[1].detail, sizeof B.widgets[1].detail, "%s of %s active", used_s, total_s);
        B.widgets[1].frac = used ? (double)used / (double)mem_total : 0;
    }
#else
    snprintf(B.widgets[1].value, sizeof B.widgets[1].value, "--");
    snprintf(B.widgets[1].detail, sizeof B.widgets[1].detail, "Unavailable off device");
    B.widgets[1].frac = 0;
#endif

    double la[3] = {0,0,0};
    if (getloadavg(la, 3) > 0) {
        snprintf(B.widgets[2].value, sizeof B.widgets[2].value, "%.2f", la[0]);
        snprintf(B.widgets[2].detail, sizeof B.widgets[2].detail, "1m %.2f  5m %.2f  15m %.2f", la[0], la[1], la[2]);
        B.widgets[2].frac = la[0] / 4.0;
        if (B.widgets[2].frac > 1) B.widgets[2].frac = 1;
    }

    struct timeval boottime; sz = sizeof boottime;
    if (sysctlbyname("kern.boottime", &boottime, &sz, NULL, 0) == 0) {
        time_t up = time(NULL) - boottime.tv_sec;
        int h = (int)(up / 3600), m = (int)((up % 3600) / 60);
        if (h >= 24) snprintf(B.widgets[3].value, sizeof B.widgets[3].value, "%dd", h / 24);
        else snprintf(B.widgets[3].value, sizeof B.widgets[3].value, "%dh %02dm", h, m);
        snprintf(B.widgets[3].detail, sizeof B.widgets[3].detail, "System uptime");
        B.widgets[3].frac = (double)(up % 86400) / 86400.0;
    }
    B.last_stats_ms = now_ms();
    for (int i = 0; i < WIDGET_MAX; i++) {
        if (memcmp(old_value[i], B.widgets[i].value, sizeof old_value[i]) ||
            memcmp(old_detail[i], B.widgets[i].detail, sizeof old_detail[i]) ||
            old_frac[i] != B.widgets[i].frac)
            changed |= 1 << i;
    }
    return changed;
}

static int widget_hit(int x, int y)
{
    for (int i = WIDGET_MAX - 1; i >= 0; i--) {
        struct widget *w = &B.widgets[i];
        if (!w->visible) continue;
        if (x >= w->x && x < w->x + w->w && y >= w->y && y < w->y + w->h) return i;
    }
    return -1;
}

static int pin_hit(int x, int y)
{
    for (int i = B.npins - 1; i >= 0; i--) {
        struct desktop_pin *p = &B.pins[i];
        if (!p->visible) continue;
        if (x >= p->x && x < p->x + PIN_W && y >= p->y && y < p->y + PIN_H) return i;
    }
    return -1;
}

static void press_hit_at(int x, int y, int *kind, int *idx)
{
    *idx = pin_hit(x, y);
    if (*idx >= 0) {
        *kind = BG_PRESS_PIN;
        return;
    }

    *idx = widget_hit(x, y);
    *kind = *idx >= 0 ? BG_PRESS_WIDGET : BG_PRESS_NONE;
}

static void widget_clamp(struct widget *w)
{
    if (w->x < 8) w->x = 8;
    if (w->y < 48) w->y = 48;
    if (B.width > 0 && w->x + w->w > B.width - 8) w->x = B.width - 8 - w->w;
    if (B.height > 0 && w->y + w->h > B.height - 8) w->y = B.height - 8 - w->h;
}

static void pin_clamp(struct desktop_pin *p)
{
    if (p->x < 8) p->x = 8;
    if (p->y < 48) p->y = 48;
    if (B.width > 0 && p->x + PIN_W > B.width - 8) p->x = B.width - 8 - PIN_W;
    if (B.height > 0 && p->y + PIN_H > B.height - 8) p->y = B.height - 8 - PIN_H;
}

static int pin_rects_overlap(int ax, int ay, int bx, int by)
{
    const int gap = 8;
    return ax < bx + PIN_W + gap && ax + PIN_W + gap > bx &&
           ay < by + PIN_H + gap && ay + PIN_H + gap > by;
}

static int pin_position_occupied(int self_idx, int x, int y)
{
    for (int i = 0; i < B.npins; i++) {
        if (i >= self_idx || !B.pins[i].visible) continue;
        if (pin_rects_overlap(x, y, B.pins[i].x, B.pins[i].y)) return 1;
    }
    return 0;
}

static int pin_grid_cols(void)
{
    const int step_x = PIN_W + 16;
    int usable = B.width > 0 ? B.width - 16 : 1424;
    int cols = usable / step_x;
    return cols > 0 ? cols : 1;
}

static int pin_grid_rows(void)
{
    const int step_y = PIN_H + 14;
    int usable = B.height > 0 ? B.height - 56 : 1024;
    int rows = usable / step_y;
    return rows > 0 ? rows : 1;
}

static void pin_slot_xy(int slot, int *x, int *y)
{
    const int step_x = PIN_W + 16;
    const int step_y = PIN_H + 14;
    int cols = pin_grid_cols();
    *x = 8 + (slot % cols) * step_x;
    *y = 48 + (slot / cols) * step_y;
}

static void pin_place_without_overlap(struct desktop_pin *p, int self_idx)
{
    pin_clamp(p);
    if (!pin_position_occupied(self_idx, p->x, p->y)) return;

    int cols = pin_grid_cols();
    int rows = pin_grid_rows();
    int slots = cols * rows;
    int step_x = PIN_W + 16;
    int step_y = PIN_H + 14;
    int col = (p->x - 8 + step_x / 2) / step_x;
    int row = (p->y - 48 + step_y / 2) / step_y;
    if (col < 0) col = 0;
    if (row < 0) row = 0;
    int start = (row * cols + col) % (slots > 0 ? slots : 1);

    for (int n = 0; n < slots; n++) {
        int x, y;
        pin_slot_xy((start + n) % slots, &x, &y);
        if (!pin_position_occupied(self_idx, x, y)) {
            p->x = x;
            p->y = y;
            pin_clamp(p);
            return;
        }
    }
}

static int pins_resolve_collisions(void)
{
    int changed = 0;
    for (int i = 0; i < B.npins; i++) {
        struct desktop_pin *p = &B.pins[i];
        if (!p->visible) continue;
        int old_x = p->x, old_y = p->y;
        pin_place_without_overlap(p, i);
        if (p->x != old_x || p->y != old_y) changed = 1;
    }
    return changed;
}

static void quote_sh(char *out, size_t n, const char *s)
{
    size_t w = 0;
    if (w + 1 < n) out[w++] = '\'';
    for (const char *p = s; *p && w + 5 < n; p++) {
        if (*p == '\'') {
            memcpy(out + w, "'\\''", 4);
            w += 4;
        } else out[w++] = *p;
    }
    if (w + 1 < n) out[w++] = '\'';
    out[w < n ? w : n - 1] = 0;
}

static void pin_launch(int idx)
{
    if (idx < 0 || idx >= B.npins) return;
    struct desktop_pin *p = &B.pins[idx];
    if (!strcmp(p->type, "file")) {
        char q[320], cmd[384];
        quote_sh(q, sizeof q, p->target);
        snprintf(cmd, sizeof cmd, "xdg-open %s", q);
        sd_launch(cmd);
    } else {
        sd_launch(p->target);
    }
}

static int menu_actions(int kind, int idx, const char **labels, int *actions)
{
    int n = 0;
    if (kind == BG_PRESS_PIN && idx >= 0 && idx < B.npins) {
        labels[n] = "Open"; actions[n++] = MENU_ACT_OPEN;
        if (!strcmp(B.pins[idx].type, "file") && is_image_path(B.pins[idx].target)) {
            labels[n] = "Set as Wallpaper"; actions[n++] = MENU_ACT_SET_WALLPAPER;
        }
        labels[n] = "Remove from Desktop"; actions[n++] = MENU_ACT_REMOVE_PIN;
        labels[n] = "Refresh Desktop"; actions[n++] = MENU_ACT_REFRESH;
    } else if (kind == BG_PRESS_WIDGET && idx >= 0 && idx < WIDGET_MAX) {
        labels[n] = "Hide Widget"; actions[n++] = MENU_ACT_HIDE_WIDGET;
        labels[n] = "Refresh Desktop"; actions[n++] = MENU_ACT_REFRESH;
    } else if (kind == BG_PRESS_NONE) {
        labels[n] = "New Folder"; actions[n++] = MENU_ACT_NEW_FOLDER;
        labels[n] = "Open Documents"; actions[n++] = MENU_ACT_OPEN_DOCUMENTS;
        labels[n] = "Reset Wallpaper"; actions[n++] = MENU_ACT_RESET_WALLPAPER;
        labels[n] = "Refresh Desktop"; actions[n++] = MENU_ACT_REFRESH;
    }
    return n;
}

static int menu_height_for(int kind, int idx)
{
    const char *labels[4]; int actions[4];
    return MENU_PAD * 2 + menu_actions(kind, idx, labels, actions) * MENU_ROW_H;
}

static void menu_open_at(int kind, int idx, int x, int y)
{
    int h;
    const char *labels[4]; int actions[4];
    if (menu_actions(kind, idx, labels, actions) <= 0) return;
    B.menu_open = 1;
    B.menu_kind = kind;
    B.menu_idx = idx;
    B.menu_opened_ms = now_ms();
    h = menu_height_for(kind, idx);
    B.menu_x = x;
    B.menu_y = y;
    if (B.menu_x + MENU_W > B.width - 8) B.menu_x = B.width - 8 - MENU_W;
    if (B.menu_y + h > B.height - 8) B.menu_y = B.height - 8 - h;
    if (B.menu_x < 8) B.menu_x = 8;
    if (B.menu_y < 48) B.menu_y = 48;
}

static int menu_hit(int x, int y)
{
    if (!B.menu_open) return MENU_ACT_NONE;
    const char *labels[4]; int actions[4];
    int n = menu_actions(B.menu_kind, B.menu_idx, labels, actions);
    int h = MENU_PAD * 2 + n * MENU_ROW_H;
    if (x < B.menu_x || x >= B.menu_x + MENU_W || y < B.menu_y || y >= B.menu_y + h)
        return MENU_ACT_NONE;
    int row = (y - B.menu_y - MENU_PAD) / MENU_ROW_H;
    if (row < 0 || row >= n) return MENU_ACT_NONE;
    return actions[row];
}

static int menu_dismiss_if_idle(uint64_t now)
{
    if (!B.menu_open) return 0;
    if (now - B.menu_opened_ms < MENU_IDLE_MS) return 0;
    B.menu_open = 0;
    return 1;
}

static void menu_remove_pin(int idx)
{
    if (idx < 0 || idx >= B.npins) return;
    pin_destroy(&B.pins[idx]);
    for (int i = idx; i < B.npins - 1; i++) B.pins[i] = B.pins[i + 1];
    B.npins--;
    memset(&B.pins[B.npins], 0, sizeof B.pins[B.npins]);
    pins_save();
}

static void reload_wallpaper_image(void)
{
#ifdef __APPLE__
    if (B.image) { CGImageRelease(B.image); B.image = NULL; }
    char wp[512];
    wallpaper_current_path(wp, sizeof wp);
    B.image = load_wallpaper(wp);
#endif
    base_cache_clear();
    render_wallpaper();
}

static void menu_set_wallpaper_from_pin(int idx)
{
    if (idx < 0 || idx >= B.npins) return;
    struct desktop_pin *p = &B.pins[idx];
    if (strcmp(p->type, "file") || !is_image_path(p->target)) return;
    char cfg[256];
    wallpaper_config_path(cfg, sizeof cfg);
    FILE *f = fopen(cfg, "w");
    if (!f) return;
    fprintf(f, "%s\n", p->target);
    fclose(f);
    reload_wallpaper_image();
}

static void menu_reset_wallpaper(void)
{
    char cfg[256];
    wallpaper_config_path(cfg, sizeof cfg);
    unlink(cfg);
    reload_wallpaper_image();
}

static void menu_new_folder(void)
{
    char docs[256], path[320], name[96];
    sd_join_path(docs, sizeof docs, sd_jbroot(), "/var/mobile/Documents");
    mkdir(docs, 0755);
    for (int i = 0; i < 100; i++) {
        snprintf(name, sizeof name, i == 0 ? "Untitled Folder" : "Untitled Folder %d", i + 1);
        snprintf(path, sizeof path, "%s/%s", docs, name);
        if (mkdir(path, 0755) == 0) {
            pin_add_file(name, path, "folder", B.menu_x, B.menu_y);
            return;
        }
        if (errno != EEXIST) return;
    }
}

static void menu_act(int action)
{
    int kind = B.menu_kind, idx = B.menu_idx;
    B.menu_open = 0;
    switch (action) {
    case MENU_ACT_OPEN:
        if (kind == BG_PRESS_PIN) pin_launch(idx);
        break;
    case MENU_ACT_REMOVE_PIN:
        if (kind == BG_PRESS_PIN) menu_remove_pin(idx);
        break;
    case MENU_ACT_HIDE_WIDGET:
        if (kind == BG_PRESS_WIDGET && idx >= 0 && idx < WIDGET_MAX) {
            B.widgets[idx].visible = 0;
            widgets_save();
        }
        break;
    case MENU_ACT_REFRESH:
        B.pins_loaded = 0;
        widgets_update_stats();
        break;
    case MENU_ACT_NEW_FOLDER:
        menu_new_folder();
        break;
    case MENU_ACT_OPEN_DOCUMENTS:
        sd_launch("xdg-open /var/mobile/Documents");
        break;
    case MENU_ACT_SET_WALLPAPER:
        if (kind == BG_PRESS_PIN) menu_set_wallpaper_from_pin(idx);
        break;
    case MENU_ACT_RESET_WALLPAPER:
        menu_reset_wallpaper();
        break;
    }
    rerender();
}

static void menu_draw(cairo_t *cr)
{
    if (!B.menu_open) return;
    const char *labels[4]; int actions[4];
    int n = menu_actions(B.menu_kind, B.menu_idx, labels, actions);
    int h = MENU_PAD * 2 + n * MENU_ROW_H;
    (void)actions;
    pr_text_ctx t = pr_text_ctx_new(cr);
    pr_fill_rrect(cr, B.menu_x + 1, B.menu_y + 6, MENU_W, h, 18, 0x38000000u);
    pr_fill_rrect(cr, B.menu_x, B.menu_y, MENU_W, h, 18, TH_CARD);
    pr_stroke_rrect(cr, B.menu_x, B.menu_y, MENU_W, h, 18, TH_BORDER, 1.0);
    for (int i = 0; i < n; i++) {
        int y = B.menu_y + MENU_PAD + i * MENU_ROW_H;
        if (i > 0) pr_fill_rect(cr, B.menu_x + 14, y, MENU_W - 28, 1, TH_SEP);
        pr_text(cr, &t, TH_FONT_STATUS, labels[i], B.menu_x + 16,
                y + MENU_ROW_H / 2, TH_FG, MENU_W - 32);
    }
    pr_text_ctx_free(&t);
}

static void pins_draw(cairo_t *cr)
{
    pr_text_ctx t = pr_text_ctx_new(cr);
    for (int i = 0; i < B.npins; i++) {
        struct desktop_pin *p = &B.pins[i];
        if (!p->visible) continue;
        pin_clamp(p);
        int hot = i == B.pin_drag_idx;
        if (hot)
            pr_fill_rrect(cr, p->x, p->y, PIN_W, PIN_H, 18, 0x33FFFFFFu);
        int ix = p->x + (PIN_W - PIN_ICON) / 2;
        int iy = p->y + 8;
        if (p->icon_surf)
            pr_draw_icon(cr, p->icon_surf, ix, iy, PIN_ICON, 0);
        else
            pr_draw_monogram(cr, &t, p->name, ix, iy, PIN_ICON, 16, TH_TILE, TH_FG, TH_FONT_TITLE);
        pr_text_centered(cr, &t, TH_FONT_WIDGET_DETAIL, p->name,
                         p->x + 4, PIN_W - 8, p->y + PIN_ICON + 28, TH_FG);
        if (hot)
            pr_stroke_rrect(cr, p->x + 2, p->y + 2, PIN_W - 4, PIN_H - 4, 16, TH_ACCENT, 1.5);
    }
    pr_text_ctx_free(&t);
}

static void widgets_draw(cairo_t *cr)
{
    pr_text_ctx t = pr_text_ctx_new(cr);
    for (int i = 0; i < WIDGET_MAX; i++) {
        struct widget *w = &B.widgets[i];
        if (!w->visible) continue;
        widget_clamp(w);
        int hot = (B.edit_mode && i == B.drag_idx);
        pr_fill_rrect(cr, w->x + 0, w->y + 7, w->w, w->h, 22, 0x30000000u);
        pr_fill_rrect(cr, w->x, w->y, w->w, w->h, 22, hot ? 0xB8222328u : 0xA8191A1Fu);
        pr_stroke_rrect(cr, w->x, w->y, w->w, w->h, 22, hot ? TH_ACCENT : 0x36FFFFFFu, hot ? 1.8 : 1.0);
        pr_text(cr, &t, TH_FONT_WIDGET_LABEL, w->title, w->x + 16, w->y + 18, TH_FG_DIM, w->w - 32);
        pr_text(cr, &t, TH_FONT_WIDGET_VALUE, w->value, w->x + 16, w->y + 46, TH_FG, w->w - 32);
        pr_text(cr, &t, TH_FONT_WIDGET_DETAIL, w->detail, w->x + 16, w->y + 68, 0xCCFFFFFFu, w->w - 32);
        double barw = w->w - 36;
        pr_fill_rrect(cr, w->x + 18, w->y + w->h - 16, barw, 5, 2.5, 0x33FFFFFFu);
        double frac = w->frac;
        if (frac < 0) frac = 0; if (frac > 1) frac = 1;
        pr_fill_rrect(cr, w->x + 18, w->y + w->h - 16, barw * frac, 5, 2.5,
                      frac > 0.85 ? 0xFFFF453Au : TH_ACCENT);
        if (B.edit_mode) {
            pr_fill_rrect(cr, w->x + w->w - 42, w->y + 14, 22, 4, 2, 0x70FFFFFFu);
            pr_fill_rrect(cr, w->x + w->w - 42, w->y + 24, 22, 4, 2, 0x55FFFFFFu);
        }
    }
    pr_text_ctx_free(&t);
}

/* ------------------------------------------------------------ decoding --- */

#ifdef __APPLE__
static CGImageRef load_wallpaper(const char *path)
{
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(
        NULL, (const UInt8 *)path, (CFIndex)strlen(path), false);
    if (!url) return NULL;
    CGImageSourceRef src = CGImageSourceCreateWithURL(url, NULL);
    CFRelease(url);
    if (!src) return NULL;
    CGImageRef img = CGImageSourceCreateImageAtIndex(src, 0, NULL);
    CFRelease(src);
    return img;
}
#endif

/* ------------------------------------------------------------ rendering -- */

/* Fallback: the theme gradient (TH_WALL_TOP -> TH_WALL_BOT), straight into
 * BGRA pixels — no drawing library needed for two color stops. */
static void fill_gradient(uint32_t *px, int w, int h)
{
    uint32_t top = TH_WALL_TOP, bot = TH_WALL_BOT;
    int r0 = (top >> 16) & 0xff, g0 = (top >> 8) & 0xff, b0 = top & 0xff;
    int r1 = (bot >> 16) & 0xff, g1 = (bot >> 8) & 0xff, b1 = bot & 0xff;
    for (int y = 0; y < h; y++) {
        double t = h > 1 ? (double)y / (h - 1) : 0;
        uint32_t c = 0xff000000u
                   | ((uint32_t)(r0 + (r1 - r0) * t) << 16)
                   | ((uint32_t)(g0 + (g1 - g0) * t) << 8)
                   |  (uint32_t)(b0 + (b1 - b0) * t);
        uint32_t *row = px + (size_t)y * w;
        for (int x = 0; x < w; x++) row[x] = c;
    }
}

static void paint_base(uint32_t *map, int bw, int bh, int stride)
{
    int painted = 0;
#ifdef __APPLE__
    if (B.image) {
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGContextRef ctx = CGBitmapContextCreate(map, (size_t)bw, (size_t)bh, 8,
                               (size_t)stride, cs,
                               kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
        CGColorSpaceRelease(cs);
        if (ctx) {
            size_t iw = CGImageGetWidth(B.image), ih = CGImageGetHeight(B.image);
            if (iw && ih) {
                double k = (double)bw / iw > (double)bh / ih
                         ? (double)bw / iw : (double)bh / ih;
                double dw = iw * k, dh = ih * k;
                CGRect rect = CGRectMake((bw - dw) / 2.0, (bh - dh) / 2.0, dw, dh);
                CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
                CGContextDrawImage(ctx, rect, B.image);
                painted = 1;
            }
            CGContextRelease(ctx);
        }
    }
#endif
    if (!painted) fill_gradient(map, bw, bh);
}

static int ensure_base_cache(int bw, int bh, int stride)
{
    size_t size = (size_t)stride * (size_t)bh;
    if (B.base_pixels && B.base_w == bw && B.base_h == bh &&
        B.base_stride == stride && B.base_size == size)
        return 1;

    base_cache_clear();
    B.base_pixels = malloc(size);
    if (!B.base_pixels) return 0;
    B.base_size = size;
    B.base_w = bw;
    B.base_h = bh;
    B.base_stride = stride;
    paint_base(B.base_pixels, bw, bh, stride);
    return 1;
}

static void render_wallpaper(void)
{
    if (!B.wall_configured) return;
    int s = B.scale, bw = B.width * s, bh = B.height * s;
    cairo_t *cr; cairo_surface_t *surf;
    struct sd_cairo_slot *slot = sd_cairo_pool_begin(&B.wall_pool, B.shm,
                                                     B.width, B.height, B.scale,
                                                     &cr, &surf);
    struct wl_buffer *buf = slot ? slot->buffer : NULL;
    if (!buf) return;
    int stride = cairo_image_surface_get_stride(surf);
    size_t size = (size_t)stride * (size_t)bh;
    uint32_t *map = (uint32_t *)cairo_image_surface_get_data(surf);

    if (ensure_base_cache(bw, bh, stride))
        memcpy(map, B.base_pixels, size);
    else
        paint_base(map, bw, bh, stride);

    cairo_surface_flush(surf);
    cairo_destroy(cr);
    cairo_surface_destroy(surf);
    wl_surface_set_buffer_scale(B.wall_surf, B.scale);
    wl_surface_attach(B.wall_surf, buf, 0, 0);
    wl_surface_damage_buffer(B.wall_surf, 0, 0, bw, bh);
    wl_surface_commit(B.wall_surf);
}

static void render_desktop_region(int dx, int dy, int dw, int dh, int partial, int poll_stats)
{
    if (!B.desk_configured) return;
    if (!B.widgets_loaded) widgets_load();
    uint64_t now = now_ms();
    pins_reload_if_due(now);
    if (poll_stats && now - B.last_stats_ms > 2500) widgets_update_stats();

    int s = B.scale, bw = B.width * s, bh = B.height * s;
    cairo_t *cr; cairo_surface_t *cs;
    struct sd_cairo_slot *slot = sd_cairo_pool_begin(&B.desk_pool, B.shm,
                                                     B.width, B.height, B.scale,
                                                     &cr, &cs);
    struct wl_buffer *buf = slot ? slot->buffer : NULL;
    if (!buf) return;
    int stride = cairo_image_surface_get_stride(cs);
    size_t size = (size_t)stride * (size_t)bh;
    uint32_t *map = (uint32_t *)cairo_image_surface_get_data(cs);
    memset(map, 0, size);

    (void)s;
    pins_draw(cr);
    widgets_draw(cr);
    menu_draw(cr);
    cairo_surface_flush(cs);
    cairo_destroy(cr);
    cairo_surface_destroy(cs);

    wl_surface_set_buffer_scale(B.desk_surf, B.scale);
    wl_surface_attach(B.desk_surf, buf, 0, 0);
    if (partial) {
        if (dx < 0) { dw += dx; dx = 0; }
        if (dy < 0) { dh += dy; dy = 0; }
        if (dx + dw > B.width) dw = B.width - dx;
        if (dy + dh > B.height) dh = B.height - dy;
    }
    if (partial && dw > 0 && dh > 0)
        wl_surface_damage_buffer(B.desk_surf, dx * s, dy * s, dw * s, dh * s);
    else
        wl_surface_damage_buffer(B.desk_surf, 0, 0, bw, bh);
    wl_surface_commit(B.desk_surf);
}

static void render_desktop(void)
{
    render_desktop_region(0, 0, 0, 0, 0, 1);
}

static void include_widget_damage(int *x0, int *y0, int *x1, int *y1,
                                  const struct widget *w)
{
    const int pad = 12;
    int wx0 = w->x - pad, wy0 = w->y - pad;
    int wx1 = w->x + w->w + pad, wy1 = w->y + w->h + pad;
    if (wx0 < *x0) *x0 = wx0;
    if (wy0 < *y0) *y0 = wy0;
    if (wx1 > *x1) *x1 = wx1;
    if (wy1 > *y1) *y1 = wy1;
}

static void render_desktop_widgets(int mask)
{
    int x0 = B.width, y0 = B.height, x1 = 0, y1 = 0;
    for (int i = 0; i < WIDGET_MAX; i++) {
        if (!(mask & (1 << i)) || !B.widgets[i].visible) continue;
        include_widget_damage(&x0, &y0, &x1, &y1, &B.widgets[i]);
    }
    if (x1 <= x0 || y1 <= y0) return;
    render_desktop_region(x0, y0, x1 - x0, y1 - y0, 1, 0);
}

static void render(void)
{
    render_wallpaper();
    render_desktop();
}

static void rerender(void)
{
    render_desktop();
}

/* ------------------------------------------------------- layer surface --- */

static void layer_configure(void *d, struct zwlr_layer_surface_v1 *ls, uint32_t serial, uint32_t w, uint32_t h)
{
    struct bg_layer_ref *ref = d;
    int old_w = B.width, old_h = B.height;
    if (w) B.width = (int)w;
    if (h) B.height = (int)h;
    zwlr_layer_surface_v1_ack_configure(ls, serial);
    if (ref && ref->kind == BG_SURF_WALL)
        B.wall_configured = 1;
    else if (ref && ref->kind == BG_SURF_DESK)
        B.desk_configured = 1;

    if (old_w != B.width || old_h != B.height) {
        render();
    } else if (ref && ref->kind == BG_SURF_WALL) {
        render_wallpaper();
    } else {
        render_desktop();
    }
}
static void layer_closed(void *d, struct zwlr_layer_surface_v1 *ls){ (void)d;(void)ls; B.running = 0; }
static const struct zwlr_layer_surface_v1_listener layer_listener = {
    .configure = layer_configure, .closed = layer_closed,
};

/* --------------------------------------------------------------- input ---- */

static void drag_to(int x, int y)
{
    if (B.pin_drag_idx >= 0 && B.pin_drag_idx < B.npins) {
        struct desktop_pin *p = &B.pins[B.pin_drag_idx];
        p->x = x - B.pin_drag_dx;
        p->y = y - B.pin_drag_dy;
        pin_clamp(p);
        rerender();
        return;
    }
    if (B.drag_idx < 0 || B.drag_idx >= WIDGET_MAX) return;
    struct widget *w = &B.widgets[B.drag_idx];
    w->x = x - B.drag_dx;
    w->y = y - B.drag_dy;
    widget_clamp(w);
    rerender();
}

static void maybe_begin_drag(uint64_t now)
{
    if (B.menu_open) return;
    if (B.drag_idx >= 0 || B.pin_drag_idx >= 0) return;
    int kind = BG_PRESS_NONE, idx = -1, x = 0, y = 0, x0 = 0, y0 = 0;
    if (B.touch_active) {
        kind = B.touch_kind; idx = B.touch_idx; x = B.touch_x; y = B.touch_y; x0 = B.touch_x0; y0 = B.touch_y0;
    } else if (B.ptr_down) {
        kind = B.ptr_kind; idx = B.ptr_idx; x = B.ptr_x; y = B.ptr_y; x0 = B.ptr_x0; y0 = B.ptr_y0;
    }
    if (now - B.press_ms < WIDGET_HOLD_MS) return;
    int dx = x - x0, dy = y - y0;
    int moved = moved_past_slop(dx, dy);
    if (!moved) {
        menu_open_at(kind, idx, x, y);
        B.touch_moved = B.ptr_moved = 1;
        B.touch_kind = B.ptr_kind = BG_PRESS_NONE;
        B.touch_idx = B.ptr_idx = -1;
        rerender();
        return;
    }
    if (kind == BG_PRESS_PIN && idx < B.npins) {
        B.pin_drag_idx = idx;
        B.pin_drag_dx = x - B.pins[idx].x;
        B.pin_drag_dy = y - B.pins[idx].y;
    } else if (kind == BG_PRESS_WIDGET && idx < WIDGET_MAX) {
        B.edit_mode = 1;
        B.drag_idx = idx;
        B.drag_dx = x - B.widgets[idx].x;
        B.drag_dy = y - B.widgets[idx].y;
    }
    rerender();
}

static void drag_finish(void)
{
    if (B.drag_idx >= 0) widgets_save();
    if (B.pin_drag_idx >= 0) pins_save();
    B.drag_idx = -1;
    B.pin_drag_idx = -1;
    B.ptr_idx = B.touch_idx = -1;
    B.ptr_kind = B.touch_kind = BG_PRESS_NONE;
    rerender();
}

static void pt_enter(void *d, struct wl_pointer *p, uint32_t serial, struct wl_surface *sf,
                     wl_fixed_t x, wl_fixed_t y)
{ (void)d;(void)p;(void)serial;(void)sf; B.ptr_x = wl_fixed_to_int(x); B.ptr_y = wl_fixed_to_int(y); }
static void pt_leave(void *d, struct wl_pointer *p, uint32_t serial, struct wl_surface *sf)
{ (void)d;(void)p;(void)serial;(void)sf; B.ptr_down = 0; if ((B.drag_idx >= 0 || B.pin_drag_idx >= 0) && !B.touch_active) drag_finish(); }
static void pt_motion(void *d, struct wl_pointer *p, uint32_t time, wl_fixed_t x, wl_fixed_t y)
{
    (void)d;(void)p;(void)time;
    B.ptr_x = wl_fixed_to_int(x); B.ptr_y = wl_fixed_to_int(y);
    if (B.ptr_down) {
        int dx = B.ptr_x - B.ptr_x0, dy = B.ptr_y - B.ptr_y0;
        if (moved_past_slop(dx, dy))
            B.ptr_moved = 1;
        if (B.drag_idx >= 0 || B.pin_drag_idx >= 0) drag_to(B.ptr_x, B.ptr_y);
    }
}
static void pt_button(void *d, struct wl_pointer *p, uint32_t serial, uint32_t time,
                      uint32_t button, uint32_t state)
{
    (void)d;(void)p;(void)serial;(void)time;
    if (button != 0x110) return;
    if (state == WL_POINTER_BUTTON_STATE_PRESSED) {
        if (B.menu_open) {
            int act = menu_hit(B.ptr_x, B.ptr_y);
            if (act) menu_act(act);
            else { B.menu_open = 0; rerender(); }
            return;
        }
        B.ptr_down = 1;
        B.ptr_x0 = B.ptr_x; B.ptr_y0 = B.ptr_y;
        B.ptr_moved = 0;
        press_hit_at(B.ptr_x, B.ptr_y, &B.ptr_kind, &B.ptr_idx);
        B.press_ms = now_ms();
    } else {
        int was_pin = B.ptr_kind == BG_PRESS_PIN ? B.ptr_idx : -1;
        B.ptr_down = 0;
        if (B.drag_idx >= 0 || B.pin_drag_idx >= 0) drag_finish();
        else if (!B.ptr_moved && was_pin >= 0) pin_launch(was_pin);
        B.ptr_kind = BG_PRESS_NONE; B.ptr_idx = -1;
    }
}
static void pt_axis(void *d, struct wl_pointer *p, uint32_t t, uint32_t a, wl_fixed_t v){ (void)d;(void)p;(void)t;(void)a;(void)v; }
static void pt_frame(void *d, struct wl_pointer *p){ (void)d;(void)p; }
static void pt_axis_src(void *d, struct wl_pointer *p, uint32_t s){ (void)d;(void)p;(void)s; }
static void pt_axis_stop(void *d, struct wl_pointer *p, uint32_t t, uint32_t a){ (void)d;(void)p;(void)t;(void)a; }
static void pt_axis_disc(void *d, struct wl_pointer *p, uint32_t a, int32_t v){ (void)d;(void)p;(void)a;(void)v; }
#ifdef WL_POINTER_AXIS_VALUE120_SINCE_VERSION
static void pt_axis_v120(void *d, struct wl_pointer *p, uint32_t a, int32_t v){ (void)d;(void)p;(void)a;(void)v; }
#endif
#ifdef WL_POINTER_AXIS_RELATIVE_DIRECTION_SINCE_VERSION
static void pt_axis_dir(void *d, struct wl_pointer *p, uint32_t a, uint32_t dir){ (void)d;(void)p;(void)a;(void)dir; }
#endif
static const struct wl_pointer_listener pointer_listener = {
    .enter = pt_enter, .leave = pt_leave, .motion = pt_motion, .button = pt_button,
    .axis = pt_axis, .frame = pt_frame, .axis_source = pt_axis_src,
    .axis_stop = pt_axis_stop, .axis_discrete = pt_axis_disc,
#ifdef WL_POINTER_AXIS_VALUE120_SINCE_VERSION
    .axis_value120 = pt_axis_v120,
#endif
#ifdef WL_POINTER_AXIS_RELATIVE_DIRECTION_SINCE_VERSION
    .axis_relative_direction = pt_axis_dir,
#endif
};

static void tc_down(void *d, struct wl_touch *t, uint32_t serial, uint32_t time,
                    struct wl_surface *sf, int32_t id, wl_fixed_t x, wl_fixed_t y)
{
    (void)d;(void)t;(void)serial;(void)time;(void)sf;
    if (B.touch_active) return;
    int tx = wl_fixed_to_int(x), ty = wl_fixed_to_int(y);
    if (B.menu_open) {
        int act = menu_hit(tx, ty);
        if (act) menu_act(act);
        else { B.menu_open = 0; rerender(); }
        return;
    }
    B.touch_active = 1; B.touch_id = id;
    B.touch_x = B.touch_x0 = tx;
    B.touch_y = B.touch_y0 = ty;
    B.touch_moved = 0;
    press_hit_at(B.touch_x, B.touch_y, &B.touch_kind, &B.touch_idx);
    B.press_ms = now_ms();
}
static void tc_motion(void *d, struct wl_touch *t, uint32_t time, int32_t id, wl_fixed_t x, wl_fixed_t y)
{
    (void)d;(void)t;(void)time;
    if (!B.touch_active || id != B.touch_id) return;
    B.touch_x = wl_fixed_to_int(x); B.touch_y = wl_fixed_to_int(y);
    int dx = B.touch_x - B.touch_x0, dy = B.touch_y - B.touch_y0;
    if (moved_past_slop(dx, dy))
        B.touch_moved = 1;
    if (B.drag_idx >= 0 || B.pin_drag_idx >= 0) drag_to(B.touch_x, B.touch_y);
}
static void tc_up(void *d, struct wl_touch *t, uint32_t serial, uint32_t time, int32_t id)
{
    (void)d;(void)t;(void)serial;(void)time;
    if (!B.touch_active || id != B.touch_id) return;
    int was_pin = B.touch_kind == BG_PRESS_PIN ? B.touch_idx : -1;
    B.touch_active = 0;
    if (B.drag_idx >= 0 || B.pin_drag_idx >= 0) drag_finish();
    else if (!B.touch_moved && was_pin >= 0) pin_launch(was_pin);
    B.touch_kind = BG_PRESS_NONE; B.touch_idx = -1;
}
static void tc_frame(void *d, struct wl_touch *t){ (void)d;(void)t; }
static void tc_cancel(void *d, struct wl_touch *t)
{ (void)d;(void)t; B.touch_active = 0; if (B.drag_idx >= 0 || B.pin_drag_idx >= 0) drag_finish(); }
static void tc_shape(void *d, struct wl_touch *t, int32_t id, wl_fixed_t maj, wl_fixed_t min)
{ (void)d;(void)t;(void)id;(void)maj;(void)min; }
static void tc_orient(void *d, struct wl_touch *t, int32_t id, wl_fixed_t o)
{ (void)d;(void)t;(void)id;(void)o; }
static const struct wl_touch_listener touch_listener = {
    .down = tc_down, .up = tc_up, .motion = tc_motion, .frame = tc_frame,
    .cancel = tc_cancel, .shape = tc_shape, .orientation = tc_orient,
};

static void seat_caps(void *d, struct wl_seat *s, uint32_t caps)
{
    (void)d;
    if ((caps & WL_SEAT_CAPABILITY_POINTER) && !B.ptr) {
        B.ptr = wl_seat_get_pointer(s);
        wl_pointer_add_listener(B.ptr, &pointer_listener, NULL);
    }
    if ((caps & WL_SEAT_CAPABILITY_TOUCH) && !B.touch) {
        B.touch = wl_seat_get_touch(s);
        wl_touch_add_listener(B.touch, &touch_listener, NULL);
    }
}
static void seat_name(void *d, struct wl_seat *s, const char *n){ (void)d;(void)s;(void)n; }
static const struct wl_seat_listener seat_listener = { .capabilities = seat_caps, .name = seat_name };

/* --------------------------------------------------------------- registry */

/* Follow the compositor's output scale so the wallpaper is decoded/covered at
 * the real physical resolution on any DPI; IOSC_PANEL_SCALE overrides. */
static void out_geometry(void *d, struct wl_output *o, int32_t x, int32_t y,
                         int32_t pw, int32_t ph, int32_t sp,
                         const char *mk, const char *md, int32_t tr)
{ (void)d;(void)o;(void)x;(void)y;(void)pw;(void)ph;(void)sp;(void)mk;(void)md;(void)tr; }
static void out_mode(void *d, struct wl_output *o, uint32_t f, int32_t w, int32_t h, int32_t r)
{ (void)d;(void)o;(void)f;(void)w;(void)h;(void)r; }
static void out_done(void *d, struct wl_output *o){ (void)d;(void)o; }
static void out_scale(void *d, struct wl_output *o, int32_t f)
{
    (void)d;(void)o;
    if (B.scale_env || f <= 0 || f == B.scale) return;
    B.scale = (int)f;
    B.pins_loaded = 0;
    base_cache_clear();
    render();
}
static const struct wl_output_listener output_listener = {
    .geometry = out_geometry, .mode = out_mode, .done = out_done, .scale = out_scale,
};

static void reg_global(void *d, struct wl_registry *r, uint32_t name, const char *iface, uint32_t ver)
{
    (void)d;
    if (!strcmp(iface, wl_compositor_interface.name))
        B.comp = wl_registry_bind(r, name, &wl_compositor_interface, ver < 4 ? ver : 4);
    else if (!strcmp(iface, wl_shm_interface.name))
        B.shm = wl_registry_bind(r, name, &wl_shm_interface, 1);
    else if (!strcmp(iface, wl_output_interface.name) && !B.output) {
        B.output = wl_registry_bind(r, name, &wl_output_interface, ver < 2 ? ver : 2);
        if (ver >= 2) wl_output_add_listener(B.output, &output_listener, NULL);
    } else if (!strcmp(iface, wl_seat_interface.name)) {
        B.seat = wl_registry_bind(r, name, &wl_seat_interface, ver < 5 ? ver : 5);
        wl_seat_add_listener(B.seat, &seat_listener, NULL);
    } else if (!strcmp(iface, zwlr_layer_shell_v1_interface.name))
        B.layer_shell = wl_registry_bind(r, name, &zwlr_layer_shell_v1_interface, ver < 4 ? ver : 4);
}
static void reg_remove(void *d, struct wl_registry *r, uint32_t name){ (void)d;(void)r;(void)name; }
static const struct wl_registry_listener registry_listener = { .global = reg_global, .global_remove = reg_remove };

/* ------------------------------------------------------------------ main */

int main(void)
{
    signal(SIGCHLD, SIG_IGN);
    memset(&B, 0, sizeof B);
    B.width = 1440; B.height = 1080; B.scale = 2; B.running = 1;
    B.drag_idx = B.pin_drag_idx = B.ptr_idx = B.touch_idx = -1;
    const char *es = getenv("IOSC_PANEL_SCALE");
    if (es && atoi(es) > 0) { B.scale = atoi(es); B.scale_env = 1; }
    widgets_load();
    pins_load();
    widgets_update_stats();

    char wp[512];
    wallpaper_current_path(wp, sizeof wp);
#ifdef __APPLE__
    B.image = load_wallpaper(wp);
    fprintf(stderr, "ioscbg: wallpaper %s (%s)\n", wp, B.image ? "loaded" : "missing -> gradient");
#else
    fprintf(stderr, "ioscbg: no ImageIO on this platform -> gradient\n");
#endif

    B.dpy = wl_display_connect(NULL);
    if (!B.dpy) { fprintf(stderr, "ioscbg: cannot connect to WAYLAND_DISPLAY\n"); return 1; }
    struct wl_registry *reg = wl_display_get_registry(B.dpy);
    wl_registry_add_listener(reg, &registry_listener, NULL);
    wl_display_roundtrip(B.dpy);
    wl_display_roundtrip(B.dpy);

    if (!B.comp || !B.shm) { fprintf(stderr, "ioscbg: missing wl_compositor/wl_shm\n"); return 1; }
    if (!B.layer_shell) {
        fprintf(stderr, "ioscbg: compositor lacks zwlr_layer_shell_v1 — cannot map\n");
        return 2;
    }

    B.wall_surf = wl_compositor_create_surface(B.comp);
    B.wall_layer = zwlr_layer_shell_v1_get_layer_surface(B.layer_shell, B.wall_surf, NULL,
                   ZWLR_LAYER_SHELL_V1_LAYER_BACKGROUND, "wallpaper");
    zwlr_layer_surface_v1_add_listener(B.wall_layer, &layer_listener, &wall_ref);
    zwlr_layer_surface_v1_set_anchor(B.wall_layer,
        ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP | ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM |
        ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT | ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT);
    zwlr_layer_surface_v1_set_size(B.wall_layer, 0, 0);
    zwlr_layer_surface_v1_set_exclusive_zone(B.wall_layer, -1);
    zwlr_layer_surface_v1_set_keyboard_interactivity(B.wall_layer, 0);

    B.desk_surf = wl_compositor_create_surface(B.comp);
    B.desk_layer = zwlr_layer_shell_v1_get_layer_surface(B.layer_shell, B.desk_surf, NULL,
                   ZWLR_LAYER_SHELL_V1_LAYER_BACKGROUND, "desktop-items");
    zwlr_layer_surface_v1_add_listener(B.desk_layer, &layer_listener, &desk_ref);
    zwlr_layer_surface_v1_set_anchor(B.desk_layer,
        ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP | ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM |
        ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT | ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT);
    zwlr_layer_surface_v1_set_size(B.desk_layer, 0, 0);
    zwlr_layer_surface_v1_set_exclusive_zone(B.desk_layer, -1);
    zwlr_layer_surface_v1_set_keyboard_interactivity(B.desk_layer, 0);

    wl_surface_commit(B.wall_surf);
    wl_surface_commit(B.desk_surf);

    int fd = wl_display_get_fd(B.dpy);
    while (B.running) {
        while (wl_display_prepare_read(B.dpy) != 0) wl_display_dispatch_pending(B.dpy);
        wl_display_flush(B.dpy);
        struct pollfd pfd = { .fd = fd, .events = POLLIN };
        int timeout = 1000;
        if ((B.touch_active && B.touch_idx >= 0) || (B.ptr_down && B.ptr_idx >= 0))
            timeout = 50;
        int n = poll(&pfd, 1, timeout);
        if (n < 0 && errno != EINTR) { wl_display_cancel_read(B.dpy); break; }
        if (n > 0 && (pfd.revents & POLLIN)) wl_display_read_events(B.dpy);
        else wl_display_cancel_read(B.dpy);
        wl_display_dispatch_pending(B.dpy);
        uint64_t ms = now_ms();
        maybe_begin_drag(ms);
        if (menu_dismiss_if_idle(ms)) {
            rerender();
        } else if (pins_reload_if_due(ms)) {
            rerender();
        } else if (ms - B.last_stats_ms > 2500) {
            int changed = widgets_update_stats();
            if (changed) render_desktop_widgets(changed);
        }
    }
    sd_cairo_pool_destroy(&B.wall_pool);
    sd_cairo_pool_destroy(&B.desk_pool);
    wl_display_disconnect(B.dpy);
    base_cache_clear();
#ifdef __APPLE__
    if (B.image) CGImageRelease(B.image);
#endif
    return 0;
}

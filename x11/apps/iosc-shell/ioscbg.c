/*
 * ioscbg — the wallpaper client for the iosc desktop shell.
 *
 * A minimal zwlr_layer_shell_v1 client on the BACKGROUND layer spanning the
 * whole output. It decodes the xios-desktop-theme wallpaper with ImageIO /
 * CoreGraphics — native iOS frameworks, so JPEG/PNG/HEIC all work with zero
 * new package dependencies — and cover-scales it straight into the wl_shm
 * buffer (premultiplied BGRA, exactly iosc's byte order). If no wallpaper
 * resolves, it paints the theme's deep indigo gradient instead.
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
#define SD_CAIRO
#include "shell-draw.h"
#include "shell-theme.h"
#include "panel-render.h"
#include "wlr-layer-shell-unstable-v1-client-protocol.h"

#include <poll.h>
#include <errno.h>
#include <signal.h>
#include <sys/mount.h>
#include <sys/sysctl.h>
#include <time.h>

#ifdef __APPLE__
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <ImageIO/ImageIO.h>
#include <mach/mach.h>
#endif

#define WIDGET_MAX       4
#define WIDGET_W         224
#define WIDGET_H         104
#define WIDGET_HOLD_MS   540
#define WIDGET_SLOP      10

struct widget {
    const char *key;
    const char *title;
    char value[32];
    char detail[64];
    double frac;
    int x, y, w, h, visible;
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
    struct wl_surface    *surf;
    struct zwlr_layer_surface_v1 *layer;
    int   width, height, scale, scale_env, configured, running;
    int   drawn_w, drawn_h;           /* last rendered size (skip redundant redraws) */
    struct widget widgets[WIDGET_MAX];
    int   widgets_loaded, edit_mode, drag_idx, drag_dx, drag_dy;
    int   ptr_down, ptr_idx, ptr_x, ptr_y, ptr_x0, ptr_y0;
    int   touch_active, touch_id, touch_idx, touch_x, touch_y, touch_x0, touch_y0;
    uint64_t press_ms, last_stats_ms;
#ifdef __APPLE__
    CGImageRef image;
#endif
} B;

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

static void widgets_default(void)
{
    B.widgets[0] = (struct widget){ "storage", "Storage", "", "", 0, 42, 92, WIDGET_W, WIDGET_H, 1 };
    B.widgets[1] = (struct widget){ "memory",  "Memory",  "", "", 0, 42, 212, WIDGET_W, WIDGET_H, 1 };
    B.widgets[2] = (struct widget){ "load",    "Load",    "", "", 0, 42, 332, WIDGET_W, WIDGET_H, 1 };
    B.widgets[3] = (struct widget){ "uptime",  "Session", "", "", 0, 42, 452, WIDGET_W, WIDGET_H, 1 };
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

static void fmt_bytes(char *out, size_t n, uint64_t bytes)
{
    const char *u[] = { "B", "KB", "MB", "GB", "TB" };
    double v = (double)bytes;
    int i = 0;
    while (i < 4 && v >= 1024.0) { v /= 1024.0; i++; }
    snprintf(out, n, i == 0 ? "%.0f %s" : "%.1f %s", v, u[i]);
}

static void widgets_update_stats(void)
{
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

static void widget_clamp(struct widget *w)
{
    if (w->x < 8) w->x = 8;
    if (w->y < 48) w->y = 48;
    if (B.width > 0 && w->x + w->w > B.width - 8) w->x = B.width - 8 - w->w;
    if (B.height > 0 && w->y + w->h > B.height - 8) w->y = B.height - 8 - w->h;
}

static void widgets_draw(cairo_t *cr)
{
    pr_text_ctx t = pr_text_ctx_new(cr);
    for (int i = 0; i < WIDGET_MAX; i++) {
        struct widget *w = &B.widgets[i];
        if (!w->visible) continue;
        widget_clamp(w);
        int hot = (B.edit_mode && i == B.drag_idx);
        pr_fill_rrect(cr, w->x + 0, w->y + 8, w->w, w->h, 24, 0x30000000u);
        pr_fill_rrect(cr, w->x, w->y, w->w, w->h, 24, hot ? 0xB8222328u : 0xA8191A1Fu);
        pr_fill_rect(cr, w->x + 20, w->y + 1, w->w - 40, 1.2, 0x44FFFFFFu);
        pr_stroke_rrect(cr, w->x, w->y, w->w, w->h, 24, hot ? TH_ACCENT : 0x36FFFFFFu, hot ? 1.8 : 1.0);
        pr_text(cr, &t, TH_FONT_SMALL, w->title, w->x + 18, w->y + 22, TH_FG_DIM, w->w - 36);
        pr_text(cr, &t, "Sans Bold 26", w->value, w->x + 18, w->y + 52, TH_FG, w->w - 36);
        pr_text(cr, &t, TH_FONT_SMALL, w->detail, w->x + 18, w->y + 78, 0xCCFFFFFFu, w->w - 36);
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

static void render(void)
{
    if (!B.configured) return;
    if (!B.widgets_loaded) widgets_load();
    if (now_ms() - B.last_stats_ms > 2500) widgets_update_stats();

    int s = B.scale, bw = B.width * s, bh = B.height * s;
    int stride = bw * 4;
    size_t size = (size_t)stride * bh;
    int fd = sd_create_anon_fd(size);
    if (fd < 0) return;
    uint32_t *map = mmap(NULL, size, PROT_READ|PROT_WRITE, MAP_SHARED, fd, 0);
    if (map == MAP_FAILED) { close(fd); return; }
    struct wl_shm_pool *pool = wl_shm_create_pool(B.shm, fd, (int32_t)size);
    struct wl_buffer *buf = wl_shm_pool_create_buffer(pool, 0, bw, bh, stride,
                                                      WL_SHM_FORMAT_ARGB8888);
    wl_shm_pool_destroy(pool);
    close(fd);

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
                /* cover: scale up to fill, center the overflow */
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

    cairo_surface_t *cs = cairo_image_surface_create_for_data(
        (unsigned char *)map, CAIRO_FORMAT_ARGB32, bw, bh, stride);
    cairo_t *cr = cairo_create(cs);
    cairo_scale(cr, s, s);
    widgets_draw(cr);
    cairo_destroy(cr);
    cairo_surface_destroy(cs);
    munmap(map, size);

    wl_buffer_add_listener(buf, &sd_buf_listener, NULL);
    wl_surface_set_buffer_scale(B.surf, B.scale);
    wl_surface_attach(B.surf, buf, 0, 0);
    wl_surface_damage_buffer(B.surf, 0, 0, bw, bh);
    wl_surface_commit(B.surf);
    B.drawn_w = B.width; B.drawn_h = B.height;
}

static void rerender(void)
{
    B.drawn_w = B.drawn_h = -1;
    render();
}

/* ------------------------------------------------------- layer surface --- */

static void layer_configure(void *d, struct zwlr_layer_surface_v1 *ls, uint32_t serial, uint32_t w, uint32_t h)
{
    (void)d;
    if (w) B.width = (int)w;
    if (h) B.height = (int)h;
    zwlr_layer_surface_v1_ack_configure(ls, serial);
    B.configured = 1;
    render();
}
static void layer_closed(void *d, struct zwlr_layer_surface_v1 *ls){ (void)d;(void)ls; B.running = 0; }
static const struct zwlr_layer_surface_v1_listener layer_listener = {
    .configure = layer_configure, .closed = layer_closed,
};

/* --------------------------------------------------------------- input ---- */

static void drag_to(int x, int y)
{
    if (B.drag_idx < 0 || B.drag_idx >= WIDGET_MAX) return;
    struct widget *w = &B.widgets[B.drag_idx];
    w->x = x - B.drag_dx;
    w->y = y - B.drag_dy;
    widget_clamp(w);
    rerender();
}

static void maybe_begin_drag(uint64_t now)
{
    if (B.edit_mode || B.drag_idx >= 0) return;
    int idx = -1, x = 0, y = 0, x0 = 0, y0 = 0;
    if (B.touch_active && B.touch_idx >= 0) {
        idx = B.touch_idx; x = B.touch_x; y = B.touch_y; x0 = B.touch_x0; y0 = B.touch_y0;
    } else if (B.ptr_down && B.ptr_idx >= 0) {
        idx = B.ptr_idx; x = B.ptr_x; y = B.ptr_y; x0 = B.ptr_x0; y0 = B.ptr_y0;
    }
    if (idx < 0 || now - B.press_ms < WIDGET_HOLD_MS) return;
    int dx = x - x0, dy = y - y0;
    if ((dx < 0 ? -dx : dx) > WIDGET_SLOP || (dy < 0 ? -dy : dy) > WIDGET_SLOP) return;
    B.edit_mode = 1;
    B.drag_idx = idx;
    B.drag_dx = x - B.widgets[idx].x;
    B.drag_dy = y - B.widgets[idx].y;
    rerender();
}

static void drag_finish(void)
{
    if (B.drag_idx >= 0) widgets_save();
    B.drag_idx = -1;
    B.ptr_idx = B.touch_idx = -1;
    rerender();
}

static void pt_enter(void *d, struct wl_pointer *p, uint32_t serial, struct wl_surface *sf,
                     wl_fixed_t x, wl_fixed_t y)
{ (void)d;(void)p;(void)serial;(void)sf; B.ptr_x = wl_fixed_to_int(x); B.ptr_y = wl_fixed_to_int(y); }
static void pt_leave(void *d, struct wl_pointer *p, uint32_t serial, struct wl_surface *sf)
{ (void)d;(void)p;(void)serial;(void)sf; B.ptr_down = 0; if (B.drag_idx >= 0 && !B.touch_active) drag_finish(); }
static void pt_motion(void *d, struct wl_pointer *p, uint32_t time, wl_fixed_t x, wl_fixed_t y)
{
    (void)d;(void)p;(void)time;
    B.ptr_x = wl_fixed_to_int(x); B.ptr_y = wl_fixed_to_int(y);
    if (B.ptr_down && B.drag_idx >= 0) drag_to(B.ptr_x, B.ptr_y);
}
static void pt_button(void *d, struct wl_pointer *p, uint32_t serial, uint32_t time,
                      uint32_t button, uint32_t state)
{
    (void)d;(void)p;(void)serial;(void)time;
    if (button != 0x110) return;
    if (state == WL_POINTER_BUTTON_STATE_PRESSED) {
        B.ptr_down = 1;
        B.ptr_x0 = B.ptr_x; B.ptr_y0 = B.ptr_y;
        B.ptr_idx = widget_hit(B.ptr_x, B.ptr_y);
        B.press_ms = now_ms();
    } else {
        B.ptr_down = 0;
        if (B.drag_idx >= 0) drag_finish();
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
    B.touch_active = 1; B.touch_id = id;
    B.touch_x = B.touch_x0 = wl_fixed_to_int(x);
    B.touch_y = B.touch_y0 = wl_fixed_to_int(y);
    B.touch_idx = widget_hit(B.touch_x, B.touch_y);
    B.press_ms = now_ms();
}
static void tc_motion(void *d, struct wl_touch *t, uint32_t time, int32_t id, wl_fixed_t x, wl_fixed_t y)
{
    (void)d;(void)t;(void)time;
    if (!B.touch_active || id != B.touch_id) return;
    B.touch_x = wl_fixed_to_int(x); B.touch_y = wl_fixed_to_int(y);
    if (B.drag_idx >= 0) drag_to(B.touch_x, B.touch_y);
}
static void tc_up(void *d, struct wl_touch *t, uint32_t serial, uint32_t time, int32_t id)
{
    (void)d;(void)t;(void)serial;(void)time;
    if (!B.touch_active || id != B.touch_id) return;
    B.touch_active = 0;
    if (B.drag_idx >= 0) drag_finish();
}
static void tc_frame(void *d, struct wl_touch *t){ (void)d;(void)t; }
static void tc_cancel(void *d, struct wl_touch *t)
{ (void)d;(void)t; B.touch_active = 0; if (B.drag_idx >= 0) drag_finish(); }
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
    B.drawn_w = B.drawn_h = -1;   /* invalidate the size cache: same logical,
                                   * new physical -> must repaint */
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
    B.drawn_w = B.drawn_h = -1;
    B.drag_idx = B.ptr_idx = B.touch_idx = -1;
    const char *es = getenv("IOSC_PANEL_SCALE");
    if (es && atoi(es) > 0) { B.scale = atoi(es); B.scale_env = 1; }
    widgets_load();
    widgets_update_stats();

    const char *wp = getenv("IOSC_WALLPAPER");
    char default_wp[256];
    if (!wp || !*wp) {
        sd_join_path(default_wp, sizeof default_wp, sd_jbroot(),
                     "/usr/share/backgrounds/xios/xios-default.jpg");
        wp = default_wp;
    }
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

    B.surf  = wl_compositor_create_surface(B.comp);
    B.layer = zwlr_layer_shell_v1_get_layer_surface(B.layer_shell, B.surf, NULL,
                ZWLR_LAYER_SHELL_V1_LAYER_BACKGROUND, "wallpaper");
    zwlr_layer_surface_v1_add_listener(B.layer, &layer_listener, NULL);
    zwlr_layer_surface_v1_set_anchor(B.layer,
        ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP | ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM |
        ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT | ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT);
    zwlr_layer_surface_v1_set_size(B.layer, 0, 0);          /* span the output */
    zwlr_layer_surface_v1_set_exclusive_zone(B.layer, -1);  /* under everything */
    zwlr_layer_surface_v1_set_keyboard_interactivity(B.layer, 0);
    wl_surface_commit(B.surf);

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
        if (ms - B.last_stats_ms > 2500) rerender();
    }
    wl_display_disconnect(B.dpy);
    return 0;
}

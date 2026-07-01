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
 * /var/jb/usr/share/backgrounds/xios/xios-default.jpg.
 *
 * No input, no timers: it renders on configure (and re-renders if the output
 * size changes, e.g. a future rotation) and then just keeps the connection
 * alive. Build: build-panel.sh. Needs iosc's zwlr_layer_shell_v1.
 */
#define _GNU_SOURCE
#define SD_NO_DRAW                    /* only sd_create_anon_fd from shell-draw.h */
#include "shell-draw.h"
#include "shell-theme.h"
#include "wlr-layer-shell-unstable-v1-client-protocol.h"

#include <poll.h>
#include <errno.h>
#include <signal.h>

#ifdef __APPLE__
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <ImageIO/ImageIO.h>
#endif

#define WALLPAPER_DEFAULT "/var/jb/usr/share/backgrounds/xios/xios-default.jpg"

static struct {
    struct wl_display    *dpy;
    struct wl_compositor *comp;
    struct wl_shm        *shm;
    struct wl_output     *output;
    struct zwlr_layer_shell_v1 *layer_shell;
    struct wl_surface    *surf;
    struct zwlr_layer_surface_v1 *layer;
    int   width, height, scale, scale_env, configured, running;
    int   drawn_w, drawn_h;           /* last rendered size (skip redundant redraws) */
#ifdef __APPLE__
    CGImageRef image;
#endif
} B;

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

static void buf_release(void *d, struct wl_buffer *b){ (void)d; wl_buffer_destroy(b); }
static const struct wl_buffer_listener buf_listener = { .release = buf_release };

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
    if (B.drawn_w == B.width && B.drawn_h == B.height) return;

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
    munmap(map, size);

    wl_buffer_add_listener(buf, &buf_listener, NULL);
    wl_surface_attach(B.surf, buf, 0, 0);
    wl_surface_damage_buffer(B.surf, 0, 0, bw, bh);
    wl_surface_commit(B.surf);
    B.drawn_w = B.width; B.drawn_h = B.height;
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
    const char *es = getenv("IOSC_PANEL_SCALE");
    if (es && atoi(es) > 0) { B.scale = atoi(es); B.scale_env = 1; }

    const char *wp = getenv("IOSC_WALLPAPER");
    if (!wp || !*wp) wp = WALLPAPER_DEFAULT;
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
        int n = poll(&pfd, 1, -1);
        if (n < 0 && errno != EINTR) { wl_display_cancel_read(B.dpy); break; }
        if (n > 0 && (pfd.revents & POLLIN)) wl_display_read_events(B.dpy);
        else wl_display_cancel_read(B.dpy);
        wl_display_dispatch_pending(B.dpy);
    }
    wl_display_disconnect(B.dpy);
    return 0;
}

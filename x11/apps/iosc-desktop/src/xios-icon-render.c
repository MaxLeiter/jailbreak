/*
 * xios-icon-render.c — render one freedesktop icon source into the iOS app-icon
 * PNG sizes used by generated Xios launcher bundles.
 *
 * This is the on-device counterpart to gen-icons.py's compose() path. It avoids
 * ImageMagick/Pillow: gdk-pixbuf already gives us PNG/SVG loading through the
 * installed loader set, scaling, alpha access, compositing, and PNG writing.
 */
#include <errno.h>
#include <libgen.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#include <gdk-pixbuf/gdk-pixbuf.h>

static const int bg_top[3] = { 24, 27, 38 };
static const int bg_bot[3] = { 9, 10, 16 };

struct output_icon {
    const char *name;
    int size;
};

static const struct output_icon outputs[] = {
    { "AppIcon60x60@2x.png", 120 },
    { "AppIcon76x76@2x~ipad.png", 152 },
    { "AppIcon83.5x83.5@2x~ipad.png", 167 },
};

static int mkdir_p(const char *path)
{
    char tmp[1024];
    size_t len = strlen(path);
    if (len == 0 || len >= sizeof(tmp)) return -1;
    memcpy(tmp, path, len + 1);
    for (char *p = tmp + 1; *p; p++) {
        if (*p != '/') continue;
        *p = 0;
        if (mkdir(tmp, 0755) != 0 && errno != EEXIST) return -1;
        *p = '/';
    }
    if (mkdir(tmp, 0755) != 0 && errno != EEXIST) return -1;
    return 0;
}

static unsigned char lerp_chan(int a, int b, double t)
{
    return (unsigned char)lrint((double)a * (1.0 - t) + (double)b * t);
}

static GdkPixbuf *new_gradient(int size)
{
    GdkPixbuf *pb = gdk_pixbuf_new(GDK_COLORSPACE_RGB, TRUE, 8, size, size);
    if (!pb) return NULL;
    int stride = gdk_pixbuf_get_rowstride(pb);
    int channels = gdk_pixbuf_get_n_channels(pb);
    guchar *pixels = gdk_pixbuf_get_pixels(pb);
    for (int y = 0; y < size; y++) {
        double t = size > 1 ? (double)y / (double)size : 0.0;
        guchar r = lerp_chan(bg_top[0], bg_bot[0], t);
        guchar g = lerp_chan(bg_top[1], bg_bot[1], t);
        guchar b = lerp_chan(bg_top[2], bg_bot[2], t);
        guchar *row = pixels + y * stride;
        for (int x = 0; x < size; x++) {
            guchar *px = row + x * channels;
            px[0] = r; px[1] = g; px[2] = b; px[3] = 255;
        }
    }
    return pb;
}

static GdkPixbuf *crop_alpha_bounds(GdkPixbuf *src)
{
    if (!gdk_pixbuf_get_has_alpha(src))
        return gdk_pixbuf_copy(src);

    int w = gdk_pixbuf_get_width(src);
    int h = gdk_pixbuf_get_height(src);
    int stride = gdk_pixbuf_get_rowstride(src);
    int channels = gdk_pixbuf_get_n_channels(src);
    guchar *pixels = gdk_pixbuf_get_pixels(src);
    int minx = w, miny = h, maxx = -1, maxy = -1;

    for (int y = 0; y < h; y++) {
        guchar *row = pixels + y * stride;
        for (int x = 0; x < w; x++) {
            if (row[x * channels + 3] == 0) continue;
            if (x < minx) minx = x;
            if (y < miny) miny = y;
            if (x > maxx) maxx = x;
            if (y > maxy) maxy = y;
        }
    }
    if (maxx < minx || maxy < miny)
        return gdk_pixbuf_copy(src);
    return gdk_pixbuf_new_subpixbuf(src, minx, miny, maxx - minx + 1, maxy - miny + 1);
}

static int render_one(GdkPixbuf *src, const char *outdir, const struct output_icon *out)
{
    GdkPixbuf *canvas = new_gradient(out->size);
    GdkPixbuf *cropped = crop_alpha_bounds(src);
    if (!canvas || !cropped) {
        if (canvas) g_object_unref(canvas);
        if (cropped) g_object_unref(cropped);
        return -1;
    }

    int cw = gdk_pixbuf_get_width(cropped);
    int ch = gdk_pixbuf_get_height(cropped);
    int inner = (int)lrint((double)out->size * 0.80);
    double scale = fmin((double)inner / (double)cw, (double)inner / (double)ch);
    int sw = (int)fmax(1.0, lrint((double)cw * scale));
    int sh = (int)fmax(1.0, lrint((double)ch * scale));
    GdkPixbuf *scaled = gdk_pixbuf_scale_simple(cropped, sw, sh, GDK_INTERP_HYPER);
    g_object_unref(cropped);
    if (!scaled) {
        g_object_unref(canvas);
        return -1;
    }

    int x = (out->size - sw) / 2;
    int y = (out->size - sh) / 2;
    gdk_pixbuf_composite(scaled, canvas, x, y, sw, sh,
                         x, y, 1.0, 1.0, GDK_INTERP_HYPER, 255);
    g_object_unref(scaled);

    char path[1024];
    snprintf(path, sizeof(path), "%s/%s", outdir, out->name);
    GError *err = NULL;
    int ok = gdk_pixbuf_save(canvas, path, "png", &err, NULL);
    if (!ok) {
        fprintf(stderr, "xios-icon-render: save %s: %s\n",
                path, err ? err->message : "unknown error");
        if (err) g_error_free(err);
        g_object_unref(canvas);
        return -1;
    }
    chmod(path, 0644);
    g_object_unref(canvas);
    return 0;
}

static void usage(const char *argv0)
{
    fprintf(stderr, "usage: %s SOURCE_ICON OUT_DIR\n", argv0);
}

int main(int argc, char **argv)
{
    if (argc != 3) {
        usage(argv[0]);
        return 2;
    }
    const char *source = argv[1];
    const char *outdir = argv[2];
    if (mkdir_p(outdir) != 0) {
        fprintf(stderr, "xios-icon-render: mkdir %s: %s\n", outdir, strerror(errno));
        return 1;
    }

    GError *err = NULL;
    GdkPixbuf *src = gdk_pixbuf_new_from_file_at_scale(source, 1024, 1024, TRUE, &err);
    if (!src) {
        fprintf(stderr, "xios-icon-render: load %s: %s\n",
                source, err ? err->message : "unknown error");
        if (err) g_error_free(err);
        return 1;
    }

    int rc = 0;
    for (size_t i = 0; i < sizeof(outputs) / sizeof(outputs[0]); i++)
        if (render_one(src, outdir, &outputs[i]) != 0)
            rc = 1;
    g_object_unref(src);
    return rc;
}

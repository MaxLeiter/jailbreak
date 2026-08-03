/*
 * Isolate the black-pixmap defect: is it OpenJDK's libawt_xawt, or the X
 * server / libXrender underneath it?
 *
 * Java2D's XRender pipeline backs a VolatileImage with an X Pixmap, wraps it
 * in an XRender Picture, fills it, and reads it back. That comes back black on
 * both Xvfb and glamor-backed Xwayland. This does the same thing in ~100 lines
 * of plain Xlib/Xrender with no JVM involved, plus a core-X11 XFillRectangle
 * control on an identical pixmap.
 *
 *   core fill OK + render fill BLACK -> XRender path (server or libXrender)
 *   both BLACK                       -> pixmap alloc/readback, not XRender
 *   both OK                          -> the bug is above this layer, i.e. ours
 *
 * RESULT on iPad7,12 / Xvfb 1.20.11, 2026-08-02: all four cases OK
 * (339966), including the 1x1-repeating-solid composite that
 * XRSurfaceData/XRCompositeManager actually issues. So the X server,
 * libXrender and the composite pattern are all correct, and the black
 * VolatileImage is inside OpenJDK's Java2D XRender implementation in our
 * build. See ../../docs/handoff/openjdk.md.
 *
 * Build (host, against the AWT lane's header sysroot):
 *
 *   W=linux-build/out/openjdk-awt-ios-work
 *   xcrun -sdk iphoneos clang -arch arm64 \
 *     -isysroot "$(xcrun --sdk iphoneos --show-sdk-path)" -mios-version-min=16.0 \
 *     -I"$W/ios-build-include" -o xrender-pixmap-probe xrender-pixmap-probe.c \
 *     "$W/header-sysroot/var/jb/usr/lib/libX11.6.dylib" \
 *     "$W/header-sysroot/var/jb/usr/lib/libXrender.1.dylib" \
 *     -Wl,-rpath,/var/jb/usr/lib
 *
 * Then copy to the device, `ldid -S` it there (a host signature is rejected),
 * and run it with DISPLAY pointing at an X server.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/extensions/Xrender.h>

#define W 64
#define H 32

/* 0x33 0x99 0x66, the same colour the Java probe uses. */
#define R8 0x33
#define G8 0x99
#define B8 0x66

static unsigned long read_px(Display *d, Pixmap p, int depth, const char *tag)
{
    XImage *img = XGetImage(d, p, 0, 0, W, H, AllPlanes, ZPixmap);
    if (!img) {
        printf("%-18s XGetImage FAILED\n", tag);
        return 0xdeadbeef;
    }
    unsigned long px = XGetPixel(img, 10, 10) & 0xffffff;
    printf("%-18s depth=%d px=%06lx %s\n", tag, depth, px,
           px == ((R8 << 16) | (G8 << 8) | B8) ? "OK" : "<-- WRONG");
    XDestroyImage(img);
    return px;
}

int main(int argc, char **argv)
{
    const char *dpyname = argc > 1 ? argv[1] : NULL;
    Display *d = XOpenDisplay(dpyname);
    if (!d) {
        fprintf(stderr, "cannot open display %s\n", dpyname ? dpyname : "(default)");
        return 1;
    }
    int scr = DefaultScreen(d);
    Window root = RootWindow(d, scr);
    int depth = DefaultDepth(d, scr);
    printf("display=%s vendor=%s depth=%d\n",
           DisplayString(d), ServerVendor(d), depth);

    int ev = 0, er = 0, major = 0, minor = 0;
    if (!XRenderQueryExtension(d, &ev, &er)) {
        printf("RENDER extension: ABSENT\n");
    } else {
        XRenderQueryVersion(d, &major, &minor);
        printf("RENDER extension: present %d.%d\n", major, minor);
    }

    /* --- control: core X11 fill into a pixmap --- */
    Pixmap pm_core = XCreatePixmap(d, root, W, H, depth);
    GC gc = XCreateGC(d, pm_core, 0, NULL);
    XSetForeground(d, gc, (R8 << 16) | (G8 << 8) | B8);
    XFillRectangle(d, pm_core, gc, 0, 0, W, H);
    XSync(d, False);
    read_px(d, pm_core, depth, "core XFillRect");

    /* --- the path Java2D uses: XRender fill into a Picture on a pixmap --- */
    XRenderPictFormat *fmt = XRenderFindVisualFormat(d, DefaultVisual(d, scr));
    if (!fmt) {
        printf("XRenderFindVisualFormat: NULL (no format for default visual)\n");
    } else {
        printf("picture format: depth=%d direct.red=%d green=%d blue=%d alpha=%d\n",
               fmt->depth, fmt->direct.red, fmt->direct.green,
               fmt->direct.blue, fmt->direct.alphaMask);
        Pixmap pm_r = XCreatePixmap(d, root, W, H, depth);
        Picture pic = XRenderCreatePicture(d, pm_r, fmt, 0, NULL);
        XRenderColor col;
        /* XRenderColor is 16-bit premultiplied. */
        col.red   = R8 * 0x101;
        col.green = G8 * 0x101;
        col.blue  = B8 * 0x101;
        col.alpha = 0xffff;
        XRenderFillRectangle(d, PictOpSrc, pic, &col, 0, 0, W, H);
        XSync(d, False);
        read_px(d, pm_r, depth, "XRenderFillRect");
        XRenderFreePicture(d, pic);
        XFreePixmap(d, pm_r);
    }

    /* --- and the same XRender fill into a 32-bit ARGB pixmap, which is what
     *     an accelerated VolatileImage/Picture usually ends up being --- */
    XRenderPictFormat *fmt32 = XRenderFindStandardFormat(d, PictStandardARGB32);
    if (fmt32) {
        Pixmap pm32 = XCreatePixmap(d, root, W, H, 32);
        Picture pic32 = XRenderCreatePicture(d, pm32, fmt32, 0, NULL);
        XRenderColor col = { R8 * 0x101, G8 * 0x101, B8 * 0x101, 0xffff };
        XRenderFillRectangle(d, PictOpSrc, pic32, &col, 0, 0, W, H);
        XSync(d, False);
        read_px(d, pm32, 32, "XRender ARGB32");
        XRenderFreePicture(d, pic32);
        XFreePixmap(d, pm32);
    } else {
        printf("PictStandardARGB32: unavailable\n");
    }

    /* --- the pattern Java2D actually uses: composite from a 1x1 REPEATING
     *     solid source Picture onto the destination, rather than
     *     XRenderFillRectangle. XRSurfaceData/XRCompositeManager builds a
     *     solid src picture once and compositing it is how it paints. --- */
    if (fmt32) {
        Pixmap pm_dst = XCreatePixmap(d, root, W, H, depth);
        XRenderPictFormat *dfmt = XRenderFindVisualFormat(d, DefaultVisual(d, scr));
        Picture dst = XRenderCreatePicture(d, pm_dst, dfmt, 0, NULL);

        Pixmap pm_src = XCreatePixmap(d, root, 1, 1, 32);
        XRenderPictureAttributes pa;
        memset(&pa, 0, sizeof(pa));
        pa.repeat = RepeatNormal;
        Picture src = XRenderCreatePicture(d, pm_src, fmt32, CPRepeat, &pa);

        XRenderColor col = { R8 * 0x101, G8 * 0x101, B8 * 0x101, 0xffff };
        XRenderFillRectangle(d, PictOpSrc, src, &col, 0, 0, 1, 1);
        XRenderComposite(d, PictOpSrc, src, None, dst, 0, 0, 0, 0, 0, 0, W, H);
        XSync(d, False);
        read_px(d, pm_dst, depth, "composite 1x1rep");

        XRenderFreePicture(d, src);
        XRenderFreePicture(d, dst);
        XFreePixmap(d, pm_src);
        XFreePixmap(d, pm_dst);
    }

    XFreeGC(d, gc);
    XFreePixmap(d, pm_core);
    XCloseDisplay(d);
    printf("XRPROBE_DONE\n");
    return 0;
}

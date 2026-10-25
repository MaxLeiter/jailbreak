#import "capture.h"
#import "spi.h"

#import <Accelerate/Accelerate.h>
#import <ImageIO/ImageIO.h>
#include <mach/mach_time.h>
#include <stdlib.h>

#define BGRA_FOURCC 0x42475241u  // 'BGRA'

struct ipc_capturer {
    ipc_geometry g;
    IOSurfaceRef full;   // panel_px_w x panel_px_h
    IOSurfaceRef small;  // panel_pt_w x panel_pt_h
    void *accel;         // IOSurfaceAcceleratorRef or NULL
    uint8_t *rot;        // rotated view-space buffer (when rot_q != 0)
    size_t rot_bpr;
    int sw, sh;          // small surface size (points)
    uint8_t *rotpx;      // full view-space buffer at native px (region path, lazy)
    size_t rotpx_bpr;
    int rotpx_w, rotpx_h;
};

static double now_ms(void) {
    static mach_timebase_info_data_t tb;
    if (!tb.denom) mach_timebase_info(&tb);
    return (double)mach_absolute_time() * tb.numer / tb.denom / 1e6;
}

static IOSurfaceRef make_surface(int w, int h) {
    size_t bpr = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, (size_t)w * 4);
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CFPropertyListRef csPlist = CGColorSpaceCopyPropertyList(cs);
    CGColorSpaceRelease(cs);
    NSDictionary *props = @{
        (__bridge NSString *)kIOSurfaceWidth : @(w),
        (__bridge NSString *)kIOSurfaceHeight : @(h),
        (__bridge NSString *)kIOSurfaceBytesPerElement : @4,
        (__bridge NSString *)kIOSurfaceBytesPerRow : @(bpr),
        (__bridge NSString *)kIOSurfaceAllocSize : @(bpr * (size_t)h),
        (__bridge NSString *)kIOSurfacePixelFormat : @(BGRA_FOURCC),
        (__bridge NSString *)kIOSurfaceColorSpace : CFBridgingRelease(csPlist),
    };
    return IOSurfaceCreate((__bridge CFDictionaryRef)props);
}

ipc_capturer *ipc_capturer_create(const ipc_geometry *g, bool allow_accel) {
    ipc_capturer *c = calloc(1, sizeof(*c));
    c->g = *g;
    c->sw = (int)lround(g->panel_pt_w);
    c->sh = (int)lround(g->panel_pt_h);
    c->full = make_surface(g->panel_px_w, g->panel_px_h);
    c->small = make_surface(c->sw, c->sh);
    if (!c->full || !c->small) {
        ipc_capturer_destroy(c);
        return NULL;
    }
    if (allow_accel && SPI.IOSurfaceAcceleratorCreate && SPI.IOSurfaceAcceleratorTransferSurface) {
        if (SPI.IOSurfaceAcceleratorCreate(kCFAllocatorDefault, NULL, &c->accel) != kIOReturnSuccess)
            c->accel = NULL;
    }
    if (g->rot_q & 3) {
        int rw = (g->rot_q & 1) ? c->sh : c->sw;
        int rh = (g->rot_q & 1) ? c->sw : c->sh;
        c->rot_bpr = (size_t)rw * 4;
        c->rot = malloc(c->rot_bpr * (size_t)rh);
    }
    return c;
}

void ipc_capturer_destroy(ipc_capturer *c) {
    if (!c) return;
    if (c->full) CFRelease(c->full);
    if (c->small) CFRelease(c->small);
    if (c->accel) CFRelease(c->accel);
    free(c->rot);
    free(c->rotpx);
    free(c);
}

static vImage_Buffer surface_buffer(IOSurfaceRef s) {
    vImage_Buffer b = {
        .data = IOSurfaceGetBaseAddress(s),
        .width = IOSurfaceGetWidth(s),
        .height = IOSurfaceGetHeight(s),
        .rowBytes = IOSurfaceGetBytesPerRow(s),
    };
    return b;
}

// Sparse scan: true if every sampled pixel's RGB is zero.
static bool looks_blank(const vImage_Buffer *b) {
    const uint8_t *base = b->data;
    for (size_t y = 0; y < b->height; y += 16) {
        const uint32_t *row = (const uint32_t *)(base + y * b->rowBytes);
        for (size_t x = 0; x < b->width; x += 16)
            if (row[x] & 0x00FFFFFFu) return false;
    }
    return true;
}

static NSData *encode_jpeg(const vImage_Buffer *b, double quality) {
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGDataProviderRef dp = CGDataProviderCreateWithData(NULL, b->data, b->rowBytes * b->height, NULL);
    // BGRA in memory == 32-bit little-endian xRGB.
    CGImageRef img = CGImageCreate(b->width, b->height, 8, 32, b->rowBytes, cs,
                                   kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst, dp, NULL,
                                   false, kCGRenderingIntentDefault);
    NSMutableData *out = [NSMutableData data];
    CGImageDestinationRef dst =
        CGImageDestinationCreateWithData((__bridge CFMutableDataRef)out, CFSTR("public.jpeg"), 1, NULL);
    NSDictionary *opts = @{(__bridge NSString *)kCGImageDestinationLossyCompressionQuality : @(quality)};
    CGImageDestinationAddImage(dst, img, (__bridge CFDictionaryRef)opts);
    bool ok = CGImageDestinationFinalize(dst);
    CFRelease(dst);
    CGImageRelease(img);
    CGDataProviderRelease(dp);
    CGColorSpaceRelease(cs);
    return ok ? out : nil;
}

NSData *ipc_capture_jpeg(ipc_capturer *c, double quality, ipc_shot_stats *st, NSString **err) {
    memset(st, 0, sizeof(*st));
    double t0 = now_ms();

    // 1. Render the composited main display ("LCD") into the full-size surface.
    SPI.CARenderServerRenderDisplay(0, CFSTR("LCD"), c->full, 0, 0);
    double t1 = now_ms();

    // 2. Downscale pixels -> points.
    bool scaled = false;
    if (c->accel) {
        IOReturn r = SPI.IOSurfaceAcceleratorTransferSurface(c->accel, c->full, c->small, NULL, NULL, NULL, NULL);
        scaled = (r == kIOReturnSuccess);
        st->used_accel = scaled;
    }
    IOSurfaceLock(c->small, 0, NULL);
    vImage_Buffer small = surface_buffer(c->small);
    if (!scaled) {
        IOSurfaceLock(c->full, kIOSurfaceLockReadOnly, NULL);
        vImage_Buffer full = surface_buffer(c->full);
        vImage_Error ve = vImageScale_ARGB8888(&full, &small, NULL, kvImageNoFlags);
        IOSurfaceUnlock(c->full, kIOSurfaceLockReadOnly, NULL);
        if (ve != kvImageNoError) {
            IOSurfaceUnlock(c->small, 0, NULL);
            if (err) *err = [NSString stringWithFormat:@"vImageScale failed: %ld", (long)ve];
            return nil;
        }
    }
    double t2 = now_ms();
    st->blank = looks_blank(&small);

    // 3. Rotate panel -> view orientation.
    vImage_Buffer view = small;
    if (c->g.rot_q & 3) {
        bool swap = (c->g.rot_q & 1) != 0;
        view.data = c->rot;
        view.width = swap ? small.height : small.width;
        view.height = swap ? small.width : small.height;
        view.rowBytes = c->rot_bpr;
        static const uint8_t kRot[4] = {kRotate0DegreesClockwise, kRotate90DegreesClockwise,
                                        kRotate180DegreesClockwise, kRotate270DegreesClockwise};
        const uint8_t black[4] = {0, 0, 0, 0xFF};
        vImage_Error ve = vImageRotate90_ARGB8888(&small, &view, kRot[c->g.rot_q & 3], black, kvImageNoFlags);
        if (ve != kvImageNoError) {
            IOSurfaceUnlock(c->small, 0, NULL);
            if (err) *err = [NSString stringWithFormat:@"vImageRotate90 failed: %ld", (long)ve];
            return nil;
        }
    }
    double t3 = now_ms();

    // 4. Encode.
    NSData *jpeg = encode_jpeg(&view, quality);
    IOSurfaceUnlock(c->small, 0, NULL);
    double t4 = now_ms();
    if (!jpeg) {
        if (err) *err = @"JPEG encode failed";
        return nil;
    }

    st->render_ms = t1 - t0;
    st->scale_ms = t2 - t1;
    st->rotate_ms = t3 - t2;
    st->encode_ms = t4 - t3;
    st->total_ms = t4 - t0;
    st->bytes = jpeg.length;
    st->out_w = (int)view.width;
    st->out_h = (int)view.height;
    return jpeg;
}

// Encode a tight BGRA buffer (rowBytes == width*4) as JPEG.
static NSData *encode_jpeg_tight(const uint8_t *data, int w, int h, double quality) {
    vImage_Buffer b = {.data = (void *)data, .width = (vImagePixelCount)w, .height = (vImagePixelCount)h, .rowBytes = (size_t)w * 4};
    return encode_jpeg(&b, quality);
}

static int clampi(int v, int lo, int hi) { return v < lo ? lo : (v > hi ? hi : v); }

NSData *ipc_capture_region_jpeg(ipc_capturer *c, CGRect roi, double quality, ipc_shot_stats *st, NSString **err) {
    memset(st, 0, sizeof(*st));
    double t0 = now_ms();

    SPI.CARenderServerRenderDisplay(0, CFSTR("LCD"), c->full, 0, 0);
    double t1 = now_ms();

    int scale = (int)lround(c->g.scale);
    if (scale < 1) scale = 1;
    int vpw = (int)lround(c->g.view_pt_w) * scale;  // view width in px
    int vph = (int)lround(c->g.view_pt_h) * scale;  // view height in px

    // Lazily (re)allocate the native-resolution rotation buffer.
    if (!c->rotpx || c->rotpx_w != vpw || c->rotpx_h != vph) {
        free(c->rotpx);
        c->rotpx_bpr = (size_t)vpw * 4;
        c->rotpx = malloc(c->rotpx_bpr * (size_t)vph);
        c->rotpx_w = vpw;
        c->rotpx_h = vph;
        if (!c->rotpx) {
            if (err) *err = @"region: allocation failed";
            return nil;
        }
    }

    IOSurfaceLock(c->full, kIOSurfaceLockReadOnly, NULL);
    vImage_Buffer full = surface_buffer(c->full);
    vImage_Buffer view = {.data = c->rotpx, .width = (vImagePixelCount)vpw, .height = (vImagePixelCount)vph, .rowBytes = c->rotpx_bpr};
    static const uint8_t kRot[4] = {kRotate0DegreesClockwise, kRotate90DegreesClockwise,
                                    kRotate180DegreesClockwise, kRotate270DegreesClockwise};
    const uint8_t black[4] = {0, 0, 0, 0xFF};
    vImage_Error ve = vImageRotate90_ARGB8888(&full, &view, kRot[c->g.rot_q & 3], black, kvImageNoFlags);
    IOSurfaceUnlock(c->full, kIOSurfaceLockReadOnly, NULL);
    double t2 = now_ms();
    if (ve != kvImageNoError) {
        if (err) *err = [NSString stringWithFormat:@"vImageRotate90 (region) failed: %ld", (long)ve];
        return nil;
    }
    st->blank = looks_blank(&view);

    // Crop in px, clamped inside the view.
    int cx = clampi((int)lround(roi.origin.x) * scale, 0, vpw - 1);
    int cy = clampi((int)lround(roi.origin.y) * scale, 0, vph - 1);
    int cw = clampi((int)lround(roi.size.width) * scale, 1, vpw - cx);
    int ch = clampi((int)lround(roi.size.height) * scale, 1, vph - cy);

    // Copy the crop into a compact buffer (avoids stride/length pitfalls in the encoder).
    uint8_t *compact = malloc((size_t)cw * ch * 4);
    if (!compact) {
        if (err) *err = @"region: crop allocation failed";
        return nil;
    }
    for (int row = 0; row < ch; row++)
        memcpy(compact + (size_t)row * cw * 4, c->rotpx + (size_t)(cy + row) * c->rotpx_bpr + (size_t)cx * 4, (size_t)cw * 4);
    double t3 = now_ms();

    NSData *jpeg = encode_jpeg_tight(compact, cw, ch, quality);
    free(compact);
    double t4 = now_ms();
    if (!jpeg) {
        if (err) *err = @"JPEG encode failed";
        return nil;
    }

    st->render_ms = t1 - t0;
    st->scale_ms = 0;
    st->rotate_ms = t2 - t1;
    st->encode_ms = t4 - t3;
    st->total_ms = t4 - t0;
    st->bytes = jpeg.length;
    st->out_w = cw;
    st->out_h = ch;
    return jpeg;
}

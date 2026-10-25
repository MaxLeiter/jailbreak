// capture.h - main-display capture -> view-oriented, point-sized JPEG.
//
// Pipeline (all buffers BGRA8888):
//   1. CARenderServerRenderDisplay("LCD") into a panel-sized IOSurface (pixels)
//   2. downscale to point resolution: IOSurfaceAccelerator (hardware scaler),
//      falling back to vImage if the accelerator is unavailable
//   3. rotate panel -> view orientation with vImage (90/180/270)
//   4. JPEG encode with ImageIO
#pragma once

#import <Foundation/Foundation.h>
#import "display.h"

typedef struct {
    double render_ms, scale_ms, rotate_ms, encode_ms, total_ms;
    size_t bytes;
    int out_w, out_h;
    bool used_accel;
    bool blank;  // every sampled pixel was black (display off, or capture denied)
} ipc_shot_stats;

typedef struct ipc_capturer ipc_capturer;

// Buffers are sized from g; recreate the capturer if the geometry changes.
ipc_capturer *ipc_capturer_create(const ipc_geometry *g, bool allow_accel);
void ipc_capturer_destroy(ipc_capturer *c);

// Returns JPEG bytes or nil (with a message in *err).
NSData *ipc_capture_jpeg(ipc_capturer *c, double quality, ipc_shot_stats *st, NSString **err);

// Crop `roi` (view-space points) and return it at NATIVE device resolution
// (points x scale), so small text stays sharp. Unlike ipc_capture_jpeg this
// skips the point downscale: it rotates the full panel-pixel frame to view
// orientation and copies out the crop. `roi` is clamped into the screen.
// Returns JPEG bytes or nil (with a message in *err).
NSData *ipc_capture_region_jpeg(ipc_capturer *c, CGRect roi, double quality, ipc_shot_stats *st, NSString **err);

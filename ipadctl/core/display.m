#import "display.h"
#import "spi.h"

#import <UIKit/UIKit.h>
#include <notify.h>
#include <string.h>

@interface IPCOrientationObserverSPI : NSObject  // FBSOrientationObserver
- (long)activeInterfaceOrientation;
- (void)invalidate;
@end

int ipc_rot_q_for_orientation(long o) {
    switch (o) {
    case 4: return 1;  // UIInterfaceOrientationLandscapeLeft: home button left, panel image turns 90 CW
    case 2: return 2;  // PortraitUpsideDown
    case 3: return 3;  // UIInterfaceOrientationLandscapeRight: home button right, 270 CW
    default: return 0; // Portrait / unknown
    }
}

const char *ipc_orientation_name(long o) {
    switch (o) {
    case 1: return "portrait";
    case 2: return "portraitUpsideDown";
    case 3: return "landscapeRight";
    case 4: return "landscapeLeft";
    default: return "unknown";
    }
}

static long read_orientation(void) {
    Class cls = NSClassFromString(@"FBSOrientationObserver");
    if (!cls) return 0;
    IPCOrientationObserverSPI *obs = [[cls alloc] init];
    if (!obs) return 0;
    long o = [obs activeInterfaceOrientation];
    [obs invalidate];
    return o;
}

bool ipc_geometry_get(ipc_geometry *g) {
    memset(g, 0, sizeof(*g));
    UIScreen *screen = [UIScreen mainScreen];
    CGRect nb = screen.nativeBounds;  // pixels, always panel orientation
    g->panel_px_w = (int)lround(nb.size.width);
    g->panel_px_h = (int)lround(nb.size.height);
    g->scale = screen.nativeScale > 0 ? screen.nativeScale : screen.scale;
    if (g->scale <= 0) g->scale = 1;
    g->panel_pt_w = g->panel_px_w / g->scale;
    g->panel_pt_h = g->panel_px_h / g->scale;

    g->orientation = read_orientation();
    g->rot_q = ipc_rot_q_for_orientation(g->orientation);
    bool swap = (g->rot_q & 1) != 0;
    g->view_pt_w = swap ? g->panel_pt_h : g->panel_pt_w;
    g->view_pt_h = swap ? g->panel_pt_w : g->panel_pt_h;
    return g->orientation >= 1 && g->orientation <= 4;
}

CGPoint ipc_view_to_panel_unit(const ipc_geometry *g, CGPoint v) {
    // Clamp into the view so a stray coordinate can never land off-glass.
    double x = fmin(fmax(v.x, 0), g->view_pt_w);
    double y = fmin(fmax(v.y, 0), g->view_pt_h);
    double W = g->panel_pt_w, H = g->panel_pt_h;
    double px, py;
    switch (g->rot_q & 3) {
    case 1: px = y;     py = H - x; break;  // view = panel rotated 90 CW
    case 2: px = W - x; py = H - y; break;
    case 3: px = W - y; py = x;     break;  // view = panel rotated 270 CW
    default: px = x;    py = y;     break;
    }
    return CGPointMake(px / W, py / H);
}

static int notify_state(const char *name) {
    int token = 0;
    if (notify_register_check(name, &token) != NOTIFY_STATUS_OK) return -1;
    uint64_t state = 0;
    int rc = notify_get_state(token, &state);
    notify_cancel(token);
    return rc == NOTIFY_STATUS_OK ? (int)state : -1;
}

void ipc_foreground_get(ipc_foreground *f) {
    memset(f, 0, sizeof(*f));
    f->lockstate = notify_state("com.apple.springboard.lockstate");
    f->blanked = notify_state("com.apple.springboard.hasBlankedScreen");

    if (SPI.SBSCopyFrontmostApplicationDisplayIdentifier) {
        CFStringRef bid = SPI.SBSCopyFrontmostApplicationDisplayIdentifier();
        f->frontmost_ok = true;
        if (bid) {
            CFStringGetCString(bid, f->frontmost, sizeof(f->frontmost), kCFStringEncodingUTF8);
            CFRelease(bid);
        } else {
            // NULL means no application scene is frontmost: home screen (or lock screen).
            strlcpy(f->frontmost, "com.apple.springboard", sizeof(f->frontmost));
        }
    }
}

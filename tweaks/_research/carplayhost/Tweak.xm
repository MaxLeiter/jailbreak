// carplayhost — a macOS-style window manager for the iPad, injected into SpringBoard.
// Each app runs in a floating, movable, resizable window hosting its LIVE scene on the
// iPad's own screen. On top of that:
//   * a floating DOCK (summoned by an AssistiveTouch-style button) to spawn windows,
//   * drag-to-edge SNAPPING with a live translucent zone preview (halves + quadrants),
//   * one-tap TILE to arrange the open windows into a grid.
// Scene-hosting recipe adapted from EthanArbuckle/carplay-cast (setupLiveAppView).
// All risky work is gated behind runtime triggers (never load-time) and wrapped in @try
// so a bug can't boot-loop SpringBoard on this daily-driver device.

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>

#define getIvar(o, i) [o valueForKey:i]
#define setIvar(o, i, v) [o setValue:v forKey:i]
#define objcInvoke(a, b) ((id (*)(id, SEL))objc_msgSend)(a, NSSelectorFromString(b))
#define objcInvoke_1(a, b, c) ((id (*)(id, SEL, typeof(c)))objc_msgSend)(a, NSSelectorFromString(b), c)
#define objcInvoke_2(a, b, c, d) ((id (*)(id, SEL, typeof(c), typeof(d)))objc_msgSend)(a, NSSelectorFromString(b), c, d)
#define objcInvoke_3(a, b, c, d, e) ((id (*)(id, SEL, typeof(c), typeof(d), typeof(e)))objc_msgSend)(a, NSSelectorFromString(b), c, d, e)

@class CPHPanel;
@class CPHChromeVC;
static NSMutableArray<CPHPanel *> *gPanels;     // every live window
static CGFloat gTopLevel = 100000;              // window-level cursor; bump on focus
static int gCascade = 0;                        // initial-placement offset counter
static NSMutableDictionary<NSString *, NSNumber *> *gLastHost; // per-bid debounce
static UIWindow *gChrome;                        // always-on-top passthrough window (dock + button + snap preview)
static NSArray<NSDictionary *> *gAppEntries;     // cached installed-app list for the dock
static const CGFloat kChromeLevel = 1000000000;  // dock/button above any app window
static BOOL gEnabled = YES;                       // master on/off (Settings toggle); read at %ctor

// Master switch — read the Settings toggle. Default ON when unset. Read the plist directly so
// SpringBoard's prefs cache can't stale it (applies on respring).
static void cphReadPrefs(void) {
    gEnabled = YES;
    @try {
        for (NSString *p in @[ @"/var/mobile/Library/Preferences/com.max.mosaic.plist",
                               @"/var/jb/var/mobile/Library/Preferences/com.max.mosaic.plist" ]) {
            NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
            if (d) { id v = d[@"enabled"]; gEnabled = (v == nil) ? YES : [v boolValue]; break; }
        }
    } @catch (__unused NSException *e) { gEnabled = YES; }
}

// Forward decls so chrome and panels can call into each other regardless of file order.
static void hostApp(NSString *bid);
static void dismissAll(void);
static void ensureChrome(void);
static void cphShowSnap(CGRect r);
static void cphHideSnap(void);
static void cphGhost(UIImage *icon, CGPoint p, BOOL show);
static void openInZone(NSString *bid, int zone);
static NSString *bidForIconView(UIView *iconView);
static NSArray<NSString *> *realDockBundleIDs(void);   // the user's actual dock apps, in order
static void launchAppNormally(NSString *bid);          // launch fullscreen, outside the WM
static void updateFocusStates(void);                   // brighten the front window, dim the rest

static void hlog(NSString *s) {
    NSLog(@"[carplayhost] %@", s);
    NSString *l = [s stringByAppendingString:@"\n"];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:@"/tmp/carplayhost.log"];
    if (!fh) { [l writeToFile:@"/tmp/carplayhost.log" atomically:YES encoding:NSUTF8StringEncoding error:nil]; return; }
    [fh seekToEndOfFile]; [fh writeData:[l dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile];
}

static UIWindowScene *foregroundWindowScene(void) {
    UIWindowScene *scene = nil;
    for (UIScene *s in [[[UIApplication sharedApplication] connectedScenes] allObjects]) {
        if ([s isKindOfClass:[UIWindowScene class]]) {
            scene = (UIWindowScene *)s;
            if (s.activationState == UISceneActivationStateForegroundActive) break;
        }
    }
    return scene;
}

static CGSize sceneSizeFor(UIWindow *w) {
    UIWindowScene *scene = w.windowScene ?: foregroundWindowScene();
    return scene ? scene.coordinateSpace.bounds.size : [UIScreen mainScreen].bounds.size;
}

// ---- app icons + installed-app list (SpringBoard has full access to both) ----
static UIImage *iconForBid(NSString *bid) {
    SEL sel = NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:format:scale:");
    if (![UIImage respondsToSelector:sel]) return nil;
    CGFloat scale = [UIScreen mainScreen].scale;
    int fmts[] = {2, 8, 1, 0, 3};
    for (int i = 0; i < 5; i++) {
        UIImage *img = ((UIImage *(*)(Class, SEL, id, int, CGFloat))objc_msgSend)([UIImage class], sel, bid, fmts[i], scale);
        if (img && img.size.width > 0) return img;
    }
    return nil;
}

static NSArray<NSDictionary *> *installedApps(void) {
    NSMutableArray *out = [NSMutableArray array];
    @try {
        id ws = objcInvoke(objc_getClass("LSApplicationWorkspace"), @"defaultWorkspace");
        NSArray *all = objcInvoke(ws, @"allApplications");
        for (id proxy in all) {
            @try {
                NSString *bid = objcInvoke(proxy, @"bundleIdentifier");
                if (![bid isKindOfClass:[NSString class]] || !bid.length) continue;
                NSString *type = objcInvoke(proxy, @"applicationType");
                if ([type isKindOfClass:[NSString class]] &&
                    ([type isEqualToString:@"Internal"] || [type isEqualToString:@"Hidden"])) continue;
                @try {
                    id tags = objcInvoke(proxy, @"appTags");
                    if ([tags isKindOfClass:[NSArray class]] && [tags containsObject:@"hidden"]) continue;
                } @catch (__unused NSException *e) {}
                if (!iconForBid(bid)) continue;   // no icon ⇒ daemon/agent, not a launchable app
                NSString *name = objcInvoke(proxy, @"localizedName");
                if (![name isKindOfClass:[NSString class]]) name = bid;
                [out addObject:@{ @"bid": bid, @"name": name }];
            } @catch (__unused NSException *e) {}
        }
    } @catch (NSException *e) { hlog([NSString stringWithFormat:@"installedApps exc %@", e.reason]); }
    [out sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]];
    }];
    return out;
}

// ===========================================================================
// Snapping geometry — drag a window near an edge/corner to tile it.
// ===========================================================================
typedef NS_ENUM(int, CPHSnapZone) {
    CPHSnapNone, CPHSnapLeft, CPHSnapRight, CPHSnapMax,
    CPHSnapTL, CPHSnapTR, CPHSnapBL, CPHSnapBR
};

static CPHSnapZone snapZoneForPoint(CGPoint p, CGSize S) {
    BOOL L = p.x < S.width * 0.10, R = p.x > S.width * 0.90;
    BOOL T = p.y < S.height * 0.12, B = p.y > S.height * 0.88;
    if (T && L) return CPHSnapTL;
    if (T && R) return CPHSnapTR;
    if (B && L) return CPHSnapBL;
    if (B && R) return CPHSnapBR;
    if (L) return CPHSnapLeft;
    if (R) return CPHSnapRight;
    if (T) return CPHSnapMax;
    return CPHSnapNone;     // bottom-center left free (the dock lives there)
}

static CGRect rectForZone(CPHSnapZone z, CGSize S) {
    CGFloat w = S.width, h = S.height, hw = w / 2, hh = h / 2;
    switch (z) {
        case CPHSnapLeft:  return CGRectMake(0, 0, hw, h);
        case CPHSnapRight: return CGRectMake(hw, 0, hw, h);
        case CPHSnapMax:   return CGRectMake(0, 0, w, h);
        case CPHSnapTL:    return CGRectMake(0, 0, hw, hh);
        case CPHSnapTR:    return CGRectMake(hw, 0, hw, hh);
        case CPHSnapBL:    return CGRectMake(0, hh, hw, hh);
        case CPHSnapBR:    return CGRectMake(hw, hh, hw, hh);
        default:           return CGRectZero;
    }
}

// Elastic edge resistance — a window dragged past [lo,hi] follows the finger at 45% (rubber-band).
static CGFloat cphRubberband(CGFloat pos, CGFloat lo, CGFloat hi) {
    if (pos < lo) return lo - (lo - pos) * 0.45;
    if (pos > hi) return hi + (pos - hi) * 0.45;
    return pos;
}

// ===========================================================================
// CPHPanel — one floating, draggable, resizable window hosting one app's scene.
// ===========================================================================
@interface CPHPanel : NSObject <UIGestureRecognizerDelegate>
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) id avc;            // SBAppViewController hosting the live scene
@property (nonatomic, strong) id entity;         // SBDeviceApplicationSceneEntity (kept for re-delivery)
@property (nonatomic, copy)   NSString *bid;
@property (nonatomic, strong) UIView *content;   // app scene lives here, below the title bar
@property (nonatomic, strong) UIViewController *rootVC;  // window root → UIKit applies device orientation
@property (nonatomic, assign) CGRect restoreFrame;
@property (nonatomic, assign) BOOL maximized;
@property (nonatomic, assign) BOOL minimized;
@property (nonatomic, assign) CGPoint dragStartOrigin;   // window origin when a drag began
@property (nonatomic, strong) UIView *chromeBar;         // title bar — fades in on touch, out when idle
@property (nonatomic, strong) UIView *grip;              // resize touch zone (always live)
@property (nonatomic, strong) UIView *gripHandle;        // its visible handle (fades with chrome)
@property (nonatomic, strong) UIView *grabber;           // at-rest drag affordance (top-center pill)
@property (nonatomic, assign) BOOL chromeRevealed;
@property (nonatomic, strong) NSTimer *chromeHideTimer;
@property (nonatomic, strong) UIView *dimOverlay;        // subtle dim when this window is inactive
- (instancetype)initWithBid:(NSString *)bid app:(id)app scene:(UIWindowScene *)scene initialFrame:(CGRect)frame;
- (void)bringToFront;
- (void)applyFocusState:(BOOL)focused;
- (void)deliverSceneSize;    // re-push current bounds to the app process so it re-lays-out
- (void)restoreFromMinimize;
- (void)snapToZone:(CPHSnapZone)z;
- (void)teardown;
@end

static BOOL isOurAVC(id avc) {
    for (CPHPanel *p in gPanels) if (p.avc == avc) return YES;
    return NO;
}
static CPHPanel *panelForBid(NSString *bid) {
    for (CPHPanel *p in gPanels) if ([p.bid isEqualToString:bid]) return p;
    return nil;
}

// ===========================================================================
// Chrome — an always-on-top passthrough window carrying the dock, the floating
// summon button, and the snap-zone preview. Touches on empty areas fall through
// to the windows below (AssistiveTouch pattern).
// ===========================================================================
@interface CPHPassthroughView : UIView
@end
@implementation CPHPassthroughView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *v = [super hitTest:point withEvent:event];
    return (v == self) ? nil : v;     // empty chrome → pass through; real control → capture
}
@end

// CRITICAL: a UIWindow returns *itself* from hitTest when none of its subviews are hit, so
// overriding only the root view leaves the window swallowing every touch over empty space.
// The window must pass through too: nil when the hit is the window or its (passthrough) root.
@interface CPHChromeWindow : UIWindow
@end
@implementation CPHChromeWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *v = [super hitTest:point withEvent:event];
    if (v == self || v == self.rootViewController.view) return nil;   // empty → fall through to panels/home
    return v;                                                          // real control → capture
}
@end

@interface CPHChromeVC : UIViewController
@property (nonatomic, strong) UIVisualEffectView *dock;
@property (nonatomic, strong) UIVisualEffectView *toggle;
@property (nonatomic, strong) UIView *snapPreview;
@property (nonatomic, strong) UIScrollView *appScroll;
@property (nonatomic, strong) UIView *scrim;
@property (nonatomic, strong) UIImageView *dragGhost;   // icon ghost while dragging from the dock
@property (nonatomic, assign) BOOL dockShown;
@property (nonatomic, strong) UIVisualEffectView *realDock;       // swipe-up mirror of the iOS dock
@property (nonatomic, strong) UIView *realDockScrim;
@property (nonatomic, strong) NSArray<NSString *> *realDockBids;
@property (nonatomic, strong) NSArray<UIButton *> *realDockButtons;
@property (nonatomic, assign) BOOL realDockShown;
- (void)toggleTapped;
- (void)revealRealDock;
@end

static CPHChromeVC *chromeVC(void) {
    return [gChrome.rootViewController isKindOfClass:[CPHChromeVC class]] ? (CPHChromeVC *)gChrome.rootViewController : nil;
}

static void cphShowSnap(CGRect r) {
    CPHChromeVC *vc = chromeVC();
    if (!vc) return;
    UIView *p = vc.snapPreview;
    [vc.view bringSubviewToFront:p];
    if (p.alpha < 0.01) p.frame = r;     // jump (don't slide) when first appearing
    [UIView animateWithDuration:0.12 animations:^{ p.frame = r; p.alpha = 1; }];
}
static void cphHideSnap(void) {
    CPHChromeVC *vc = chromeVC();
    if (!vc) return;
    [UIView animateWithDuration:0.12 animations:^{ vc.snapPreview.alpha = 0; }];
}

// A floating icon "ghost" that follows the finger while dragging an app off the dock.
static void cphGhost(UIImage *icon, CGPoint p, BOOL show) {
    CPHChromeVC *vc = chromeVC();
    if (!vc) return;
    if (!vc.dragGhost) {
        UIImageView *g = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, 60, 60)];
        g.contentMode = UIViewContentModeScaleAspectFit;
        g.layer.cornerRadius = 13; g.layer.masksToBounds = YES;
        g.layer.shadowColor = [UIColor blackColor].CGColor; g.layer.shadowOpacity = 0.4; g.layer.shadowRadius = 8;
        g.alpha = 0; g.userInteractionEnabled = NO;
        [vc.view addSubview:g];
        vc.dragGhost = g;
    }
    UIImageView *g = vc.dragGhost;
    [vc.view bringSubviewToFront:g];
    if (icon) g.image = icon;
    g.center = p;
    if (show && g.alpha < 0.9) [UIView animateWithDuration:0.12 animations:^{ g.alpha = 0.92; }];
    else if (!show) [UIView animateWithDuration:0.14 animations:^{ g.alpha = 0; }];
}

// Window root VC: makes UIKit rotate the panel (chrome + hosted app) to the device's
// current orientation, and gives the hosted SBAppViewController a parent so its scene
// inherits the right interface orientation. Supports all orientations = follow device.
@interface CPHRootVC : UIViewController
@end
@implementation CPHRootVC
- (BOOL)prefersStatusBarHidden { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAll; }
- (BOOL)shouldAutorotate { return YES; }
@end

@implementation CPHPanel

- (instancetype)initWithBid:(NSString *)bid app:(id)app scene:(UIWindowScene *)scene initialFrame:(CGRect)frame {
    if (!(self = [super init])) return nil;
    self.bid = bid;
    @try {
        UIWindow *w = scene ? [[UIWindow alloc] initWithWindowScene:scene]
                            : [[UIWindow alloc] initWithFrame:frame];
        w.frame = frame;
        w.windowLevel = (gTopLevel += 1);
        w.backgroundColor = [UIColor clearColor];
        w.clipsToBounds = NO;
        // macOS-style drop shadow: the window itself doesn't clip, so the shadow shows
        // around the rounded body view (which does the clipping).
        w.layer.shadowColor = [UIColor blackColor].CGColor;
        w.layer.shadowOpacity = 0.45;
        w.layer.shadowRadius = 18;
        w.layer.shadowOffset = CGSizeMake(0, 8);
        self.window = w;

        CPHRootVC *rootVC = [CPHRootVC new];
        self.rootVC = rootVC;
        w.rootViewController = rootVC;          // UIKit rotates the panel to the device orientation
        UIView *root = rootVC.view;
        root.frame = w.bounds;
        root.backgroundColor = [UIColor blackColor];
        root.layer.cornerRadius = 14;           // rounded window body (squared off when maximized)
        root.layer.masksToBounds = YES;
        root.layer.borderWidth = 1.0;
        root.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.16].CGColor;

        CGFloat th = 38;
        // --- content (hosted app scene) fills the WHOLE window; chrome floats over it ---
        UIView *content = [[UIView alloc] initWithFrame:w.bounds];
        content.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        content.backgroundColor = [UIColor blackColor];
        content.clipsToBounds = YES;
        [root addSubview:content];
        self.content = content;

        // Tapping the TOP of the window reveals the chrome (without stealing the tap from the app).
        UITapGestureRecognizer *topTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(topTapped:)];
        topTap.cancelsTouchesInView = NO;
        topTap.delaysTouchesBegan = NO;
        topTap.delaysTouchesEnded = NO;
        topTap.delegate = self;
        [content addGestureRecognizer:topTap];

        if (![self hostSceneForApp:app intoView:content bid:bid]) { [self teardown]; return nil; }

        // --- chrome bar: translucent blur + traffic lights + title; HIDDEN at rest (alpha 0),
        //     fades in on touch and back out when idle (hybrid). Overlays the top of the app. ---
        UIVisualEffectView *bar = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterialDark]];
        bar.frame = CGRectMake(0, 0, w.bounds.size.width, th);
        bar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        bar.alpha = 0;
        [root addSubview:bar];
        self.chromeBar = bar;
        UIView *barc = bar.contentView;
        [barc addSubview:[self trafficLight:[UIColor colorWithRed:1.00 green:0.37 blue:0.34 alpha:1] action:@selector(closeTapped)    x:4  symbol:@"×"]];  // red ×
        [barc addSubview:[self trafficLight:[UIColor colorWithRed:1.00 green:0.74 blue:0.18 alpha:1] action:@selector(minimizeTapped) x:46 symbol:@"−"]];  // yellow −
        [barc addSubview:[self trafficLight:[UIColor colorWithRed:0.24 green:0.79 blue:0.33 alpha:1] action:@selector(toggleMaximize) x:88 symbol:@"+"]];        // green +
        UILabel *name = [[UILabel alloc] initWithFrame:CGRectMake(144, 0, w.bounds.size.width - 288, th)];
        name.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        name.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
        name.textColor = [UIColor colorWithWhite:1 alpha:0.92];
        name.textAlignment = NSTextAlignmentCenter;
        @try {
            id sbapp = objcInvoke_1(objcInvoke(objc_getClass("SBApplicationController"), @"sharedInstance"), @"applicationWithBundleIdentifier:", bid);
            id dn = sbapp ? objcInvoke(sbapp, @"displayName") : nil;
            name.text = [dn isKindOfClass:[NSString class]] ? dn : bid;
        } @catch (__unused NSException *e) { name.text = bid; }
        [barc addSubview:name];
        [bar addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dragTitle:)]];
        UITapGestureRecognizer *focus = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(focusTapped)];
        [bar addGestureRecognizer:focus];
        UITapGestureRecognizer *dbl = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(popOut)];
        dbl.numberOfTapsRequired = 2;
        [bar addGestureRecognizer:dbl];
        [focus requireGestureRecognizerToFail:dbl];

        // --- grabber: small always-present pill at top-center — the at-rest drag/reveal handle ---
        UIView *grabber = [[UIView alloc] initWithFrame:CGRectMake((w.bounds.size.width - 88) / 2, 0, 88, 28)];
        grabber.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
        grabber.alpha = 0.32;
        UIView *pill = [[UIView alloc] initWithFrame:CGRectMake((88 - 44) / 2, 11, 44, 5)];
        pill.backgroundColor = [UIColor colorWithWhite:1 alpha:0.9];
        pill.layer.cornerRadius = 2.5;
        pill.userInteractionEnabled = NO;
        [grabber addSubview:pill];
        [grabber addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dragTitle:)]];
        [grabber addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(grabberTapped)]];
        [root addSubview:grabber];
        self.grabber = grabber;

        // --- resize grip: ALWAYS grabbable (transparent touch zone, alpha 1) so you can resize
        //     even at rest/fullscreen; only the visible handle fades with the chrome. ---
        UIView *grip = [[UIView alloc] initWithFrame:CGRectMake(w.bounds.size.width - 52, w.bounds.size.height - 52, 44, 44)];
        grip.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleTopMargin;
        UIView *handle = [[UIView alloc] initWithFrame:CGRectMake(14, 14, 26, 26)];
        handle.backgroundColor = [UIColor colorWithWhite:0.9 alpha:0.30];
        handle.layer.cornerRadius = 7;
        handle.alpha = 0.22;                          // faint at rest; brightens with the chrome
        handle.userInteractionEnabled = NO;
        [grip addSubview:handle];
        [root addSubview:grip];
        self.grip = grip;
        self.gripHandle = handle;
        UIPanGestureRecognizer *rz = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dragResize:)];
        [grip addGestureRecognizer:rz];

        // Inactive-window dim — topmost, non-interactive; 0 when focused, subtle when not.
        UIView *dim = [[UIView alloc] initWithFrame:root.bounds];
        dim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        dim.backgroundColor = [UIColor blackColor];
        dim.alpha = 0;
        dim.userInteractionEnabled = NO;
        [root addSubview:dim];
        self.dimOverlay = dim;

        // Swipe up from the bottom screen edge (over a fullscreen window) → reveal the dock,
        // mimicking the native "swipe up for dock". Only fires when the window reaches the edge.
        UIScreenEdgePanGestureRecognizer *edge = [[UIScreenEdgePanGestureRecognizer alloc] initWithTarget:self action:@selector(bottomEdgeSwipe:)];
        edge.edges = UIRectEdgeBottom;
        [root addGestureRecognizer:edge];

        w.hidden = NO;
        [w makeKeyAndVisible];
        // open transition: scale + fade the content in
        root.transform = CGAffineTransformMakeScale(0.94, 0.94);
        w.alpha = 0;
        [UIView animateWithDuration:0.26 delay:0 usingSpringWithDamping:0.82 initialSpringVelocity:0.5 options:0 animations:^{
            root.transform = CGAffineTransformIdentity;
            w.alpha = 1;
        } completion:nil];
        [self revealChrome];   // show the controls briefly on open, then auto-hide
        hlog([NSString stringWithFormat:@"panel up %@ frame=%@", bid, NSStringFromCGRect(frame)]);
        // Re-push bounds so the app re-lays-out to our size. A cold-launching app isn't ready at
        // 0.45s — if we only push once, its scene stays BLACK until a manual resize. So nudge a
        // few times as it finishes launching (cheap; a no-op once it's already rendered).
        __weak CPHPanel *weakSelf = self;
        for (NSNumber *delay in @[ @0.4, @0.9, @1.6, @2.6, @4.0, @6.0 ]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [weakSelf deliverSceneSize];
            });
        }
    } @catch (NSException *e) {
        hlog([NSString stringWithFormat:@"panel EXC %@ -- %@", [e name], [e reason]]);
        [self teardown];
        return nil;
    }
    return self;
}

// Scene-hosting recipe (iOS 17.6.1). Returns YES on success.
- (BOOL)hostSceneForApp:(id)app intoView:(UIView *)container bid:(NSString *)bid {
    id dsm = objcInvoke(objc_getClass("SBSceneManagerCoordinator"), @"mainDisplaySceneManager");
    id displayIdentity = objcInvoke(dsm, @"displayIdentity");
    id entity = objcInvoke_3(objc_getClass("SBDeviceApplicationSceneEntity"),
                             @"defaultEntityWithApplication:sceneHandleProvider:displayIdentity:", app, dsm, displayIdentity);
    if (!entity) { hlog(@"no scene entity"); return NO; }

    self.entity = entity;
    id avc = objcInvoke_2([objc_getClass("SBAppViewController") alloc], @"initWithIdentifier:andApplicationSceneEntity:", bid, entity);
    self.avc = avc;
    if (self.rootVC) [self.rootVC addChildViewController:(UIViewController *)avc]; // parent → correct interface orientation
    objcInvoke_1(avc, @"setIgnoresOcclusions:", (BOOL)0);
    objcInvoke_1(avc, @"_setCurrentMode:", (long long)2);
    @try { objcInvoke(getIvar(avc, @"_activationSettings"), @"clearActivationSettings"); } @catch (__unused NSException *e) {}

    id tx = objcInvoke_2(avc, @"_createSceneUpdateTransactionForApplicationSceneEntity:deliveringActions:", entity, (BOOL)1);
    id txs = getIvar(avc, @"_activeTransitions"); // NSMutableSet on 17.6
    if (tx) objcInvoke_1(txs, @"addObject:", tx);
    if (tx) objcInvoke(tx, @"begin");
    objcInvoke(avc, @"_createSceneViewController");
    objcInvoke_3(avc, @"setDisplayMode:animationFactory:completion:", (long long)4, (id)nil, (id)nil); // 4 = LiveContent

    UIView *avcView = (UIView *)objcInvoke(avc, @"view");
    avcView.backgroundColor = [UIColor clearColor];
    avcView.frame = container.bounds;
    avcView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [container addSubview:avcView];
    if (self.rootVC) [(UIViewController *)avc didMoveToParentViewController:self.rootVC];
    return YES;
}

- (void)bottomEdgeSwipe:(UIScreenEdgePanGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    CPHChromeVC *vc = chromeVC();
    if (vc) { hlog(@"bottom-edge swipe → reveal real dock"); [vc revealRealDock]; }
}
- (void)bringToFront { self.window.windowLevel = (gTopLevel += 1); updateFocusStates(); }

// macOS active/inactive look: the focused window is bright with a deep shadow; others dim + flatten.
- (void)applyFocusState:(BOOL)focused {
    [UIView animateWithDuration:0.2 animations:^{ self.dimOverlay.alpha = focused ? 0 : 0.14; }];
    UIWindow *w = self.window;
    if (!w) return;
    [CATransaction begin];
    [CATransaction setAnimationDuration:0.2];
    w.layer.shadowRadius  = focused ? 18 : 9;
    w.layer.shadowOpacity = focused ? 0.45 : 0.28;
    [CATransaction commit];
}
- (void)focusTapped { [self bringToFront]; [self revealChrome]; }
- (void)grabberTapped { [self bringToFront]; [self revealChrome]; }
// A tap anywhere along the top edge of the window reveals the chrome (the app still gets the tap).
- (void)topTapped:(UITapGestureRecognizer *)g {
    if ([g locationInView:self.window].y <= 46) { [self bringToFront]; [self revealChrome]; }
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)o { return YES; }

// Hybrid chrome: fade the bar + grip in on touch, hide the at-rest grabber; auto-hide when idle.
- (void)revealChrome {
    [self.chromeHideTimer invalidate];
    if (!self.chromeRevealed) {
        self.chromeRevealed = YES;
        hlog([NSString stringWithFormat:@"chrome reveal %@ (bar.alpha=%.2f)", self.bid, self.chromeBar.alpha]);
        [UIView animateWithDuration:0.2 animations:^{
            self.chromeBar.alpha = 1; self.gripHandle.alpha = 1; self.grabber.alpha = 0;
        }];
    }
    [self scheduleChromeHide];
}
- (void)scheduleChromeHide {
    [self.chromeHideTimer invalidate];
    self.chromeHideTimer = [NSTimer scheduledTimerWithTimeInterval:2.6 target:self
                                                          selector:@selector(hideChrome) userInfo:nil repeats:NO];
}
- (void)hideChrome {
    [self.chromeHideTimer invalidate]; self.chromeHideTimer = nil;
    self.chromeRevealed = NO;
    hlog([NSString stringWithFormat:@"chrome HIDE %@", self.bid]);
    [UIView animateWithDuration:0.3 animations:^{
        self.chromeBar.alpha = 0; self.gripHandle.alpha = 0.22; self.grabber.alpha = 0.32;
    }];
}
- (void)closeTapped {
    UIWindow *w = self.window;
    UIView *root = self.rootVC.view;
    if (!w || !root) { [self teardown]; return; }
    [UIView animateWithDuration:0.18 animations:^{
        root.transform = CGAffineTransformMakeScale(0.90, 0.90);
        w.alpha = 0;
    } completion:^(BOOL fin) { [self teardown]; }];
}
// The shrunk-toward-the-dock frame a window minimizes to (and restores from).
- (CGRect)minimizedFrameFor:(CGRect)frame {
    CGSize S = sceneSizeFor(self.window);
    CGFloat tw = MAX(60, frame.size.width * 0.18), th = MAX(44, frame.size.height * 0.18);
    return CGRectMake(S.width / 2 - tw / 2, S.height - th - 6, tw, th);
}

// Minimize: shrink toward the dock (bottom-center) and hide; restore animates it back.
// Restore is triggered by re-opening the app from the dock (hostApp → restoreFromMinimize).
- (void)minimizeTapped {
    if (self.minimized) return;
    self.minimized = YES;
    UIWindow *w = self.window;
    CGRect saved = w.frame;
    [self bringToFront];
    [UIView animateWithDuration:0.30 delay:0 options:UIViewAnimationOptionCurveEaseIn animations:^{
        w.frame = [self minimizedFrameFor:saved];
        w.alpha = 0.0;
    } completion:^(BOOL fin) {
        w.hidden = YES;
        w.alpha = 1.0;
        w.frame = saved;     // park at full size so restore animates back to the right place
    }];
}

- (void)restoreFromMinimize {
    self.minimized = NO;
    UIWindow *w = self.window;
    if (!w) return;
    CGRect dest = w.frame;     // parked full-size frame
    w.frame = [self minimizedFrameFor:dest];
    w.alpha = 0.0;
    w.hidden = NO;
    [self bringToFront];
    [UIView animateWithDuration:0.30 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        w.frame = dest;
        w.alpha = 1.0;
    } completion:^(BOOL fin) { [self deliverSceneSize]; }];
}

// macOS traffic-light button: a coloured dot in a touch-friendly 30pt tap target.
- (UIButton *)trafficLight:(UIColor *)color action:(SEL)action x:(CGFloat)x symbol:(NSString *)symbol {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.frame = CGRectMake(x, 0, 44, 38);                                 // ≥44pt tap target
    UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(14, 11, 17, 17)];
    dot.backgroundColor = color;
    dot.layer.cornerRadius = 8.5;
    dot.layer.borderWidth = 0.5;
    dot.layer.borderColor = [UIColor colorWithWhite:0 alpha:0.18].CGColor;
    dot.userInteractionEnabled = NO;
    UILabel *sym = [[UILabel alloc] initWithFrame:dot.bounds];          // macOS ×/−/+ glyph
    sym.text = symbol;
    sym.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBold];
    sym.textColor = [UIColor colorWithWhite:0 alpha:0.55];
    sym.textAlignment = NSTextAlignmentCenter;
    [dot addSubview:sym];
    [b addSubview:dot];
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

// Square off the rounded corners when the window fills the screen (else the desktop
// shows through the rounded corners at fullscreen).
- (void)setMaximized:(BOOL)maximized {
    _maximized = maximized;
    @try { self.rootVC.view.layer.cornerRadius = maximized ? 0 : 14; } @catch (__unused NSException *e) {}
}

// Re-deliver the panel's current bounds to the app process (settings-only update,
// deliveringActions:0) so the hosted app actually re-lays-out to the new size rather
// than just stretching its rendered layer. Wrapped — a settings diff can throw here.
- (void)deliverSceneSize {
    if (!self.avc || !self.entity) return;
    @try {
        UIView *v = (UIView *)objcInvoke(self.avc, @"view");
        [v setNeedsLayout]; [v layoutIfNeeded];
        id tx = objcInvoke_2(self.avc, @"_createSceneUpdateTransactionForApplicationSceneEntity:deliveringActions:", self.entity, (BOOL)0);
        if (tx) {
            id txs = getIvar(self.avc, @"_activeTransitions");
            objcInvoke_1(txs, @"addObject:", tx);
            objcInvoke(tx, @"begin");
        }
        // THE reflow fix: the host re-pins the scene to the full display (810×1080) on every
        // transaction, so push our actual content size into the scene settings AFTER, last write
        // wins → the app process re-lays-out for our window size instead of scaling a full screen.
        [self applySceneFrame:(CGRect){CGPointZero, self.content.bounds.size}];
    } @catch (NSException *e) { hlog([NSString stringWithFormat:@"deliverSceneSize exc: %@", e.reason]); }
}

// Force the hosted app's scene to OUR size so it actually reflows (not just scales). Reach the
// FBScene via the avc's scene handle, mutate its settings frame/bounds, and push the update.
- (void)applySceneFrame:(CGRect)f {
    @try {
        id sh = nil;
        @try { sh = getIvar(self.avc, @"_sceneHandle"); } @catch (__unused NSException *e) {}
        if (!sh) { @try { sh = objcInvoke(self.avc, @"sceneHandle"); } @catch (__unused NSException *e) {} }
        id scene = sh ? objcInvoke(sh, @"scene") : nil;
        if (!scene) { hlog(@"applySceneFrame: no scene"); return; }
        id cur = objcInvoke(scene, @"settings");
        id mut = objcInvoke(cur, @"mutableCopy");
        SEL setF = NSSelectorFromString(@"setFrame:");
        SEL setB = NSSelectorFromString(@"setBounds:");
        if ([mut respondsToSelector:setF]) ((void (*)(id, SEL, CGRect))objc_msgSend)(mut, setF, f);
        if ([mut respondsToSelector:setB]) ((void (*)(id, SEL, CGRect))objc_msgSend)(mut, setB, (CGRect){CGPointZero, f.size});
        SEL upd3 = NSSelectorFromString(@"updateSettings:withTransitionContext:completion:");
        SEL upd2 = NSSelectorFromString(@"updateSettings:withTransitionContext:");
        if ([scene respondsToSelector:upd3]) {
            ((void (*)(id, SEL, id, id, id))objc_msgSend)(scene, upd3, mut, nil, nil);
            hlog([NSString stringWithFormat:@"applySceneFrame %@ -> %@ (3)", self.bid, NSStringFromCGRect(f)]);
        } else if ([scene respondsToSelector:upd2]) {
            ((void (*)(id, SEL, id, id))objc_msgSend)(scene, upd2, mut, nil);
            hlog([NSString stringWithFormat:@"applySceneFrame %@ -> %@ (2)", self.bid, NSStringFromCGRect(f)]);
        } else {
            hlog([NSString stringWithFormat:@"applySceneFrame: scene %@ has no updateSettings", NSStringFromClass([scene class])]);
        }
    } @catch (NSException *e) { hlog([NSString stringWithFormat:@"applySceneFrame exc %@", e.reason]); }
}

// Lift the window when grabbed (scale up slightly + deepen the shadow), like Stage Manager.
- (void)applyLift:(BOOL)lifted {
    UIView *root = self.rootVC.view;
    UIWindow *w = self.window;
    if (!root || !w) return;
    [UIView animateWithDuration:0.24 delay:0 usingSpringWithDamping:0.75 initialSpringVelocity:0
                        options:UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionBeginFromCurrentState
                     animations:^{ root.transform = lifted ? CGAffineTransformMakeScale(1.025, 1.025) : CGAffineTransformIdentity; }
                     completion:nil];
    [CATransaction begin];
    [CATransaction setAnimationDuration:0.24];
    w.layer.shadowRadius   = lifted ? 34 : 18;
    w.layer.shadowOpacity  = lifted ? 0.55 : 0.45;
    w.layer.shadowOffset   = lifted ? CGSizeMake(0, 16) : CGSizeMake(0, 8);
    [CATransaction commit];
}

- (void)dragTitle:(UIPanGestureRecognizer *)g {
    CGSize S = sceneSizeFor(self.window);
    CGFloat keep = 80;   // keep at least this much of the window on-screen
    CGRect f = self.window.frame;
    CGFloat loX = keep - f.size.width, hiX = S.width - keep, loY = 0, hiY = S.height - keep;

    if (g.state == UIGestureRecognizerStateBegan) {
        [self bringToFront];
        self.dragStartOrigin = f.origin;
        self.maximized = NO;
        [self applyLift:YES];
        [self revealChrome];
    }
    // Absolute positioning from the drag start (so rubber-band doesn't compound frame-to-frame).
    CGPoint t = [g translationInView:nil];
    f.origin.x = cphRubberband(self.dragStartOrigin.x + t.x, loX, hiX);
    f.origin.y = cphRubberband(self.dragStartOrigin.y + t.y, loY, hiY);
    self.window.frame = f;

    CGPoint loc = [g locationInView:self.window];
    CGPoint sp = CGPointMake(f.origin.x + loc.x, f.origin.y + loc.y);
    CPHSnapZone z = snapZoneForPoint(sp, S);
    if (g.state == UIGestureRecognizerStateChanged || g.state == UIGestureRecognizerStateBegan) {
        if (z != CPHSnapNone) cphShowSnap(rectForZone(z, S)); else cphHideSnap();
    }
    if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        cphHideSnap();
        [self applyLift:NO];
        [self scheduleChromeHide];
        if (z != CPHSnapNone) { [self snapToZone:z]; return; }
        // Inertia: fling with the release velocity, settle with a spring, clamped on-screen.
        CGPoint v = [g velocityInView:nil];
        CGPoint proj = CGPointMake(MAX(loX, MIN(hiX, f.origin.x + v.x * 0.06)),
                                   MAX(loY, MIN(hiY, f.origin.y + v.y * 0.06)));
        CGFloat speed = sqrt(v.x * v.x + v.y * v.y);
        [UIView animateWithDuration:0.5 delay:0 usingSpringWithDamping:0.84 initialSpringVelocity:MIN(speed / 900.0, 6)
                            options:UIViewAnimationOptionAllowUserInteraction animations:^{
            CGRect nf = self.window.frame; nf.origin = proj; self.window.frame = nf;
        } completion:nil];
    }
}

- (void)snapToZone:(CPHSnapZone)z {
    CGRect r = rectForZone(z, sceneSizeFor(self.window));
    if (CGRectIsEmpty(r)) return;
    [self bringToFront];
    if (z == CPHSnapMax) {
        if (!self.maximized) self.restoreFrame = self.window.frame;   // remember pre-fullscreen size
        self.maximized = YES;
    } else {
        self.maximized = NO;
    }
    [UIView animateWithDuration:0.34 delay:0 usingSpringWithDamping:0.82 initialSpringVelocity:0.4
                        options:UIViewAnimationOptionAllowUserInteraction animations:^{ self.window.frame = r; }
                     completion:^(BOOL fin) { [self deliverSceneSize]; }];
}

- (void)dragResize:(UIPanGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan) { [self bringToFront]; [self revealChrome]; }
    CGPoint t = [g translationInView:nil];
    CGRect f = self.window.frame;
    f.size.width  = MAX(300, f.size.width  + t.x);
    f.size.height = MAX(220, f.size.height + t.y);
    self.window.frame = f;
    self.maximized = NO;
    [g setTranslation:CGPointZero inView:nil];
    // While dragging the layer just stretches; on release, re-deliver bounds so the app reflows.
    if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        [self deliverSceneSize];
        [self scheduleChromeHide];
    }
}

- (void)toggleMaximize {
    CGSize S = sceneSizeFor(self.window);
    CGRect full = (CGRect){ CGPointZero, S };
    CGRect dest;
    if (self.maximized) {
        dest = self.restoreFrame;
        if (CGRectIsEmpty(dest)) {     // never had a saved size → sensible centered default
            CGFloat pw = S.width * 0.58, ph = S.height * 0.66;
            dest = CGRectMake((S.width - pw) / 2, (S.height - ph) / 2, pw, ph);
        }
        self.maximized = NO;
    } else {
        self.restoreFrame = self.window.frame;   // remember current size to resume later
        dest = full;
        self.maximized = YES;
    }
    [self bringToFront];
    [UIView animateWithDuration:0.36 delay:0 usingSpringWithDamping:0.82 initialSpringVelocity:0.4
                        options:UIViewAnimationOptionAllowUserInteraction animations:^{ self.window.frame = dest; }
                     completion:^(BOOL fin) { [self deliverSceneSize]; }];
}

// Pop the app OUT of the window manager and launch it normally (double-tap the title bar).
- (void)popOut { launchAppNormally(self.bid); }

// Tear down SAFELY. SBAppViewController asserts in -dealloc if released while still
// hosting a live scene, so _setCurrentMode:0 + invalidate (BSInvalidatable) first.
- (void)teardown {
    [self.chromeHideTimer invalidate]; self.chromeHideTimer = nil;
    if (self.avc) {
        @try { objcInvoke_1(self.avc, @"_setCurrentMode:", (long long)0); } @catch (__unused NSException *e) {}
        @try { objcInvoke(self.avc, @"invalidate"); } @catch (__unused NSException *e) {}
        @try {
            [(UIViewController *)self.avc willMoveToParentViewController:nil];
            [(UIViewController *)self.avc removeFromParentViewController];
        } @catch (__unused NSException *e) {}
        self.avc = nil;
    }
    if (self.window) { self.window.hidden = YES; self.window.rootViewController = nil; self.window = nil; }
    self.rootVC = nil;
    [gPanels removeObject:self];
    updateFocusStates();
    hlog([NSString stringWithFormat:@"panel down %@ (%lu left)", self.bid, (unsigned long)gPanels.count]);
}

@end

// ===========================================================================
// CPHChromeVC — the dock, the floating summon button, and the snap preview.
// ===========================================================================
@implementation CPHChromeVC {
    BOOL _appsBuilt;
    BOOL _placedToggle;
}

- (void)loadView {
    CPHPassthroughView *v = [[CPHPassthroughView alloc] initWithFrame:[UIScreen mainScreen].bounds];
    v.backgroundColor = [UIColor clearColor];
    self.view = v;
}
- (BOOL)prefersStatusBarHidden { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAll; }

- (void)viewDidLoad {
    [super viewDidLoad];

    // snap-zone preview (non-interactive, lives above everything in the chrome)
    UIView *prev = [[UIView alloc] initWithFrame:CGRectZero];
    prev.backgroundColor = [UIColor colorWithRed:0.20 green:0.52 blue:1 alpha:0.26];
    prev.layer.borderColor = [UIColor colorWithRed:0.35 green:0.62 blue:1 alpha:0.95].CGColor;
    prev.layer.borderWidth = 2;
    prev.layer.cornerRadius = 14;
    prev.alpha = 0;
    prev.userInteractionEnabled = NO;
    [self.view addSubview:prev];
    self.snapPreview = prev;
    // (The old all-apps ▦ dock + floating summon button were removed — the real iOS dock + the
    //  swipe-up real-dock reveal replaced them. The chrome now only carries the snap preview,
    //  the drag ghost, and the real-dock reveal.)
}

- (void)dragToggle:(UIPanGestureRecognizer *)g {
    CGPoint t = [g translationInView:self.view];
    CGPoint c = self.toggle.center;
    c.x += t.x; c.y += t.y;
    CGSize S = self.view.bounds.size;
    CGFloat r = self.toggle.bounds.size.width / 2 + 4;
    c.x = MAX(r, MIN(S.width - r, c.x));
    c.y = MAX(r + 24, MIN(S.height - r - 24, c.y));
    self.toggle.center = c;
    [g setTranslation:CGPointZero inView:self.view];
}

- (void)toggleTapped {
    if (!gAppEntries) gAppEntries = installedApps();
    [self buildDockContents];
    if (self.dockShown) [self hideDock]; else [self showDock];
}

- (UIView *)controlCellGlyph:(NSString *)glyph label:(NSString *)label x:(CGFloat)x width:(CGFloat)cw height:(CGFloat)H action:(SEL)action {
    UIView *cell = [[UIView alloc] initWithFrame:CGRectMake(x, 4, cw, H - 8)];
    UILabel *g = [[UILabel alloc] initWithFrame:CGRectMake(0, 8, cw, 40)];
    g.text = glyph; g.font = [UIFont systemFontOfSize:26]; g.textAlignment = NSTextAlignmentCenter; g.textColor = [UIColor whiteColor];
    [cell addSubview:g];
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(0, 52, cw, 16)];
    l.text = label; l.font = [UIFont systemFontOfSize:9]; l.textAlignment = NSTextAlignmentCenter; l.textColor = [UIColor colorWithWhite:1 alpha:0.8];
    [cell addSubview:l];
    [cell addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:action]];
    return cell;
}

- (void)buildDockContents {
    if (_appsBuilt) return;
    _appsBuilt = YES;
    UIView *c = self.dock.contentView;
    CGFloat H = self.dock.bounds.size.height;
    CGFloat pad = 8, cw = 64;

    [c addSubview:[self controlCellGlyph:@"▦" label:@"Tile"      x:pad        width:cw height:H action:@selector(tileTapped)]];
    [c addSubview:[self controlCellGlyph:@"✕" label:@"Close All" x:pad + cw   width:cw height:H action:@selector(closeAllTapped)]];

    CGFloat sx = pad + cw * 2 + 6;
    UIView *sep = [[UIView alloc] initWithFrame:CGRectMake(sx - 4, 14, 1, H - 28)];
    sep.backgroundColor = [UIColor colorWithWhite:1 alpha:0.2];
    sep.autoresizingMask = UIViewAutoresizingFlexibleHeight;
    [c addSubview:sep];

    UIScrollView *sv = [[UIScrollView alloc] initWithFrame:CGRectMake(sx, 0, self.dock.bounds.size.width - sx - pad, H)];
    sv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    sv.showsHorizontalScrollIndicator = NO;
    [c addSubview:sv];
    self.appScroll = sv;

    CGFloat x = 6;
    for (NSUInteger i = 0; i < gAppEntries.count; i++) {
        NSDictionary *e = gAppEntries[i];
        UIView *cell = [[UIView alloc] initWithFrame:CGRectMake(x, 4, cw, H - 8)];
        cell.tag = i;
        UIImageView *iv = [[UIImageView alloc] initWithFrame:CGRectMake((cw - 50) / 2, 6, 50, 50)];
        iv.contentMode = UIViewContentModeScaleAspectFit;
        iv.layer.cornerRadius = 11; iv.layer.masksToBounds = YES;
        iv.image = iconForBid(e[@"bid"]);
        [cell addSubview:iv];
        UILabel *nl = [[UILabel alloc] initWithFrame:CGRectMake(-4, 58, cw + 8, 16)];
        nl.text = e[@"name"]; nl.font = [UIFont systemFontOfSize:10]; nl.textAlignment = NSTextAlignmentCenter;
        nl.textColor = [UIColor colorWithWhite:1 alpha:0.85];
        nl.adjustsFontSizeToFitWidth = YES; nl.minimumScaleFactor = 0.7;
        [cell addSubview:nl];
        [cell addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(iconTapped:)]];
        [sv addSubview:cell];
        x += cw;
    }
    sv.contentSize = CGSizeMake(x + 6, H);
    hlog([NSString stringWithFormat:@"dock built (%lu apps)", (unsigned long)gAppEntries.count]);
}

- (void)iconTapped:(UITapGestureRecognizer *)g {
    NSInteger i = g.view.tag;
    if (i >= 0 && i < (NSInteger)gAppEntries.count) {
        hostApp(gAppEntries[i][@"bid"]);
        [self hideDock];
    }
}

- (void)tileTapped {
    [self hideDock];
    if (!gPanels.count) return;
    // front-most first (highest window level), tile up to 4 into a grid
    NSArray<CPHPanel *> *sorted = [gPanels sortedArrayUsingComparator:^NSComparisonResult(CPHPanel *a, CPHPanel *b) {
        CGFloat la = a.window.windowLevel, lb = b.window.windowLevel;
        return la > lb ? NSOrderedAscending : (la < lb ? NSOrderedDescending : NSOrderedSame);
    }];
    CGSize S = sceneSizeFor(sorted.firstObject.window);
    CGFloat w = S.width, h = S.height, hw = w / 2, hh = h / 2;
    NSUInteger n = MIN(sorted.count, 4);
    NSArray<NSValue *> *rects;
    if (n == 1) rects = @[ [NSValue valueWithCGRect:CGRectMake(0,0,w,h)] ];
    else if (n == 2) rects = @[ [NSValue valueWithCGRect:CGRectMake(0,0,hw,h)], [NSValue valueWithCGRect:CGRectMake(hw,0,hw,h)] ];
    else if (n == 3) rects = @[ [NSValue valueWithCGRect:CGRectMake(0,0,hw,h)], [NSValue valueWithCGRect:CGRectMake(hw,0,hw,hh)], [NSValue valueWithCGRect:CGRectMake(hw,hh,hw,hh)] ];
    else rects = @[ [NSValue valueWithCGRect:CGRectMake(0,0,hw,hh)], [NSValue valueWithCGRect:CGRectMake(hw,0,hw,hh)], [NSValue valueWithCGRect:CGRectMake(0,hh,hw,hh)], [NSValue valueWithCGRect:CGRectMake(hw,hh,hw,hh)] ];
    for (NSUInteger i = 0; i < n; i++) {
        CPHPanel *p = sorted[i];
        CGRect r = [rects[i] CGRectValue];
        p.maximized = NO;
        [UIView animateWithDuration:0.22 animations:^{ p.window.frame = r; }
                         completion:^(BOOL fin) { [p deliverSceneSize]; }];
    }
}

- (void)closeAllTapped {
    [self hideDock];
    dismissAll();
}

- (void)showDock {
    self.dockShown = YES;
    if (!self.scrim) {
        UIView *s = [[UIView alloc] initWithFrame:self.view.bounds];
        s.backgroundColor = [UIColor colorWithWhite:0 alpha:0.001];   // invisible but captures outside taps
        [s addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(hideDock)]];
        self.scrim = s;
    }
    self.scrim.frame = self.view.bounds;
    [self.view insertSubview:self.scrim belowSubview:self.dock];
    [self.view bringSubviewToFront:self.dock];
    [self.view bringSubviewToFront:self.toggle];
    self.dock.alpha = 0;
    self.dock.transform = CGAffineTransformMakeTranslation(0, 44);
    [UIView animateWithDuration:0.22 delay:0 usingSpringWithDamping:0.85 initialSpringVelocity:0.4 options:0
                     animations:^{ self.dock.alpha = 1; self.dock.transform = CGAffineTransformIdentity; } completion:nil];
}

- (void)hideDock {
    self.dockShown = NO;
    [self.scrim removeFromSuperview];
    [UIView animateWithDuration:0.18 animations:^{
        self.dock.alpha = 0;
        self.dock.transform = CGAffineTransformMakeTranslation(0, 44);
    }];
}

// Reveal a mirror of the real iOS dock (centered pill of the user's actual dock apps), sliding
// up over a fullscreen window. Tapping an app opens it as a window.
- (void)revealRealDock {
    if (self.realDockShown) return;
    NSArray<NSString *> *bids = realDockBundleIDs();
    if (!bids.count) { hlog(@"realDock: no dock apps found"); return; }
    self.realDockBids = bids;
    [self.realDock removeFromSuperview];

    NSUInteger n = bids.count;
    CGFloat screenW = self.view.bounds.size.width, screenH = self.view.bounds.size.height;
    CGFloat pad = 12, gap = 10, iconSize = 54;
    CGFloat maxW = screenW - 48;
    CGFloat needed = pad * 2 + n * iconSize + (n - 1) * gap;
    if (needed > maxW) iconSize = MAX(34, (maxW - pad * 2 - (n - 1) * gap) / n);
    CGFloat pillW = pad * 2 + n * iconSize + (n - 1) * gap;
    CGFloat pillH = iconSize + pad * 2;

    UIVisualEffectView *pill = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThickMaterialDark]];
    pill.frame = CGRectMake((screenW - pillW) / 2, screenH - pillH - 14, pillW, pillH);
    pill.layer.cornerRadius = 24; pill.layer.masksToBounds = YES;
    pill.layer.borderWidth = 1; pill.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.2].CGColor;
    CGFloat x = pad;
    NSMutableArray<UIButton *> *buttons = [NSMutableArray array];
    for (NSUInteger i = 0; i < n; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        b.bounds = CGRectMake(0, 0, iconSize, iconSize);
        b.layer.anchorPoint = CGPointMake(0.5, 1.0);                 // grow upward when magnified
        b.layer.position = CGPointMake(x + iconSize / 2, pad + iconSize);
        b.tag = i;
        [b setImage:iconForBid(bids[i]) forState:UIControlStateNormal];
        b.imageView.contentMode = UIViewContentModeScaleAspectFit;
        b.layer.cornerRadius = iconSize * 0.22; b.layer.masksToBounds = YES;
        [b addTarget:self action:@selector(realDockIconTapped:) forControlEvents:UIControlEventTouchUpInside];
        [pill.contentView addSubview:b];
        [buttons addObject:b];
        if (panelForBid(bids[i])) {                                  // running-window indicator dot
            UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(x + iconSize / 2 - 2.5, pillH - 8, 5, 5)];
            dot.backgroundColor = [UIColor colorWithWhite:1 alpha:0.9];
            dot.layer.cornerRadius = 2.5;
            dot.userInteractionEnabled = NO;
            [pill.contentView addSubview:dot];
        }
        x += iconSize + gap;
    }
    self.realDockButtons = buttons;
    // macOS magnification — pointer hover (mouse) or a touch-drag across the dock.
    [pill addGestureRecognizer:[[UIHoverGestureRecognizer alloc] initWithTarget:self action:@selector(dockMagnify:)]];
    [pill addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dockMagnify:)]];

    UIView *scrim = [[UIView alloc] initWithFrame:self.view.bounds];
    scrim.backgroundColor = [UIColor colorWithWhite:0 alpha:0.001];
    [scrim addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(hideRealDock)]];
    self.realDockScrim = scrim;
    [self.view addSubview:scrim];
    [self.view addSubview:pill];
    self.realDock = pill;
    self.realDockShown = YES;

    pill.transform = CGAffineTransformMakeTranslation(0, pillH + 30);
    pill.alpha = 0;
    [UIView animateWithDuration:0.30 delay:0 usingSpringWithDamping:0.80 initialSpringVelocity:0.6 options:0
                     animations:^{ pill.transform = CGAffineTransformIdentity; pill.alpha = 1; } completion:nil];
}

- (void)hideRealDock {
    if (!self.realDockShown) return;
    self.realDockShown = NO;
    [self.realDockScrim removeFromSuperview];
    UIView *pill = self.realDock;
    [UIView animateWithDuration:0.2 animations:^{
        pill.transform = CGAffineTransformMakeTranslation(0, pill.bounds.size.height + 30);
        pill.alpha = 0;
    } completion:^(BOOL fin) { [pill removeFromSuperview]; }];
}

// macOS dock magnification: icons swell with proximity to the pointer/finger, fall back to 1× off.
- (void)dockMagnify:(UIGestureRecognizer *)g {
    BOOL active = (g.state == UIGestureRecognizerStateBegan || g.state == UIGestureRecognizerStateChanged);
    CGFloat tx = active ? [g locationInView:self.realDock].x : -100000;   // off-screen → reset to 1×
    CGFloat sigma = 75, boost = 0.7;
    [UIView animateWithDuration:0.12 delay:0
                        options:UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionBeginFromCurrentState
                     animations:^{
        for (UIButton *b in self.realDockButtons) {
            CGFloat dx = b.layer.position.x - tx;
            CGFloat s = 1 + boost * exp(-(dx * dx) / (2 * sigma * sigma));
            b.transform = CGAffineTransformMakeScale(s, s);
        }
    } completion:nil];
}

- (void)realDockIconTapped:(UIButton *)b {
    NSInteger i = b.tag;
    if (i >= 0 && i < (NSInteger)self.realDockBids.count) {
        NSString *bid = self.realDockBids[i];
        [self hideRealDock];
        hostApp(bid);
    }
}

@end

// ===========================================================================
// Real-dock integration — hold an app's dock icon to open it as a window.
// ===========================================================================
static char kCPHDockLP;    // associated-object key: our tap recognizer on a dock icon
static char kCPHDockPan;   // associated-object key: our pan (drag-to-tile) recognizer
static char kCPHDragBid;   // associated-object key: bid captured at drag start

static BOOL iconsEditing(void) {
    @try {
        id ctrl = objcInvoke(objc_getClass("SBIconController"), @"sharedInstance");
        return ((BOOL (*)(id, SEL))objc_msgSend)(ctrl, NSSelectorFromString(@"isEditing"));
    } @catch (__unused NSException *e) { return NO; }
}
static NSString *bidForIconView(UIView *iconView) {
    id icon = nil; @try { icon = objcInvoke(iconView, @"icon"); } @catch (__unused NSException *e) {}
    if (!icon) return nil;
    // Resolve via the SBApplication first — handles Suggested/Recent dock icons, whose
    // applicationBundleIdentifier/leafIdentifier report a recency UUID instead of the bundle id.
    @try {
        id app = objcInvoke(icon, @"application");
        if (app) { id b = objcInvoke(app, @"bundleIdentifier"); if ([b isKindOfClass:[NSString class]]) return b; }
    } @catch (__unused NSException *e) {}
    NSString *bid = nil;
    @try { bid = objcInvoke(icon, @"applicationBundleIdentifier"); } @catch (__unused NSException *e) {}
    if (![bid isKindOfClass:[NSString class]]) { @try { bid = objcInvoke(icon, @"leafIdentifier"); } @catch (__unused NSException *e) {} }
    // Reject obvious non-bundle-ids (a UUID has no dot) so we never hostApp(UUID).
    if ([bid isKindOfClass:[NSString class]] && [bid containsString:@"."]) return bid;
    return nil;
}

// Collect the real iOS dock's app icon views (SBIconViews whose ancestry includes a "Dock" view).
static void collectDockIcons(UIView *v, Class iconCls, NSMutableArray *out) {
    if (iconCls && [v isKindOfClass:iconCls]) {
        UIView *a = v; int d = 0;
        while ((a = a.superview) && d++ < 12) {
            if ([NSStringFromClass([a class]) containsString:@"Dock"]) { [out addObject:v]; break; }
        }
        return;   // an icon view has no icon-view children worth recursing
    }
    for (UIView *sub in v.subviews) collectDockIcons(sub, iconCls, out);
}

// The user's actual dock apps, left-to-right (mirrors their customization live).
static NSArray<NSString *> *realDockBundleIDs(void) {
    NSMutableArray<UIView *> *icons = [NSMutableArray array];
    @try {
        Class iconCls = objc_getClass("SBIconView");
        for (UIScene *s in [[[UIApplication sharedApplication] connectedScenes] allObjects]) {
            if (![s isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *win in ((UIWindowScene *)s).windows) {
                if (win == gChrome) continue;                                  // skip our chrome
                if ([win.rootViewController isKindOfClass:objc_getClass("CPHRootVC")]) continue;  // skip panels
                collectDockIcons(win, iconCls, icons);
            }
        }
    } @catch (__unused NSException *e) {}
    [icons sortUsingComparator:^NSComparisonResult(UIView *a, UIView *b) {
        CGFloat ax = [a convertPoint:CGPointZero toView:nil].x;
        CGFloat bx = [b convertPoint:CGPointZero toView:nil].x;
        return ax < bx ? NSOrderedAscending : (ax > bx ? NSOrderedDescending : NSOrderedSame);
    }];
    NSMutableArray<NSString *> *bids = [NSMutableArray array];
    for (UIView *iv in icons) {
        NSString *bid = bidForIconView(iv);
        if (bid.length && ![bids containsObject:bid]) [bids addObject:bid];
    }
    return bids;
}

@interface CPHIconHelper : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)shared;
- (void)dockIconTap:(UITapGestureRecognizer *)g;
- (void)dockIconPan:(UIPanGestureRecognizer *)g;
@end
@implementation CPHIconHelper
+ (instancetype)shared {
    static CPHIconHelper *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [CPHIconHelper new]; });
    return s;
}
// Only let our tap/pan fire on real app icons (have a bundle id) and not while editing.
// Folders / placeholders have no bid → our recognizer fails → the icon's normal tap (which
// required ours to fail) runs, so folders still open. Decided live, so recycled views are safe.
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gr {
    @try {
        if (iconsEditing()) return NO;
        return bidForIconView(gr.view).length > 0;
    } @catch (__unused NSException *e) { return NO; }
}
- (void)dockIconTap:(UITapGestureRecognizer *)g {
    @try {
        if (iconsEditing()) return;   // don't hijack taps while rearranging
        NSString *bid = bidForIconView(g.view);
        if (!bid.length) { hlog(@"dockTap: no bid"); return; }
        hlog([NSString stringWithFormat:@"dockTap open %@", bid]);
        hostApp(bid);   // opens as a window (or focuses/restores an existing one)
    } @catch (NSException *e) { hlog([NSString stringWithFormat:@"dockTap exc %@", e.reason]); }
}
// Drag an app off the dock → ghost follows the finger, snap zones light up, release to tile.
- (void)dockIconPan:(UIPanGestureRecognizer *)g {
    @try {
        if (iconsEditing()) return;   // let iOS handle rearrange in edit mode
        UIView *iconView = g.view;
        UIWindow *hw = iconView.window;
        if (!hw) return;
        CGPoint p = [g locationInView:hw];        // home-screen window == scene coordinates
        CGSize S = hw.bounds.size;
        ensureChrome();

        if (g.state == UIGestureRecognizerStateBegan) {
            NSString *bid = bidForIconView(iconView);
            objc_setAssociatedObject(g, &kCPHDragBid, bid, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            cphGhost(bid ? iconForBid(bid) : nil, p, YES);
        } else if (g.state == UIGestureRecognizerStateChanged) {
            cphGhost(nil, p, YES);
            CPHSnapZone z = snapZoneForPoint(p, S);
            if (z != CPHSnapNone) cphShowSnap(rectForZone(z, S)); else cphHideSnap();
        } else if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
            cphGhost(nil, p, NO);
            cphHideSnap();
            CPHSnapZone z = snapZoneForPoint(p, S);
            NSString *bid = objc_getAssociatedObject(g, &kCPHDragBid);
            if (bid.length && z != CPHSnapNone && g.state == UIGestureRecognizerStateEnded) {
                hlog([NSString stringWithFormat:@"dockDrag %@ -> zone %d", bid, (int)z]);
                openInZone(bid, (int)z);
            }
        }
    } @catch (NSException *e) { hlog([NSString stringWithFormat:@"dockPan exc %@", e.reason]); }
}
@end

// ===========================================================================
// Triggers
// ===========================================================================
static void hostApp(NSString *bid) {
    if (!gEnabled || !bid.length) return;
    ensureChrome();
    NSTimeInterval now = [NSDate date].timeIntervalSinceReferenceDate;
    NSNumber *last = gLastHost[bid];
    if (last && now - last.doubleValue < 0.6) { hlog([NSString stringWithFormat:@"debounced %@", bid]); return; }
    gLastHost[bid] = @(now);

    // Already hosting this app? Restore (if minimized) + focus it, no duplicate window.
    CPHPanel *existing = panelForBid(bid);
    if (existing) {
        if (existing.window.hidden) [existing restoreFromMinimize];
        else [existing bringToFront];
        hlog([NSString stringWithFormat:@"focus existing %@", bid]);
        return;
    }

    @try {
        hlog([NSString stringWithFormat:@"hostApp %@", bid]);
        id app = objcInvoke_1(objcInvoke(objc_getClass("SBApplicationController"), @"sharedInstance"), @"applicationWithBundleIdentifier:", bid);
        if (!app) { hlog(@"no SBApplication"); return; }

        UIWindowScene *scene = foregroundWindowScene();
        CGRect screen = scene ? scene.coordinateSpace.bounds : [UIScreen mainScreen].bounds;
        CGFloat pw = screen.size.width * 0.58, ph = screen.size.height * 0.66;
        // First window opens fullscreen (title bar kept); once something's open, new ones cascade.
        BOOL fullscreen = (gPanels.count == 0);
        CGRect initial;
        if (fullscreen) {
            initial = screen;
        } else {
            CGFloat ox = 50 + (gCascade % 5) * 44;
            CGFloat oy = 32 + (gCascade % 5) * 40;
            gCascade++;
            initial = CGRectMake(ox, oy, pw, ph);
        }

        CPHPanel *panel = [[CPHPanel alloc] initWithBid:bid app:app scene:scene initialFrame:initial];
        if (panel) {
            if (fullscreen) {
                panel.maximized = YES;   // square the corners + treat as maximized
                // green button un-maximizes to a centered window
                panel.restoreFrame = CGRectMake((screen.size.width - pw) / 2, (screen.size.height - ph) / 2, pw, ph);
            }
            [gPanels addObject:panel];
            updateFocusStates();
        }
    } @catch (NSException *e) {
        hlog([NSString stringWithFormat:@"EXC %@ -- %@", [e name], [e reason]]);
    }
}

static void dismissAll(void) {
    for (CPHPanel *p in [gPanels copy]) [p teardown];
    hlog(@"dismissed all");
}

// Front-most (highest level, visible) window is "focused"; everything else is inactive.
static void updateFocusStates(void) {
    CPHPanel *front = nil;
    for (CPHPanel *p in gPanels) {
        if (p.minimized || !p.window || p.window.hidden) continue;
        if (!front || p.window.windowLevel > front.window.windowLevel) front = p;
    }
    for (CPHPanel *p in gPanels) [p applyFocusState:(p == front)];
}

// Pressing home / going to the switcher should send all windows to the dock (still running),
// NOT leave a black hosted scene covering the home screen. Returns how many were minimized.
static int minimizeAllWindows(void) {
    int n = 0;
    for (CPHPanel *p in [gPanels copy]) {
        if (p.window && !p.window.hidden && !p.minimized) { [p minimizeTapped]; n++; }
    }
    if (n) hlog([NSString stringWithFormat:@"home → minimized %d window(s)", n]);
    return n;
}

// Suspend/restore our overlay when system UI takes over — fade + scale down (then truly hide),
// or unhide then fade + scale back in, so it reads like a native transition, not a hard cut.
static void setManagedWindowsHidden(BOOL hidden) {
    NSArray<CPHPanel *> *ps = [gPanels copy];
    if (!hidden) {   // showing: unhide + re-render while still faded out (no black flash)
        for (CPHPanel *p in ps) { if (!p.minimized && p.window) { p.window.hidden = NO; [p deliverSceneSize]; } }
        if (gChrome) gChrome.hidden = NO;
    }
    [UIView animateWithDuration:0.30 delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:^{
        for (CPHPanel *p in ps) {
            if (p.minimized || !p.window) continue;
            p.window.alpha = hidden ? 0.0 : 1.0;
            p.rootVC.view.transform = hidden ? CGAffineTransformMakeScale(0.93, 0.93) : CGAffineTransformIdentity;
        }
        if (gChrome) gChrome.alpha = hidden ? 0.0 : 1.0;
    } completion:^(BOOL fin) {
        if (!hidden) {
            // Re-push bounds so the hosted scenes re-render — they go BLACK while hidden and
            // only repaint on a settings update (which a resize triggers). Without this, windows
            // come back black after multitasking/Control Center until you resize them.
            for (CPHPanel *p in ps) { if (!p.minimized) [p deliverSceneSize]; }
            return;
        }
        for (CPHPanel *p in ps) { if (!p.minimized && p.window) p.window.hidden = YES; }
        if (gChrome) gChrome.hidden = YES;
    }];
}

// Coordinator for "system UI is taking over". Control Center, Notification Center, the app
// switcher, Siri, etc. all sit ABOVE our windows, so they'd open behind us. While ANY of them
// is up we suspend (hide) our overlay; when the last one dismisses we restore. Reference-counted
// by reason so overlapping/nested takeovers don't restore early. (Distinct from the Home button,
// which does a *sticky* minimize-to-dock that the user re-summons.)
static NSMutableSet<NSString *> *gSuspendReasons;
static void cphSuspendOverlay(NSString *reason) {
    if (!gSuspendReasons) gSuspendReasons = [NSMutableSet set];
    BOOL wasClear = (gSuspendReasons.count == 0);
    [gSuspendReasons addObject:reason];
    if (wasClear) setManagedWindowsHidden(YES);
    hlog([NSString stringWithFormat:@"suspend(%@) → %lu", reason, (unsigned long)gSuspendReasons.count]);
}
static void cphResumeOverlay(NSString *reason) {
    [gSuspendReasons removeObject:reason];
    if (gSuspendReasons.count == 0) setManagedWindowsHidden(NO);
    hlog([NSString stringWithFormat:@"resume(%@) → %lu", reason, (unsigned long)gSuspendReasons.count]);
}

// Open (or focus) an app and snap it to a tiling zone — used by drag-from-dock.
static void openInZone(NSString *bid, int zone) {
    if (!bid.length) return;
    hostApp(bid);
    CPHPanel *p = panelForBid(bid);
    if (p) [p snapToZone:(CPHSnapZone)zone];
}

// Launch an app the NORMAL fullscreen way (escape hatch out of the window manager). If we're
// hosting it, hand the scene back first so the app process isn't owned twice.
static void launchAppNormally(NSString *bid) {
    if (!bid.length) return;
    CPHPanel *p = panelForBid(bid);
    if (p) [p teardown];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        @try {
            id ws = objcInvoke(objc_getClass("LSApplicationWorkspace"), @"defaultWorkspace");
            ((BOOL (*)(id, SEL, id))objc_msgSend)(ws, NSSelectorFromString(@"openApplicationWithBundleID:"), bid);
            hlog([NSString stringWithFormat:@"openAsApp %@", bid]);
        } @catch (__unused NSException *e) {}
    });
}

static void ensureChrome(void) {
    if (gChrome) return;
    UIWindowScene *scene = foregroundWindowScene();
    if (!scene) return;
    @try {
        UIWindow *w = [[CPHChromeWindow alloc] initWithWindowScene:scene];
        w.frame = scene.coordinateSpace.bounds;
        w.windowLevel = (UIWindowLevel)kChromeLevel;
        w.backgroundColor = [UIColor clearColor];
        w.rootViewController = [CPHChromeVC new];
        gChrome = w;
        w.hidden = NO;    // visible but never key — don't steal focus from a hosted app
        hlog(@"chrome up");
    } @catch (NSException *e) {
        hlog([NSString stringWithFormat:@"chrome exc %@", e.reason]);
        gChrome = nil;
    }
}

static void scheduleChrome(int attempt) {
    if (gChrome || attempt > 6) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ensureChrome();
        if (!gChrome) scheduleChrome(attempt + 1);
    });
}

// Our ad-hoc-hosted SBAppViewControllers aren't fully integrated into the scene-layout
// system, so when a hosted scene updates its settings it throws a BSAssert that would
// SIGABRT SpringBoard. Catch it — but ONLY for our hosted VCs, never the real ones.
%hook SBAppViewController
- (void)sceneHandle:(id)arg1 didUpdateSettingsWithDiff:(id)arg2 previousSettings:(id)arg3 {
    if (isOurAVC(self)) {
        // Our ad-hoc-hosted scene throws a BSAssert ("foreground status changed out from under
        // us") on settings churn — catching it is the actual SIGABRT guard for SpringBoard.
        @try { %orig; } @catch (NSException *e) { hlog([NSString stringWithFormat:@"caught scene-update exc: %@", [e reason]]); }
        return;
    }
    %orig;
}
%end

// Arm a hold-to-open recognizer on icons that live in the dock (only the dock).
%hook SBIconView
- (void)didMoveToWindow {
    %orig;
    if (!gEnabled) return;
    @try {
        UIView *self_ = (UIView *)self;     // SBIconView is forward-declared here; it's a UIView
        if (!self_.window) return;
        if (objc_getAssociatedObject(self, &kCPHDockLP)) return;
        BOOL inDock = NO; { UIView *v = self_; int depth = 0;
            while ((v = v.superview) && depth++ < 10) {
                if ([NSStringFromClass([v class]) containsString:@"Dock"]) { inDock = YES; break; }
            }
        }
        // Tap → open as a window — on ALL app icons (dock AND home screen). A delegate decides
        // per-icon at tap time whether to fire (only real app icons, never folders, never in
        // edit mode), so the icon's own launch defers to ours but folders still open normally
        // even as icon views get recycled across pages.
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:[CPHIconHelper shared] action:@selector(dockIconTap:)];
        tap.delegate = [CPHIconHelper shared];
        for (UIGestureRecognizer *r in [self_.gestureRecognizers copy]) {
            if ([r isKindOfClass:[UITapGestureRecognizer class]] && [(UITapGestureRecognizer *)r numberOfTapsRequired] == 1) {
                @try { [r requireGestureRecognizerToFail:tap]; } @catch (__unused NSException *e) {}
            }
        }
        [self_ addGestureRecognizer:tap];
        objc_setAssociatedObject(self, &kCPHDockLP, tap, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        // Drag-to-tile only on the dock (avoid fighting home-screen paging / icon dragging).
        if (inDock) {
            UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:[CPHIconHelper shared] action:@selector(dockIconPan:)];
            pan.delegate = [CPHIconHelper shared];
            [self_ addGestureRecognizer:pan];
            objc_setAssociatedObject(self, &kCPHDockPan, pan, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    } @catch (__unused NSException *e) {}
}
// Add "Open as App" to the icon long-press menu → launch normally (outside the WM).
- (NSArray *)additionalContextMenuActions {
    NSArray *orig = %orig;
    if (!gEnabled) return orig;
    @try {
        NSString *bid = bidForIconView((UIView *)self);
        if (!bid.length) return orig;
        UIAction *act = [UIAction actionWithTitle:@"Open as App"
                                            image:[UIImage systemImageNamed:@"arrow.up.forward.app"]
                                       identifier:@"com.max.cph.openasapp"
                                          handler:^(__kindof UIAction *a) { launchAppNormally(bid); }];
        return orig ? [orig arrayByAddingObject:act] : @[ act ];
    } @catch (__unused NSException *e) { return orig; }
}
%end

// Each system surface that sits above our windows funnels into the one overlay coordinator.
// All pairs are matched (same class, appear/disappear or present/dismiss) so the overlay can't
// get stuck hidden if one half never fires.
%hook SBFluidSwitcherViewController   // app switcher
- (void)viewWillAppear:(BOOL)animated { %orig; cphSuspendOverlay(@"switcher"); }
- (void)viewWillDisappear:(BOOL)animated { %orig; cphResumeOverlay(@"switcher"); }
%end

%hook CSCoverSheetViewController      // Notification Center / Cover Sheet
- (void)viewWillAppear:(BOOL)animated { %orig; cphSuspendOverlay(@"coversheet"); }
- (void)viewWillDisappear:(BOOL)animated { %orig; cphResumeOverlay(@"coversheet"); }
%end

%hook SBControlCenterController       // Control Center — dismissAnimated: confirmed; find the present
- (void)_beginPresentationWithControlCenterPresentationContext:(id)ctx { %orig; hlog(@"cc:beginCtx"); cphSuspendOverlay(@"controlcenter"); }
- (void)presentAnimated:(BOOL)animated { %orig; hlog(@"cc:presentAnimated"); cphSuspendOverlay(@"controlcenter"); }
- (void)dismissAnimated:(BOOL)animated { %orig; cphResumeOverlay(@"controlcenter"); }
%end

%hook SpringBoard
- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    cphReadPrefs();
    gPanels = [NSMutableArray array];
    gLastHost = [NSMutableDictionary dictionary];
    if (!gEnabled) { hlog(@"Mosaic disabled — dormant"); return; }   // no chrome, no observers
    id dnc = objcInvoke(objc_getClass("NSDistributedNotificationCenter"), @"defaultCenter");
    [dnc addObserverForName:@"com.max.carplayhost.open" object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
        hostApp([n userInfo][@"identifier"]);
    }];
    [dnc addObserverForName:@"com.max.carplayhost.dismiss" object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
        dismissAll();
    }];
    scheduleChrome(0);
    hlog(@"observers registered (window-manager + dock)");
}

// Home button → minimize all windows to the dock (apps keep running) so the home screen
// shows instead of a black hosted scene. Always call %orig so the button still works.
// These selectors may or may not exist on this build; Logos skips the ones that don't.
- (void)handleMenuButtonTap {
    if (minimizeAllWindows()) hlog(@"home: handleMenuButtonTap");
    %orig;
}
- (void)handleHomeButtonSinglePress {
    if (minimizeAllWindows()) hlog(@"home: handleHomeButtonSinglePress");
    %orig;
}
- (void)handleHomeButtonPress {
    if (minimizeAllWindows()) hlog(@"home: handleHomeButtonPress");
    %orig;
}
// Control Center may notify SpringBoard (its delegate) rather than self-present — candidate pair.
- (void)controlCenterWillPresent { %orig; hlog(@"cc:SB-willPresent"); cphSuspendOverlay(@"controlcenter"); }
- (void)controlCenterDidDismiss { %orig; hlog(@"cc:SB-didDismiss"); cphResumeOverlay(@"controlcenter"); }
%end

// Settings toggle posts this Darwin notification → apply live (no respring needed).
static void cphPrefsChanged(CFNotificationCenterRef c, void *o, CFStringRef name, const void *obj, CFDictionaryRef info) {
    BOOL was = gEnabled;
    cphReadPrefs();
    if (was == gEnabled) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gEnabled) { dismissAll(); if (gChrome) gChrome.hidden = YES; }
        else { ensureChrome(); }
        hlog([NSString stringWithFormat:@"Mosaic %@ (live toggle)", gEnabled ? @"enabled" : @"disabled"]);
    });
}

%ctor {
    cphReadPrefs();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, cphPrefsChanged,
                                    CFSTR("com.max.mosaic.changed"), NULL, CFNotificationSuspensionBehaviorCoalesce);
}

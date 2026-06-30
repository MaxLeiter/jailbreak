#import "RootViewController.h"
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>

static char kBidKey;

static void logLine(NSString *s) {
    NSLog(@"[carplayshell] %@", s);
    NSString *path = @"/tmp/carplayshell.log";
    NSString *line = [s stringByAppendingString:@"\n"];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) { [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil]; return; }
    [fh seekToEndOfFile];
    [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [fh closeFile];
}

@interface RootViewController ()
@property (nonatomic, strong) NSArray<NSString *> *bundleIDs;
@end

@implementation RootViewController

static void loadCarPlayFrameworks(void) {
    const char *fws[] = {
        "/System/Library/PrivateFrameworks/CarKit.framework/CarKit",
        "/System/Library/PrivateFrameworks/CarPlayServices.framework/CarPlayServices",
        "/System/Library/PrivateFrameworks/CarPlayUIServices.framework/CarPlayUIServices",
        NULL };
    for (int i = 0; fws[i]; i++) dlopen(fws[i], RTLD_NOW);
}

- (BOOL)prefersStatusBarHidden { return YES; }
// Follow the device — HomeBase is a desktop, it should rotate with the iPad.
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAll; }

- (void)viewDidLoad {
    [super viewDidLoad];
    loadCarPlayFrameworks();
    [@"=== carplayshell ===\n" writeToFile:@"/tmp/carplayshell.log" atomically:YES encoding:NSUTF8StringEncoding error:nil];
    logLine([NSString stringWithFormat:@"viewDidLoad CarPlayUIServices=%d CarPlayServices=%d CarKit=%d",
             objc_getClass("CRSUIWallpaperPreferences") != nil,
             objc_getClass("CRSIconLayoutController") != nil,
             objc_getClass("CARSession") != nil]);

    self.view.backgroundColor = [UIColor blackColor];
    CAGradientLayer *grad = [CAGradientLayer layer];
    grad.frame = [UIScreen mainScreen].bounds;
    grad.colors = @[(id)[UIColor colorWithRed:0.07 green:0.08 blue:0.10 alpha:1].CGColor,
                    (id)[UIColor colorWithRed:0.02 green:0.02 blue:0.03 alpha:1].CGColor];
    [self.view.layer insertSublayer:grad atIndex:0];
    [self applyGenuineWallpaper];

    UILabel *clock = [[UILabel alloc] init];
    clock.tag = 99;
    clock.textColor = [UIColor whiteColor];
    clock.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    clock.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:clock];
    [NSLayoutConstraint activateConstraints:@[
        [clock.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:6],
        [clock.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
    ]];
    [self updateClock];
    [NSTimer scheduledTimerWithTimeInterval:10 target:self selector:@selector(updateClock) userInfo:nil repeats:YES];

    // Kitchen-friendly curated set. Anything not actually installed (or iconless) is
    // filtered out in layoutGrid, so wrong/absent ids silently drop instead of showing
    // a broken placeholder. Names are normalized via -displayNameForBundleID:.
    self.bundleIDs = @[@"com.apple.Music", @"com.spotify.client", @"com.google.ios.youtube",
                       @"com.apple.tv", @"com.apple.podcasts", @"com.apple.mobilesafari",
                       @"com.apple.mobiletimer", @"com.apple.weather", @"com.apple.Maps",
                       @"com.waze.iphone", @"com.apple.mobilenotes", @"com.apple.reminders",
                       @"com.apple.MobileSMS", @"com.apple.mobilecal", @"com.apple.news",
                       @"com.apple.Home"];

    [self attemptGenuineIconState];
}

- (void)updateClock {
    UILabel *clock = (UILabel *)[self.view viewWithTag:99];
    NSDateFormatter *df = [NSDateFormatter new];
    df.dateFormat = @"h:mm";
    clock.text = [df stringFromDate:[NSDate date]];
}

// Render the GENUINE CarPlay wallpaper (no car needed) behind the launcher.
- (void)applyGenuineWallpaper {
    @try {
        Class SW = objc_getClass("CRSUISystemWallpaper");
        if (!SW) { logLine(@"no CRSUISystemWallpaper"); return; }
        id wp = ((id (*)(id, SEL))objc_msgSend)((id)SW, sel_getUid("defaultWallpaper"));
        if (!wp) { logLine(@"no defaultWallpaper"); return; }

        // Safer path first: load the genuine wallpaper asset image by catalog name.
        NSString *asset = ((id (*)(id, SEL))objc_msgSend)(wp, sel_getUid("wallpaperAssetCatalogName"));
        if ([asset isKindOfClass:[NSString class]]) {
            UITraitCollection *trait = [UITraitCollection traitCollectionWithUserInterfaceIdiom:(UIUserInterfaceIdiom)3];
            UIImage *img = ((UIImage *(*)(id, SEL, id, id))objc_msgSend)([UIImage class],
                            sel_getUid("crsui_wallpaperImageNamed:compatibleWithTraitCollection:"), asset, trait);
            if (img) {
                UIImageView *iv = [[UIImageView alloc] initWithFrame:self.view.bounds];
                iv.image = img;
                iv.contentMode = UIViewContentModeScaleAspectFill;
                iv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
                [self.view insertSubview:iv atIndex:0];
                logLine([NSString stringWithFormat:@"genuine wallpaper IMAGE asset=%@ %dx%d", asset, (int)img.size.width, (int)img.size.height]);
                return;
            }
        }
        // Fallback: genuine dynamic wallpaper VIEW (CRSUIResolvedWallpaper -view)
        id resolved = ((id (*)(id, SEL))objc_msgSend)(wp, sel_getUid("resolveWallpaper"));
        id wpView = resolved ? ((id (*)(id, SEL))objc_msgSend)(resolved, sel_getUid("view")) : nil;
        if ([wpView isKindOfClass:[UIView class]]) {
            UIView *bg = (UIView *)wpView;
            bg.frame = self.view.bounds;
            bg.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            [self.view insertSubview:bg atIndex:0];
            logLine(@"genuine wallpaper VIEW applied");
            return;
        }
        logLine([NSString stringWithFormat:@"genuine wallpaper unavailable (asset=%@), keeping gradient", asset]);
    } @catch (__unused NSException *e) { logLine(@"wallpaper apply exc"); }
}

- (void)attemptGenuineIconState {
    Class C = objc_getClass("CRSIconLayoutController");
    if (!C) return;
    @try {
        id ctrl = ((id (*)(id, SEL))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)C, sel_getUid("alloc")), sel_getUid("init"));
        void (^completion)(id, id) = ^(id state, id err) {
            logLine([NSString stringWithFormat:@"fetchIconState -> state=%@ err=%@", state, err]);
        };
        ((void (*)(id, SEL, id, id))objc_msgSend)(ctrl, sel_getUid("fetchIconStateForVehicleID:completion:"), nil, completion);
    } @catch (__unused NSException *e) { NSLog(@"[carplayshell] icon-state probe exc"); }
}

- (UIImage *)iconForBundleID:(NSString *)bid {
    @try {
        CGFloat scale = [UIScreen mainScreen].scale;
        UIImage *(*f)(id, SEL, id, int, CGFloat) = (UIImage *(*)(id, SEL, id, int, CGFloat))objc_msgSend;
        return f([UIImage class], sel_getUid("_applicationIconImageForBundleIdentifier:format:scale:"), bid, 2, scale);
    } @catch (__unused NSException *e) { return nil; }
}

// LaunchServices (LSApplicationWorkspace) is nil inside this app's sandbox, so to tell a
// real app from an absent one we compare its icon against the generic placeholder icon
// that _applicationIconImageForBundleIdentifier: returns for unknown bundle ids.
- (NSData *)placeholderIconData {
    UIImage *ph = [self iconForBundleID:@"com.max.__not_a_real_app__"];
    return ph ? UIImagePNGRepresentation(ph) : nil;
}

- (NSString *)displayNameForBundleID:(NSString *)bid {
    // Normalize known codenames to their user-facing names.
    static NSDictionary *pretty = nil;
    if (!pretty) pretty = @{
        @"com.apple.MobileSMS": @"Messages", @"com.apple.mobilephone": @"Phone",
        @"com.apple.mobilesafari": @"Safari", @"com.apple.mobilecal": @"Calendar",
        @"com.apple.mobiletimer": @"Clock", @"com.apple.mobilenotes": @"Notes",
        @"com.apple.mobileslideshow": @"Photos", @"com.apple.weather": @"Weather",
        @"com.apple.Home": @"Home", @"com.waze.iphone": @"Waze",
        @"com.google.ios.youtube": @"YouTube", @"com.spotify.client": @"Spotify",
        @"com.apple.tv": @"TV", @"com.apple.Music": @"Music",
    };
    NSString *p = pretty[bid];
    if (p) return p;
    @try {
        id ws = ((id (*)(id, SEL))objc_msgSend)(objc_getClass("LSApplicationWorkspace"), sel_getUid("defaultWorkspace"));
        id proxy = ((id (*)(id, SEL, id))objc_msgSend)(ws, sel_getUid("applicationProxyForIdentifier:"), bid);
        id name = proxy ? ((id (*)(id, SEL))objc_msgSend)(proxy, sel_getUid("localizedName")) : nil;
        if ([name isKindOfClass:[NSString class]]) return name;
    } @catch (__unused NSException *e) {}
    return [[bid componentsSeparatedByString:@"."] lastObject] ?: bid;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self layoutGrid];
}


- (void)layoutGrid {
    for (UIView *v in [self.view.subviews copy]) if (v.tag >= 1000) [v removeFromSuperview];

    CGFloat tile = 74, gapX = 30, gapY = 24, labelH = 16;
    NSMutableArray *avail = [NSMutableArray array];
    NSData *phData = [self placeholderIconData];
    for (NSString *bid in self.bundleIDs) {
        UIImage *icon = [self iconForBundleID:bid];
        if (!icon) continue;
        if (phData && [UIImagePNGRepresentation(icon) isEqualToData:phData]) continue; // absent app → generic placeholder
        [avail addObject:@{ @"bid": bid, @"icon": icon }];
    }
    logLine([NSString stringWithFormat:@"%lu/%lu curated icons available", (unsigned long)avail.count, (unsigned long)self.bundleIDs.count]);

    int cols = 5;
    int n = (int)avail.count;
    if (n == 0) return;
    int rows = (n + cols - 1) / cols;
    CGFloat cellW = tile + gapX, cellH = tile + labelH + gapY;
    CGFloat gridW = cols * cellW - gapX;
    CGFloat gridH = rows * cellH - gapY;
    CGFloat startX = (self.view.bounds.size.width - gridW) / 2;
    CGFloat startY = (self.view.bounds.size.height - gridH) / 2 + 12;

    for (int i = 0; i < n; i++) {
        int r = i / cols, c = i % cols;
        CGFloat x = startX + c * cellW, y = startY + r * cellH;
        NSDictionary *d = avail[i];

        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        b.tag = 1000 + i;
        b.frame = CGRectMake(x, y, tile, tile);
        [b setImage:d[@"icon"] forState:UIControlStateNormal];
        b.imageView.contentMode = UIViewContentModeScaleAspectFill;
        b.layer.cornerRadius = 16;
        b.layer.cornerCurve = kCACornerCurveContinuous;
        b.clipsToBounds = YES;
        objc_setAssociatedObject(b, &kBidKey, d[@"bid"], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [b addTarget:self action:@selector(tileTapped:) forControlEvents:UIControlEventTouchUpInside];
        [self.view addSubview:b];

        UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(x - gapX / 2, y + tile + 2, tile + gapX, labelH)];
        lbl.tag = 1500 + i;
        lbl.text = [self displayNameForBundleID:d[@"bid"]];
        lbl.textColor = [UIColor whiteColor];
        lbl.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
        lbl.textAlignment = NSTextAlignmentCenter;
        [self.view addSubview:lbl];
    }
}

- (void)tileTapped:(UIButton *)b {
    NSString *bid = objc_getAssociatedObject(b, &kBidKey);
    logLine([NSString stringWithFormat:@"host %@", bid]);
    @try {
        // Ask the carplayhost SpringBoard tweak to host this app's live scene on-screen.
        id dnc = ((id (*)(id, SEL))objc_msgSend)(objc_getClass("NSDistributedNotificationCenter"), sel_getUid("defaultCenter"));
        ((void (*)(id, SEL, id, id, id, BOOL))objc_msgSend)(dnc,
            sel_getUid("postNotificationName:object:userInfo:deliverImmediately:"),
            @"com.max.carplayhost.open", (id)nil, @{ @"identifier": bid }, (BOOL)YES);
    } @catch (__unused NSException *e) {}
}

@end

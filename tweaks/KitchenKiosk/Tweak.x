#import <Foundation/Foundation.h>
#import <dlfcn.h>

// ─── KitchenKiosk ────────────────────────────────────────────────────────────
// Injected into SpringBoard. The device sleeps / auto-locks NORMALLY (per your
// Auto-Lock setting, e.g. via AutoLockPicker) — we intentionally do NOT keep it
// awake.
//
// KIOSK LOCK (opt-in): if /var/jb/etc/kitchenkiosk.on exists, auto-launch
// KitchenHub and keep it foreground (re-launch if you leave) — but only while
// the device is UNLOCKED, so it never fights the lock screen or wakes a sleeping
// panel. Gated by the flag file so it never traps you in the app while you're
// developing:
//     ssh root@ipad 'touch /var/jb/etc/kitchenkiosk.on'   (rm to disable)
// ─────────────────────────────────────────────────────────────────────────────

@interface SBLockScreenManager : NSObject
+ (instancetype)sharedInstance;
- (BOOL)isUILocked;
@end

static int (*ksLaunch)(CFStringRef, Boolean) = NULL;           // SBSLaunchApplicationWithIdentifier
static CFStringRef (*ksFrontmost)(void) = NULL;                 // SBSCopyFrontmostApplicationDisplayIdentifier

static NSString * const kBundle = @"com.max.kitchenhub";
static NSString * const kFlag   = @"/var/jb/etc/kitchenkiosk.on";

static BOOL kioskEnabled(void) {
    return [[NSFileManager defaultManager] fileExistsAtPath:kFlag];
}

static BOOL deviceUnlocked(void) {
    SBLockScreenManager *m = [%c(SBLockScreenManager) sharedInstance];
    return m ? ![m isUILocked] : YES;
}

static NSString *frontmostBundle(void) {
    if (!ksFrontmost) return nil;
    CFStringRef f = ksFrontmost();
    return f ? (__bridge_transfer NSString *)f : nil;
}

static void enforce(void) {
    if (!kioskEnabled() || !ksLaunch) return;     // kiosk-lock is opt-in
    if (!deviceUnlocked()) return;                // let it sleep / don't fight the lock screen
    NSString *fg = frontmostBundle();
    if (![fg isEqualToString:kBundle]) {
        NSLog(@"[KitchenKiosk] relaunching %@ (front=%@)", kBundle, fg);
        ksLaunch((__bridge CFStringRef)kBundle, false);
    }
}

%hook SpringBoard
- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    [NSTimer scheduledTimerWithTimeInterval:5.0 repeats:YES block:^(NSTimer *t) { enforce(); }];
    // First kiosk launch after boot, once SpringBoard has settled.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ enforce(); });
}
%end

%ctor {
    void *h = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices",
                     RTLD_LAZY);
    if (h) {
        ksLaunch = (int (*)(CFStringRef, Boolean))dlsym(h, "SBSLaunchApplicationWithIdentifier");
        ksFrontmost = (CFStringRef (*)(void))dlsym(h, "SBSCopyFrontmostApplicationDisplayIdentifier");
    }
    NSLog(@"[KitchenKiosk] loaded (launch=%p frontmost=%p)", ksLaunch, ksFrontmost);
    %init;
}

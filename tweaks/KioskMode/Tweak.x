#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <dlfcn.h>

// ─── KioskMode ───────────────────────────────────────────────────────────────
// Injected into SpringBoard. Locks the device to ONE app (a "kiosk"): auto-
// launches it and re-launches it if you leave — but only while the device is
// UNLOCKED, so it never fights the lock screen or wakes a sleeping panel. The
// device still sleeps / auto-locks NORMALLY (per your Auto-Lock setting).
//
// All behaviour is driven by a config plist that the KioskMode app writes:
//     /var/mobile/Library/Preferences/com.max.kioskmode.plist
// SpringBoard and the app both run as `mobile`, so they share it directly.
//
//   enabled        BOOL    master switch — kiosk is armed
//   targetBundleID STRING  the app to lock to
//   escapeMethod   STRING  "off" | "volumeUpTriple" | "volumeDownTriple"
//   paused         BOOL    runtime: escape gesture flips this; when YES the
//                          kiosk stops enforcing so you can use the device
//
// Escape: perform the chosen volume pattern (triple-press within ~1.4s) to
// toggle `paused`. A short haptic confirms. Nothing is enforced until you arm
// it in the app, so it can never trap you unexpectedly.
// ─────────────────────────────────────────────────────────────────────────────

@interface SBLockScreenManager : NSObject
+ (instancetype)sharedInstance;
- (BOOL)isUILocked;
@end

static int (*ksLaunch)(CFStringRef, Boolean) = NULL;   // SBSLaunchApplicationWithIdentifier
static CFStringRef (*ksFrontmost)(void) = NULL;         // SBSCopyFrontmostApplicationDisplayIdentifier

// NOT com.max.kioskmode.plist: that filename is the KioskMode *app's* own
// CFPreferences domain, so cfprefsd caches it at app launch and flushes stale
// values back over the app's direct writes (silently re-arming a toggled-off
// lock). A non-domain filename keeps cfprefsd out; app + tweak own it with plain
// file I/O. Must stay in lockstep with KioskConfig.path in the app.
static NSString * const kCfgPath =
    @"/var/mobile/Library/Preferences/com.max.kioskmode.shared.plist";
static NSString * const kOwnBundle = @"com.max.kioskmode";
static const char *kLogPath = "/var/mobile/kioskmode.log";

// Lightweight file log (SpringBoard runs as `mobile`, which owns /var/mobile).
// Readable over SSH for headless debugging of the volume-escape path.
static void kmLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    FILE *f = fopen(kLogPath, "a");
    if (f) { fprintf(f, "%.2f %s\n", CFAbsoluteTimeGetCurrent(), msg.UTF8String); fclose(f); }
    NSLog(@"[KioskMode] %@", msg);
}

// Cached config, refreshed by the enforcement timer (staleness ≤ tick interval).
static NSDictionary *gCfg = nil;
static const NSTimeInterval kTick = 2.5;

static void reloadConfig(void) {
    gCfg = [NSDictionary dictionaryWithContentsOfFile:kCfgPath] ?: @{};
}

static BOOL cfgBool(NSString *key)   { return [gCfg[key] boolValue]; }
static NSString *cfgStr(NSString *k) { id v = gCfg[k]; return [v isKindOfClass:NSString.class] ? v : nil; }

static BOOL deviceUnlocked(void) {
    SBLockScreenManager *m = [%c(SBLockScreenManager) sharedInstance];
    return m ? ![m isUILocked] : YES;
}

static NSString *frontmostBundle(void) {
    if (!ksFrontmost) return nil;
    CFStringRef f = ksFrontmost();
    return f ? (__bridge_transfer NSString *)f : nil;
}

// Flip `paused` and persist it so the app's UI and the next boot agree.
static void togglePaused(void) {
    reloadConfig();   // read the freshest config first, so writing `paused` back
                      // doesn't clobber an `enabled`/target the app just changed
    BOOL now = !cfgBool(@"paused");
    NSMutableDictionary *m = [gCfg mutableCopy];
    m[@"paused"] = @(now);
    [m writeToFile:kCfgPath atomically:YES];
    gCfg = m;
    AudioServicesPlaySystemSound(1519);   // light "actuate" haptic as confirmation
    kmLog(@"escape gesture → paused=%d", now);
}

static void enforce(void) {
    reloadConfig();
    if (!cfgBool(@"enabled") || cfgBool(@"paused")) return;   // disarmed or paused
    if (!ksLaunch) return;
    NSString *target = cfgStr(@"targetBundleID");
    if (target.length == 0) return;                            // nothing configured
    if (!deviceUnlocked()) return;                             // let it sleep / don't fight lock screen
    NSString *fg = frontmostBundle();
    // Never fight the KioskMode app itself — it's the escape hatch for changing
    // settings or turning the lock off, so it must stay reachable.
    if ([fg isEqualToString:kOwnBundle]) return;
    if (![fg isEqualToString:target]) {
        NSLog(@"[KioskMode] relaunching %@ (front=%@)", target, fg);
        ksLaunch((__bridge CFStringRef)target, false);
    }
}

// ─── Volume-pattern escape detection ─────────────────────────────────────────
// Count same-direction presses inside a sliding window; three → escape.
static const NSTimeInterval kEscapeWindow = 2.0;
#define kEscapeCount 3
static CFTimeInterval gPresses[kEscapeCount];   // ring of recent matching presses
static int gPressHead = 0;

static void registerPress(BOOL isUp) {
    NSString *method = cfgStr(@"escapeMethod");
    BOOL wantUp   = [method isEqualToString:@"volumeUpTriple"];
    BOOL wantDown = [method isEqualToString:@"volumeDownTriple"];
    kmLog(@"press up=%d method=%@ head=%d", isUp, method, gPressHead);
    if (!((wantUp && isUp) || (wantDown && !isUp))) return;    // not the escape direction

    CFTimeInterval now = CFAbsoluteTimeGetCurrent();
    gPresses[gPressHead % kEscapeCount] = now;
    gPressHead++;
    if (gPressHead < kEscapeCount) return;

    // Oldest of the last kEscapeCount presses must be within the window.
    CFTimeInterval oldest = gPresses[gPressHead % kEscapeCount];
    if (now - oldest <= kEscapeWindow) {
        gPressHead = 0;                                        // consume the burst
        togglePaused();
    }
}

// On iPadOS 17 a hardware volume press dispatches through
// _sendVolumeButtonDownForIncrease:modifiers: (fires once per physical press,
// even at min/max volume where the value-change methods stay silent). The
// increaseVolume/decreaseVolume hooks are kept only for diagnostics.
%hook SBVolumeControl
- (void)_sendVolumeButtonDownForIncrease:(BOOL)increase modifiers:(unsigned long long)mods {
    %orig;
    registerPress(increase);
}
- (void)increaseVolume { %orig; kmLog(@"increaseVolume (value method)"); }
- (void)decreaseVolume { %orig; kmLog(@"decreaseVolume (value method)"); }
%end

%hook SpringBoard
- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    reloadConfig();
    [NSTimer scheduledTimerWithTimeInterval:kTick repeats:YES
                                      block:^(NSTimer *t) { enforce(); }];
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
    kmLog(@"loaded (launch=%p frontmost=%p)", ksLaunch, ksFrontmost);
    %init;
}

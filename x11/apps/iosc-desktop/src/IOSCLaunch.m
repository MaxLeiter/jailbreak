// IOSCLaunch.m — the per-app home-screen launcher stub for the iosc desktop.
//
// One tiny UIKit binary, copied verbatim into every generated launcher .app bundle.
// It does NOT know which Linux app it launches at compile time; it reads its own
// bundle's Info.plist at runtime (IOSCExec / IOSCAppID / IOSCName), so the SAME
// signed Mach-O drives gnome-console, gnome-calculator, nautilus, ... — the bundle
// differs only in Info.plist + icon. (See x11/docs/iosc-desktop-env.md.)
//
// Flow on every foreground (first tap AND every re-tap):
//   1. read IOSCExec/IOSCAppID from Info.plist
//   2. connect to the root ioscd daemon at /var/jb/tmp/ioscd.sock or /var/tmp/ioscd.sock
//   3. send  "LAUNCH\t<app_id>\t<exec>\n"
//   4. ioscd ensures iosc is up, foregrounds Xios.app (the on-screen display),
//      and either execs <exec> as a new Wayland client or raises the existing
//      window whose app_id matches (second-tap => raise, not duplicate).
// The launcher never execs the Linux app itself: that would inherit this app's
// iOS sandbox. ioscd runs outside the sandbox (root LaunchDaemon) and does it.
//
// We deliberately do NOT exit(): a clean process is cheaper than risking the
// FrontBoard relaunch throttle (>=3 crashes), and ioscd's uiopen pulls Xios to
// the front anyway, backgrounding us. A re-tap re-activates us -> didBecomeActive
// fires again -> another LAUNCH -> ioscd raises the live window.
//
// Standalone: no dependency on any other app/tweak in this repo.

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <string.h>
#include <errno.h>

static NSArray<NSString *> *iosc_daemon_socket_candidates(void)
{
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    NSString *runtimeTmp = NSProcessInfo.processInfo.environment[@"XIOS_RUNTIME_TMP"];
    if (runtimeTmp.length > 0) {
        [paths addObject:[runtimeTmp stringByAppendingPathComponent:@"ioscd.sock"]];
    }
    [paths addObject:@"/var/jb/tmp/ioscd.sock"];
    [paths addObject:@"/var/tmp/ioscd.sock"];
    return paths;
}

// Send one LAUNCH request to ioscd. Best-effort: any failure just means the
// daemon isn't installed/running yet, which we surface on the splash label.
static BOOL iosc_send_launch(NSString *appID, NSString *exec, NSString **errOut)
{
    int fd = -1;
    NSString *lastPath = nil;
    int lastErr = ENOENT;
    for (NSString *path in iosc_daemon_socket_candidates()) {
        fd = socket(AF_UNIX, SOCK_STREAM, 0);
        if (fd < 0) { if (errOut) *errOut = @"socket() failed"; return NO; }

        struct sockaddr_un addr;
        memset(&addr, 0, sizeof(addr));
        addr.sun_family = AF_UNIX;
        strncpy(addr.sun_path, path.fileSystemRepresentation, sizeof(addr.sun_path) - 1);
        if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) == 0) {
            lastPath = path;
            lastErr = 0;
            break;
        }
        lastPath = path;
        lastErr = errno;
        close(fd);
        fd = -1;
    }
    if (lastErr != 0) {
        if (errOut) {
            *errOut = [NSString stringWithFormat:@"ioscd not reachable at %@ (%s)",
                       lastPath ?: @"known sockets", strerror(lastErr)];
        }
        if (fd >= 0) close(fd);
        return NO;
    }

    // Field-separated line; <exec> is the remainder so it may contain spaces.
    NSString *line = [NSString stringWithFormat:@"LAUNCH\t%@\t%@\n",
                      appID ?: @"", exec ?: @""];
    NSData *out = [line dataUsingEncoding:NSUTF8StringEncoding];
    const uint8_t *p = out.bytes; size_t left = out.length;
    while (left > 0) {
        ssize_t n = write(fd, p, left);
        if (n <= 0) { if (errOut) *errOut = @"write to ioscd failed"; close(fd); return NO; }
        p += n; left -= (size_t)n;
    }

    // Read a short ack ("LAUNCHED\n" / "RAISED\n" / "ERR ...\n"); non-fatal.
    char buf[256]; ssize_t n = read(fd, buf, sizeof(buf) - 1);
    if (n > 0) { buf[n] = 0; }
    close(fd);
    return YES;
}

@interface IOSCAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) UILabel *status;
@property (nonatomic, copy)   NSString *appName;
@property (nonatomic, copy)   NSString *appID;
@property (nonatomic, copy)   NSString *exec;
@property (nonatomic, assign) BOOL launchedOnce;
@end

@implementation IOSCAppDelegate

- (BOOL)application:(UIApplication *)application
        didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    self.appName = info[@"IOSCName"] ?: info[@"CFBundleDisplayName"] ?: @"app";
    self.appID   = info[@"IOSCAppID"] ?: @"";
    self.exec    = info[@"IOSCExec"]  ?: @"";

    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UIViewController *vc = [UIViewController new];
    vc.view.backgroundColor = [UIColor colorWithRed:0.043 green:0.047 blue:0.078 alpha:1]; // #0b0c14

    UILabel *label = [[UILabel alloc] initWithFrame:vc.view.bounds];
    label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    label.textAlignment = NSTextAlignmentCenter;
    label.numberOfLines = 0;
    label.textColor = [UIColor colorWithRed:0.333 green:0.667 blue:1.0 alpha:1]; // #55aaff
    label.font = [UIFont systemFontOfSize:28 weight:UIFontWeightSemibold];
    label.text = [NSString stringWithFormat:@"Opening %@…", self.appName];
    [vc.view addSubview:label];
    self.status = label;

    self.window.rootViewController = vc;
    [self.window makeKeyAndVisible];
    return YES;
}

// Fires on first launch and on every re-foreground (re-tap). Idempotent on the
// daemon side: a repeat LAUNCH for a live app_id is a raise, not a duplicate.
- (void)applicationDidBecomeActive:(UIApplication *)application
{
    NSString *appID = self.appID, *exec = self.exec, *name = self.appName;
    if (exec.length == 0) {
        self.status.text = @"No IOSCExec in Info.plist";
        return;
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *err = nil;
        BOOL ok = iosc_send_launch(appID, exec, &err);
        dispatch_async(dispatch_get_main_queue(), ^{
            self.status.text = ok
                ? [NSString stringWithFormat:@"Opening %@…", name]
                : [NSString stringWithFormat:@"Could not reach the iosc desktop.\n%@", err];
        });
    });
}

@end

int main(int argc, char *argv[])
{
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([IOSCAppDelegate class]));
    }
}

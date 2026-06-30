// cpprobe — safe, read-only CarPlay session bring-up probe.
// Runs as a CLI tool over SSH (NOT a SpringBoard tweak) so it cannot respring-loop the device.
// Goal: de-risk P1 (session synthesis) — see what loads, what classes exist, what
// initForCarPlayShell/currentSession do, and which XPC service the session-request client wants.
//
// Deliberately does NOT call startSessionWithHost:/startAdvertising* (those have side effects).

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

static id CLS(const char *n) { return (id)objc_getClass(n); }
#define MSG  ((id (*)(id, SEL))objc_msgSend)
#define DESC(o) ((o) ? [[(o) description] UTF8String] : "(nil)")

static void dlopenfw(const char *path) {
    void *h = dlopen(path, RTLD_NOW);
    printf("  dlopen %-66s %s\n", path, h ? "OK" : dlerror());
}

int main(int argc, char **argv) {
    @autoreleasepool {
        printf("== cpprobe: CarPlay session bring-up probe ==\n\n");

        printf("== dlopen CarPlay frameworks ==\n");
        const char *fws[] = {
            "/System/Library/PrivateFrameworks/CarKit.framework/CarKit",
            "/System/Library/PrivateFrameworks/CarPlayServices.framework/CarPlayServices",
            "/System/Library/PrivateFrameworks/CarPlayUIServices.framework/CarPlayUIServices",
            "/System/Library/PrivateFrameworks/CarPlayUI.framework/CarPlayUI",
            "/System/Library/Frameworks/CarPlay.framework/CarPlay",
            NULL
        };
        for (int i = 0; fws[i]; i++) dlopenfw(fws[i]);

        printf("\n== class availability ==\n");
        const char *classes[] = {
            "CARSessionStatus", "CARSession", "CARSessionRequestClient", "CARSessionRequestHost",
            "CRCertificationOverridesClient", "CRSIconLayoutController", "CRSOpenApplicationService",
            "CRSUIWindow", "CRSUISystemWallpaperProvider", "CRSUIWallpaperPreferences", NULL
        };
        for (int i = 0; classes[i]; i++)
            printf("  %-34s %s\n", classes[i], objc_getClass(classes[i]) ? "present" : "MISSING");

        printf("\n== CARSessionStatus initForCarPlayShell ==\n");
        @try {
            id st = MSG(MSG(CLS("CARSessionStatus"), sel_getUid("alloc")), sel_getUid("initForCarPlayShell"));
            printf("  status         = %s\n", DESC(st));
            id sess = st ? MSG(st, sel_getUid("currentSession")) : nil;
            printf("  currentSession = %s\n", sess ? DESC(sess) : "(nil — no car connected, expected)");
        } @catch (NSException *e) { printf("  EXC: %s\n", [[e description] UTF8String]); }

        printf("\n== CARSessionRequestClient construct (no startSession) ==\n");
        @try {
            id rc = MSG(MSG(CLS("CARSessionRequestClient"), sel_getUid("alloc")), sel_getUid("init"));
            printf("  client            = %s\n", DESC(rc));
            id conn = rc ? MSG(rc, sel_getUid("serviceConnection")) : nil;
            printf("  serviceConnection = %s\n", DESC(conn));
        } @catch (NSException *e) { printf("  EXC: %s\n", [[e description] UTF8String]); }

        if (argc > 1 && strcmp(argv[1], "start") == 0) {
            printf("\n== ATTEMPT startSessionWithHost: (wiredCarPlaySimulator, stub ::1) ==\n");
            @try {
                SEL initSel = sel_getUid("initWithDisplayName:wiredIPv6Addresses:wirelessIPv6Addresses:port:carplayWiFiUUID:deviceIdentifier:publicKey:sourceVersion:supportsMutualAuthentication:authenticationCertificateSerial:pairedVehicleIdentifier:wiredCarPlaySimulator:");
                id host = MSG(CLS("CARSessionRequestHost"), sel_getUid("alloc"));
                host = ((id (*)(id, SEL, id, id, id, long long, id, id, id, id, BOOL, id, id, BOOL))objc_msgSend)(
                    host, initSel,
                    @"iPad CarPlay",      // displayName
                    @[@"::1"],            // wiredIPv6Addresses (loopback stub)
                    @[],                  // wirelessIPv6Addresses
                    (long long)7000,      // port
                    nil,                  // carplayWiFiUUID
                    @"cpprobe-device",    // deviceIdentifier
                    nil,                  // publicKey
                    @"1.0",               // sourceVersion
                    (BOOL)NO,             // supportsMutualAuthentication
                    nil,                  // authenticationCertificateSerial
                    nil,                  // pairedVehicleIdentifier
                    (BOOL)YES);           // wiredCarPlaySimulator
                printf("  host = %s\n", DESC(host));

                id rc = MSG(MSG(CLS("CARSessionRequestClient"), sel_getUid("alloc")), sel_getUid("init"));
                // Log args as raw pointers only — never deref (block signature is unconfirmed)
                void (^completion)(id, id) = ^(id a, id b) {
                    printf("  [completion] fired: arg0=%p arg1=%p\n", (__bridge void *)a, (__bridge void *)b);
                    NSLog(@"[cpprobe] startSession completion: arg0=%p arg1=%p", (__bridge void *)a, (__bridge void *)b);
                };
                ((void (*)(id, SEL, id, id, id))objc_msgSend)(
                    rc, sel_getUid("startSessionWithHost:requestIdentifier:completion:"),
                    host, @"cpprobe-req-1", completion);
                printf("  startSession called; spinning runloop 6s for async XPC reply...\n");
                [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:6.0]];
                printf("  runloop done\n");
            } @catch (NSException *e) { printf("  EXC: %s\n", [[e description] UTF8String]); }
        }

        printf("\n== done ==\n");
    }
    return 0;
}

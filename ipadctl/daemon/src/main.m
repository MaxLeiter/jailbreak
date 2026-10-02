// ipadctld - root daemon that implements the ipadctl HTTP API (see API.md) on
// top of the proven capture + HID core in ipadctl/core.
//
// Threading: every request handler runs on the main dispatch queue, which is
// also the serial "work" queue the HTTP layer funnels requests through. That
// serializes actions (one at a time, per the contract) and keeps UIScreen /
// FrontBoardServices reads on the main thread, matching the probe's proven
// call pattern. The process stays alive on dispatch_main().
#import <Foundation/Foundation.h>

#import "hid.h"
#import "http.h"
#import "log.h"
#import "server.h"
#import "spi.h"
#import "token.h"

#include <errno.h>
#include <string.h>
#include <unistd.h>

static NSString *const kDir = @"/var/jb/var/root/ipadctl";
static const int kPort = 8790;

// Raise this process's jetsam memory limit. Under launchd a "daemon"-category
// job gets a 6 MB per-process limit, which a single panel-sized capture
// IOSurface (~14 MB) blows instantly (JETSAM_REASON_MEMORY_PERPROCESSLIMIT).
// Needs com.apple.private.memorystatus. (The probe never hit this: it ran from
// an SSH shell, outside launchd's jetsam regime.)
extern int memorystatus_control(uint32_t command, int32_t pid, uint32_t flags, void *buffer, size_t buffersize);
#define IPC_MEMSTATUS_SET_HIGH_WATER_MARK 5  // active=inactive limit, non-fatal

static void raise_jetsam_limit(int mb) {
    int rc = memorystatus_control(IPC_MEMSTATUS_SET_HIGH_WATER_MARK, getpid(), (uint32_t)mb, NULL, 0);
    if (rc != 0)
        fprintf(stderr, "ipadctld: WARNING could not raise jetsam limit to %d MB: %s\n", mb, strerror(errno));
    else
        fprintf(stderr, "ipadctld: jetsam memory limit raised to %d MB\n", mb);
}

static void emit(id obj) {
    NSData *d = [NSJSONSerialization dataWithJSONObject:obj options:NSJSONWritingSortedKeys error:nil];
    NSString *s = d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : @"{}";
    fprintf(stdout, "%s\n", s.UTF8String);
    fflush(stdout);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        raise_jetsam_limit(300);  // before any capture surface is allocated

        if (!spi_load()) {
            fprintf(stderr, "ipadctld: private symbol resolution failed (see above)\n");
            return 1;
        }
        bool hid_ready = ipc_hid_init();
        if (!hid_ready) fprintf(stderr, "ipadctld: WARNING IOHIDEventSystemClientCreate failed; input will not work\n");

        NSString *err = nil;
        NSString *token = ipc_token_load_or_create(kDir, &err);
        if (!token) {
            fprintf(stderr, "ipadctld: %s\n", err.UTF8String);
            return 1;
        }
        ipc_log_open([kDir stringByAppendingPathComponent:@"actions.log"]);

        // Startup self-test (missing entitlements fail silently; this is how we notice).
        NSDictionary *selftest = ipc_selftest();
        ipc_log_note([NSString stringWithFormat:@"startup selftest %@ hid_ready=%d",
                                                 [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:selftest options:0 error:nil] encoding:NSUTF8StringEncoding], hid_ready]);
        emit(@{@"event" : @"startup", @"port" : @(kPort), @"hid_ready" : @(hid_ready), @"selftest" : selftest});

        NSString *serr = nil;
        if (!ipc_http_serve(kPort, dispatch_get_main_queue(), ipc_server_handler(token), &serr)) {
            fprintf(stderr, "ipadctld: cannot start HTTP server: %s\n", serr.UTF8String);
            ipc_log_note([NSString stringWithFormat:@"FATAL http server: %@", serr]);
            return 1;
        }
        ipc_log_note([NSString stringWithFormat:@"listening on :%d", kPort]);
        fprintf(stderr, "ipadctld: listening on :%d\n", kPort);
        (void)argc;
        (void)argv;
    }
    dispatch_main();
    return 0;
}

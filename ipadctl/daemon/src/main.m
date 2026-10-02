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

static NSString *const kDir = @"/var/jb/var/root/ipadctl";
static const int kPort = 8790;

static void emit(id obj) {
    NSData *d = [NSJSONSerialization dataWithJSONObject:obj options:NSJSONWritingSortedKeys error:nil];
    NSString *s = d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : @"{}";
    fprintf(stdout, "%s\n", s.UTF8String);
    fflush(stdout);
}

int main(int argc, char **argv) {
    @autoreleasepool {
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

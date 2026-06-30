// cphost <bundleid> | dismiss — post the carplayhost distributed notification (run over SSH to trigger hosting).
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>

int main(int argc, char **argv) {
    if (argc < 2) { printf("usage: cphost <bundleid> | dismiss\n"); return 1; }
    @autoreleasepool {
        id dnc = ((id (*)(id, SEL))objc_msgSend)(objc_getClass("NSDistributedNotificationCenter"), sel_getUid("defaultCenter"));
        if (!dnc) { printf("no NSDistributedNotificationCenter\n"); return 2; }
        NSString *name; NSDictionary *ui = nil;
        if (strcmp(argv[1], "dismiss") == 0) {
            name = @"com.max.carplayhost.dismiss";
        } else if (strcmp(argv[1], "dock") == 0) {
            name = @"com.max.carplayhost.dock";
        } else if (strcmp(argv[1], "nochrome") == 0) {
            name = @"com.max.carplayhost.nochrome";
        } else if (strcmp(argv[1], "resize") == 0 && argc >= 4) {
            name = @"com.max.carplayhost.resize";
            ui = @{ @"w": @(atof(argv[2])), @"h": @(atof(argv[3])) };
        } else {
            name = @"com.max.carplayhost.open";
            ui = @{ @"identifier": [NSString stringWithUTF8String:argv[1]] };
        }
        ((void (*)(id, SEL, id, id, id, BOOL))objc_msgSend)(dnc,
            sel_getUid("postNotificationName:object:userInfo:deliverImmediately:"), name, (id)nil, ui, (BOOL)YES);
        printf("posted %s %s\n", [name UTF8String], argc > 2 ? "" : (ui ? [ui[@"identifier"] UTF8String] : ""));
        return 0;
    }
}

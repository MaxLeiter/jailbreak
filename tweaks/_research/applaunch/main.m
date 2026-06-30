// applaunch <bundleid> — launch an installed app via SpringBoardServices (run over SSH).
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <dlfcn.h>

int main(int argc, char **argv) {
    if (argc < 2) { printf("usage: applaunch <bundleid>\n"); return 1; }
    void *h = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_NOW);
    if (!h) { printf("dlopen SBS failed: %s\n", dlerror()); return 2; }
    int (*SBSLaunch)(CFStringRef, Boolean) = dlsym(h, "SBSLaunchApplicationWithIdentifier");
    if (!SBSLaunch) { printf("no SBSLaunchApplicationWithIdentifier: %s\n", dlerror()); return 3; }
    CFStringRef bid = CFStringCreateWithCString(NULL, argv[1], kCFStringEncodingUTF8);
    int r = SBSLaunch(bid, false);
    printf("SBSLaunchApplicationWithIdentifier(%s) -> %d\n", argv[1], r);
    return r;
}

#import "apps.h"

#include <dlfcn.h>

// Minimal declarations for the private LSApplicationWorkspace API. Everything
// is resolved at runtime via NSClassFromString, so the binary links only
// against the public SDK.
@interface LSApplicationProxy : NSObject
@property (nonatomic, readonly) NSString *applicationIdentifier;
@property (nonatomic, readonly) NSString *localizedName;
@property (nonatomic, readonly) NSString *applicationType;  // User / System / Internal
@property (nonatomic, readonly) BOOL isLaunchProhibited;
- (NSArray *)appTags;
@end

@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (NSArray *)allApplications;
- (LSApplicationProxy *)applicationProxyForIdentifier:(NSString *)bundleID;
- (BOOL)openApplicationWithBundleID:(NSString *)bundleID;
- (BOOL)openURL:(NSURL *)url;
@end

static LSApplicationWorkspace *workspace(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // LSApplicationWorkspace lives in MobileCoreServices on iOS; load it so
        // NSClassFromString can find the class.
        dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_NOW);
    });
    Class cls = NSClassFromString(@"LSApplicationWorkspace");
    return cls ? [cls defaultWorkspace] : nil;
}

static bool is_visible(LSApplicationProxy *p) {
    NSString *type = p.applicationType;
    if (![type isEqualToString:@"User"] && ![type isEqualToString:@"System"]) return false;
    if (p.isLaunchProhibited) return false;
    @try {
        NSArray *tags = [p appTags];
        if ([tags containsObject:@"hidden"]) return false;
    } @catch (__unused id e) {
    }
    return p.localizedName.length > 0 && p.applicationIdentifier.length > 0;
}

NSArray<NSDictionary *> *ipc_apps_list(void) {
    LSApplicationWorkspace *ws = workspace();
    if (!ws) return @[];
    NSMutableArray *out = [NSMutableArray array];
    for (LSApplicationProxy *p in [ws allApplications]) {
        if (!is_visible(p)) continue;
        [out addObject:@{@"bundle_id" : p.applicationIdentifier, @"name" : p.localizedName}];
    }
    [out sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"name"] caseInsensitiveCompare:b[@"name"]];
    }];
    return out;
}

NSString *ipc_app_name(NSString *bundle_id) {
    if (bundle_id.length == 0) return nil;
    LSApplicationWorkspace *ws = workspace();
    if (!ws) return nil;
    @try {
        if ([ws respondsToSelector:@selector(applicationProxyForIdentifier:)]) {
            LSApplicationProxy *p = [ws applicationProxyForIdentifier:bundle_id];
            if (p.localizedName.length) return p.localizedName;
        }
    } @catch (__unused id e) {
    }
    for (LSApplicationProxy *p in [ws allApplications])
        if ([p.applicationIdentifier isEqualToString:bundle_id]) return p.localizedName;
    return nil;
}

bool ipc_app_open(NSString *bundle_id, NSString **err) {
    LSApplicationWorkspace *ws = workspace();
    if (!ws) { if (err) *err = @"LSApplicationWorkspace unavailable"; return false; }
    if (![ws respondsToSelector:@selector(openApplicationWithBundleID:)]) {
        if (err) *err = @"openApplicationWithBundleID: unavailable";
        return false;
    }
    BOOL ok = NO;
    @try {
        ok = [ws openApplicationWithBundleID:bundle_id];
    } @catch (id e) {
        if (err) *err = [NSString stringWithFormat:@"openApplicationWithBundleID threw: %@", e];
        return false;
    }
    if (!ok && err) *err = [NSString stringWithFormat:@"could not launch %@ (unknown bundle id or launch refused)", bundle_id];
    return ok;
}

bool ipc_url_open(NSString *url, NSString **err) {
    NSURL *u = [NSURL URLWithString:url];
    if (!u) { if (err) *err = @"malformed URL"; return false; }
    LSApplicationWorkspace *ws = workspace();
    if (!ws) { if (err) *err = @"LSApplicationWorkspace unavailable"; return false; }
    BOOL ok = NO;
    @try {
        ok = [ws openURL:u];
    } @catch (id e) {
        if (err) *err = [NSString stringWithFormat:@"openURL threw: %@", e];
        return false;
    }
    if (!ok && err) *err = [NSString stringWithFormat:@"no handler could open %@", url];
    return ok;
}

#import "XiosRootListController.h"

#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>
#import <errno.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <unistd.h>

static NSString *const XiosPrefsSocketPath = @"/var/jb/tmp/ioscd.sock";

@interface XiosLauncherApp : NSObject
@property (nonatomic, copy) NSString *appID;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *exec;
@property (nonatomic, copy) NSString *icon;
@property (nonatomic, copy) NSString *bundlePath;
@property (nonatomic) BOOL enabled;
@end

@implementation XiosLauncherApp
@end

@interface XiosRootListController ()
@property (nonatomic, copy) NSArray<XiosLauncherApp *> *apps;
@property (nonatomic, copy) NSString *statusText;
@end

@implementation XiosRootListController

- (instancetype)init {
    self = [super init];
    if (self) {
        _apps = @[];
        _statusText = @"Loading...";
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Xios";
}

- (NSMutableArray *)specifiers {
    if (!_specifiers) {
        [self reloadLauncherState];
        _specifiers = [self buildSpecifiers];
    }
    return _specifiers;
}

- (NSMutableArray *)buildSpecifiers {
    NSMutableArray *items = [NSMutableArray array];

    PSSpecifier *intro = [PSSpecifier groupSpecifierWithName:@"Home Screen Apps"];
    [intro setProperty:@"Installed desktop .desktop files can be exposed as individual iPad Home Screen apps. This pane talks to ioscd; changes apply on device." forKey:PSFooterTextGroupKey];
    [items addObject:intro];

    PSSpecifier *status = [PSSpecifier preferenceSpecifierNamed:self.statusText
                                                         target:self
                                                            set:nil
                                                            get:nil
                                                         detail:nil
                                                           cell:PSStaticTextCell
                                                           edit:nil];
    [status setProperty:@"status" forKey:PSIDKey];
    [items addObject:status];

    [items addObject:[self buttonNamed:@"Refresh" identifier:@"refresh" selector:@selector(refreshTapped:)]];

    PSSpecifier *syncGroup = [PSSpecifier groupSpecifierWithName:@"Sync"];
    [syncGroup setProperty:@"Dry run previews the bundles that would be created. Apply runs uicache and changes SpringBoard." forKey:PSFooterTextGroupKey];
    [items addObject:syncGroup];
    [items addObject:[self buttonNamed:@"Dry Run Native Apps" identifier:@"dry-native" selector:@selector(dryNativeTapped:)]];
    [items addObject:[self buttonNamed:@"Dry Run Classic Apps" identifier:@"dry-classic" selector:@selector(dryClassicTapped:)]];
    [items addObject:[self buttonNamed:@"Apply Native Apps..." identifier:@"apply-native" selector:@selector(applyNativeTapped:)]];
    [items addObject:[self buttonNamed:@"Apply Classic Apps..." identifier:@"apply-classic" selector:@selector(applyClassicTapped:)]];

    PSSpecifier *appsGroup = [PSSpecifier groupSpecifierWithName:@"Applications"];
    NSString *footer = self.apps.count
        ? @"Toggle apps off to keep them out of future syncs. Borderline helper entries such as servers can stay disabled."
        : @"No launcher candidates were returned by ioscd.";
    [appsGroup setProperty:footer forKey:PSFooterTextGroupKey];
    [items addObject:appsGroup];

    for (XiosLauncherApp *app in self.apps) {
        PSSpecifier *spec = [PSSpecifier preferenceSpecifierNamed:app.name
                                                          target:self
                                                             set:@selector(setLauncherEnabled:specifier:)
                                                             get:@selector(getLauncherEnabled:)
                                                          detail:nil
                                                            cell:PSSwitchCell
                                                            edit:nil];
        [spec setProperty:app.appID forKey:@"appID"];
        [spec setProperty:app.exec ?: @"" forKey:@"exec"];
        [spec setProperty:app.bundlePath ?: @"" forKey:@"bundlePath"];
        [items addObject:spec];
    }

    return items;
}

- (PSSpecifier *)buttonNamed:(NSString *)name identifier:(NSString *)identifier selector:(SEL)selector {
    PSSpecifier *spec = [PSSpecifier preferenceSpecifierNamed:name
                                                       target:self
                                                          set:nil
                                                          get:nil
                                                       detail:nil
                                                         cell:PSButtonCell
                                                         edit:nil];
    spec.buttonAction = selector;
    [spec setProperty:identifier forKey:PSIDKey];
    return spec;
}

- (void)refreshTapped:(PSSpecifier *)specifier {
    [self refreshSpecifiersWithStatus:@"Refreshing..."];
}

- (void)dryNativeTapped:(PSSpecifier *)specifier {
    [self runSyncNative:YES dryRun:YES];
}

- (void)dryClassicTapped:(PSSpecifier *)specifier {
    [self runSyncNative:NO dryRun:YES];
}

- (void)applyNativeTapped:(PSSpecifier *)specifier {
    [self confirmApplyNative:YES];
}

- (void)applyClassicTapped:(PSSpecifier *)specifier {
    [self confirmApplyNative:NO];
}

- (id)getLauncherEnabled:(PSSpecifier *)specifier {
    NSString *appID = [specifier propertyForKey:@"appID"];
    for (XiosLauncherApp *app in self.apps) {
        if ([app.appID isEqualToString:appID]) return @(app.enabled);
    }
    return @NO;
}

- (void)setLauncherEnabled:(id)value specifier:(PSSpecifier *)specifier {
    NSString *appID = [specifier propertyForKey:@"appID"];
    if (![appID length]) return;
    BOOL enabled = [value boolValue];
    NSString *verb = enabled ? @"APP_ENABLE" : @"APP_DISABLE";
    NSArray<NSString *> *lines = [self sendIOSCDLine:[NSString stringWithFormat:@"%@\t%@\n", verb, appID]];
    NSString *last = lines.lastObject ?: @"";
    if ([last isEqualToString:@"APPS_END\t0"]) {
        self.statusText = [NSString stringWithFormat:@"%@ %@", enabled ? @"Enabled" : @"Disabled", appID];
    } else {
        self.statusText = [NSString stringWithFormat:@"Toggle failed: %@", lines.firstObject ?: @"ioscd unavailable"];
    }
    [self refreshSpecifiersWithStatus:self.statusText];
}

- (void)confirmApplyNative:(BOOL)native {
    NSString *mode = native ? @"native" : @"classic";
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"Apply %@ apps?", mode]
                                                                   message:@"This creates or updates SpringBoard app bundles and runs uicache."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Apply"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(__unused UIAlertAction *action) {
        [self runSyncNative:native dryRun:NO];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)runSyncNative:(BOOL)native dryRun:(BOOL)dryRun {
    NSString *mode = native ? @"native" : @"classic";
    NSString *dry = dryRun ? @"dry" : @"apply";
    NSArray<NSString *> *lines = [self sendIOSCDLine:[NSString stringWithFormat:@"APPS_SYNC\t%@\t%@\n", mode, dry]];
    BOOL ok = [lines.lastObject isEqualToString:@"APPS_END\t0"];
    self.statusText = [NSString stringWithFormat:@"%@ %@ %@", dryRun ? @"Dry run" : @"Applied", mode, ok ? @"completed" : @"failed"];
    [self refreshSpecifiersWithStatus:self.statusText];
    [self showReportTitle:self.statusText lines:lines];
}

- (void)showReportTitle:(NSString *)title lines:(NSArray<NSString *> *)lines {
    NSString *message = lines.count ? [lines componentsJoinedByString:@"\n"] : @"No response from ioscd.";
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)refreshSpecifiersWithStatus:(NSString *)status {
    self.statusText = status ?: @"";
    [self reloadLauncherState];
    _specifiers = [self buildSpecifiers];
    [self reloadSpecifiers];
}

- (void)reloadLauncherState {
    NSArray<NSString *> *lines = [self sendIOSCDLine:@"APPS_LIST\n"];
    NSMutableArray<XiosLauncherApp *> *apps = [NSMutableArray array];
    for (NSString *line in lines) {
        if ([line hasPrefix:@"ERR "]) {
            self.statusText = line;
            break;
        }
        if ([line hasPrefix:@"APPS_END"]) break;
        NSArray<NSString *> *fields = [line componentsSeparatedByString:@"\t"];
        if (fields.count < 6) continue;
        XiosLauncherApp *app = [XiosLauncherApp new];
        app.appID = fields[0];
        app.name = fields[1];
        app.exec = fields[2];
        app.icon = fields[3];
        app.bundlePath = fields[4];
        app.enabled = ![fields[5].lowercaseString isEqualToString:@"disabled"];
        [apps addObject:app];
    }
    [apps sortUsingComparator:^NSComparisonResult(XiosLauncherApp *a, XiosLauncherApp *b) {
        return [a.name localizedCaseInsensitiveCompare:b.name];
    }];
    self.apps = apps;
    if (![self.statusText length] || [self.statusText isEqualToString:@"Loading..."] || [self.statusText isEqualToString:@"Refreshing..."]) {
        self.statusText = [NSString stringWithFormat:@"%lu launcher candidates", (unsigned long)apps.count];
    }
}

- (NSArray<NSString *> *)sendIOSCDLine:(NSString *)line {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return @[ @"ERR socket failed" ];

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    const char *path = XiosPrefsSocketPath.UTF8String;
    if (strlen(path) >= sizeof(addr.sun_path)) {
        close(fd);
        return @[ @"ERR socket path too long" ];
    }
    strncpy(addr.sun_path, path, sizeof(addr.sun_path) - 1);
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        NSString *err = [NSString stringWithFormat:@"ERR connect %@: %s", XiosPrefsSocketPath, strerror(errno)];
        close(fd);
        return @[ err ];
    }

    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    const uint8_t *bytes = data.bytes;
    NSUInteger sent = 0;
    while (sent < data.length) {
        ssize_t n = write(fd, bytes + sent, data.length - sent);
        if (n > 0) sent += (NSUInteger)n;
        else if (n < 0 && errno == EINTR) continue;
        else {
            close(fd);
            return @[ @"ERR write failed" ];
        }
    }
    shutdown(fd, SHUT_WR);

    NSMutableData *reply = [NSMutableData data];
    uint8_t buf[4096];
    while (reply.length < (1024 * 1024)) {
        ssize_t n = read(fd, buf, sizeof(buf));
        if (n > 0) [reply appendBytes:buf length:(NSUInteger)n];
        else if (n < 0 && errno == EINTR) continue;
        else break;
    }
    close(fd);

    NSString *text = [[NSString alloc] initWithData:reply encoding:NSUTF8StringEncoding] ?: @"";
    NSArray<NSString *> *rawLines = [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    for (NSString *raw in rawLines) {
        if (raw.length) [lines addObject:raw];
    }
    return lines.count ? lines : @[ @"ERR empty response" ];
}

@end

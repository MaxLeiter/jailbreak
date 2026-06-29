#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <math.h>

//  DBSSettingsController applies the value via:
//    -[DBSSettingsController setScreenLock:specifier:]
//      -> [[MCProfileConnection sharedConnection] setValue:@(sec)
//            forSetting:MCFeatureAutoLockTime]   (no clamping; -1/Never -> INT_MAX)

@interface PSSpecifier : NSObject
@end

@interface DBSSettingsController : UIViewController
- (void)setScreenLock:(id)value specifier:(id)specifier;
- (id)screenLock:(id)specifier;
@end

@interface DBSAutoLockViewController : UIViewController
- (PSSpecifier *)specifier;
- (DBSSettingsController *)alp_parent;
- (NSInteger)alp_currentSeconds;
- (void)alp_neverToggled:(UISwitch *)sw;
- (void)alp_applyTapped:(UIButton *)sender;
- (NSString *)alp_titleForSeconds:(NSInteger)secs;
- (void)alp_refreshParentForSeconds:(NSInteger)secs;
@end

static void alp_log(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *line = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[AutoLockPicker] %@", line);   // visible via Console/idevicesyslog only
}

static char kPickerKey;
static char kNeverKey;

%hook DBSAutoLockViewController

- (void)viewDidLoad {
    %orig;
    alp_log(@"viewDidLoad; view=%@", NSStringFromClass([self.view class]));

    UIView *root = self.view;

    // Opaque cover so the underlying preset list is fully replaced (no overlap).
    UIView *cover = [[UIView alloc] initWithFrame:root.bounds];
    cover.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    cover.backgroundColor = [UIColor systemGroupedBackgroundColor];
    [root addSubview:cover];

    UILabel *title = [UILabel new];
    title.text = @"Lock the screen after";
    title.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    title.textColor = [UIColor labelColor];

    UIDatePicker *picker = [UIDatePicker new];
    picker.datePickerMode = UIDatePickerModeCountDownTimer;
    picker.minuteInterval = 1;
    objc_setAssociatedObject(self, &kPickerKey, picker, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // "Never" row
    UILabel *neverLabel = [UILabel new];
    neverLabel.text = @"Never";
    neverLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    neverLabel.textColor = [UIColor labelColor];
    UISwitch *neverSwitch = [UISwitch new];
    [neverSwitch addTarget:self action:@selector(alp_neverToggled:)
          forControlEvents:UIControlEventValueChanged];
    objc_setAssociatedObject(self, &kNeverKey, neverSwitch, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UIStackView *neverRow = [[UIStackView alloc] initWithArrangedSubviews:@[neverLabel, neverSwitch]];
    neverRow.axis = UILayoutConstraintAxisHorizontal;
    neverRow.spacing = 12;

    UIButton *setBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [setBtn setTitle:@"  Set Auto-Lock  " forState:UIControlStateNormal];
    setBtn.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    setBtn.backgroundColor = [UIColor systemBlueColor];
    [setBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    setBtn.layer.cornerRadius = 12;
    [setBtn addTarget:self action:@selector(alp_applyTapped:)
       forControlEvents:UIControlEventTouchUpInside];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[title, picker, neverRow, setBtn]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 20;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [cover addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.centerXAnchor constraintEqualToAnchor:cover.centerXAnchor],
        [stack.topAnchor constraintEqualToAnchor:cover.safeAreaLayoutGuide.topAnchor constant:28],
        [stack.leadingAnchor constraintGreaterThanOrEqualToAnchor:cover.leadingAnchor constant:16],
        [stack.trailingAnchor constraintLessThanOrEqualToAnchor:cover.trailingAnchor constant:-16],
    ]];

    // initialize from the current value
    NSInteger cur = [self alp_currentSeconds];
    if (cur < 0) {                  // Never
        neverSwitch.on = YES;
        picker.countDownDuration = 15 * 60;
        picker.enabled = NO;
    } else {
        picker.countDownDuration = (cur >= 60) ? cur : (15 * 60);
    }
    alp_log(@"header installed; cur=%ld", (long)cur);
}

%new
- (DBSSettingsController *)alp_parent {
    Class cls = objc_getClass("DBSSettingsController");
    for (UIViewController *vc in self.navigationController.viewControllers)
        if ([vc isKindOfClass:cls]) return (DBSSettingsController *)vc;
    return nil;
}

%new
- (NSInteger)alp_currentSeconds {
    @try {
        DBSSettingsController *parent = [self alp_parent];
        if ([parent respondsToSelector:@selector(screenLock:)]) {
            id v = ((id (*)(id, SEL, id))objc_msgSend)(parent, @selector(screenLock:), self.specifier);
            return [v integerValue];
        }
    } @catch (NSException *e) { alp_log(@"currentSeconds EXC: %@", e); }
    return 0;
}

%new
- (NSString *)alp_titleForSeconds:(NSInteger)secs {
    if (secs < 0) return @"Never";
    NSInteger h = secs / 3600, m = (secs % 3600) / 60, s = secs % 60;
    NSMutableArray *parts = [NSMutableArray array];
    if (h) [parts addObject:[NSString stringWithFormat:@"%ld hr", (long)h]];
    if (m) [parts addObject:[NSString stringWithFormat:@"%ld min", (long)m]];
    if (s) [parts addObject:[NSString stringWithFormat:@"%ld sec", (long)s]];
    return parts.count ? [parts componentsJoinedByString:@" "] : @"0 sec";
}

%new
- (void)alp_refreshParentForSeconds:(NSInteger)secs {
    DBSSettingsController *parent = [self alp_parent];
    if (!parent) return;
    @try {
        NSNumber *key = @(secs);
        NSString *title = [self alp_titleForSeconds:secs];
        // Make the custom value "known" so the row can render it.
        id valsObj = [parent valueForKey:@"_autoLockValues"];
        if ([valsObj isKindOfClass:[NSArray class]] && ![valsObj containsObject:key]) {
            NSMutableArray *mv = [valsObj mutableCopy];
            NSUInteger neverIdx = [mv indexOfObject:@(-1)];
            if (neverIdx != NSNotFound) [mv insertObject:key atIndex:neverIdx];
            else [mv addObject:key];
            [parent setValue:mv forKey:@"_autoLockValues"];
        }
        for (NSString *dk in @[@"_autoLockTitleDictionary", @"_localizedAutoLockTitleDictionary"]) {
            id d = [parent valueForKey:dk];
            if ([d isKindOfClass:[NSDictionary class]] && ![d objectForKey:key]) {
                NSMutableDictionary *md = [d mutableCopy];
                md[key] = title;
                [parent setValue:md forKey:dk];
            }
        }
        if ([parent respondsToSelector:@selector(updateAutoLockSpecifier)])
            ((void (*)(id, SEL))objc_msgSend)(parent, @selector(updateAutoLockSpecifier));
        alp_log(@"refreshed parent row -> %@", title);
    } @catch (NSException *e) { alp_log(@"refresh EXC: %@", e); }
}

%new
- (void)alp_neverToggled:(UISwitch *)sw {
    UIDatePicker *picker = objc_getAssociatedObject(self, &kPickerKey);
    picker.enabled = !sw.on;
}

%new
- (void)alp_applyTapped:(UIButton *)sender {
    UIDatePicker *picker = objc_getAssociatedObject(self, &kPickerKey);
    UISwitch *neverSwitch = objc_getAssociatedObject(self, &kNeverKey);
    NSInteger secs;
    if (neverSwitch.on) {
        secs = -1;                                   // Never
    } else {
        secs = (NSInteger)llround(picker.countDownDuration);
        if (secs < 30) secs = 30;
    }

    DBSSettingsController *parent = [self alp_parent];
    alp_log(@"apply %ld; parent=%@", (long)secs, NSStringFromClass([parent class]));
    @try {
        if ([parent respondsToSelector:@selector(setScreenLock:specifier:)]) {
            ((void (*)(id, SEL, id, id))objc_msgSend)(parent, @selector(setScreenLock:specifier:),
                                                      @(secs), self.specifier);
        } else {
            alp_log(@"apply FAILED: parent has no setScreenLock:specifier:");
        }
    } @catch (NSException *e) { alp_log(@"apply EXC: %@", e); }

    // Refresh the Display & Brightness row so its label reflects the new value
    // (our custom values aren't in the system's title map by default).
    [self alp_refreshParentForSeconds:secs];

    NSString *human = (secs < 0) ? @"Never"
        : (secs % 60 == 0 ? [NSString stringWithFormat:@"%ld min", (long)(secs/60)]
                          : [NSString stringWithFormat:@"%ld min %ld s", (long)(secs/60), (long)(secs%60)]);
    UIAlertController *a = [UIAlertController alertControllerWithTitle:nil
                            message:[NSString stringWithFormat:@"Auto-Lock: %@", human]
                            preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:a animated:YES completion:^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.9 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [a dismissViewControllerAnimated:YES completion:^{
                [self.navigationController popViewControllerAnimated:YES];
            }];
        });
    }];
}

%end

%ctor {
    void *h = dlopen("/System/Library/PrivateFrameworks/Settings/"
                     "DisplayAndBrightnessSettings.framework/DisplayAndBrightnessSettings", RTLD_LAZY);
    Class c = objc_getClass("DBSAutoLockViewController");
    alp_log(@"ctor in '%@': dlopen=%p class=%@",
            [[NSProcessInfo processInfo] processName], h, c);
    %init;
}

// PullToRespring2 — pull down at the top of Settings to respring.
//
// A rootless, modern-iOS refresh of Noah Saso's PullToRespring
// (https://github.com/NoahSaso/PullToRespring, MIT).
//
// Two injection contexts, one dylib (see the filter plist):
//   - Preferences (Settings): attach a UIRefreshControl to the root list, plus
//     a scroll watcher that fires on a deliberate over-pull. Either posts a
//     Darwin notification. (The stock UIRefreshControl trigger alone is hard to
//     reach because the Settings search bar competes for the same downward pull.)
//   - SpringBoard: observe that notification and respring via FBSSystemService.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <notify.h>

static NSString *const kPTR2Notification = @"com.max.pulltorespring2.respring";

// Points of over-pull past the resting top that trigger a respring. Deliberate
// but not a marathon; tune here if it feels too easy/hard.
static const CGFloat kPTR2PullThreshold = 92.0;

// ---------------------------------------------------------------------------
// Settings side
// ---------------------------------------------------------------------------

@interface PSListController : UIViewController
- (UITableView *)table;
@end

// Watches a scroll view's contentOffset and posts the respring notification once
// the user drags past the threshold and releases. Decouples the trigger from
// UIRefreshControl's (hard-to-reach) internal threshold.
@interface PTR2PullWatcher : NSObject
@property (nonatomic, weak) UIScrollView *scrollView;
@property (nonatomic, assign) BOOL armed;
@property (nonatomic, assign) BOOL fired;
@end

@implementation PTR2PullWatcher
- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary *)change
                       context:(void *)context {
	UIScrollView *sv = self.scrollView;
	if (!sv) return;
	CGFloat pulled = -(sv.contentOffset.y + sv.adjustedContentInset.top);
	if (pulled <= 4.0) { self.armed = NO; self.fired = NO; return; }
	if (sv.isDragging && pulled >= kPTR2PullThreshold) self.armed = YES;
	if (!sv.isDragging && self.armed && !self.fired) {
		self.fired = YES;
		self.armed = NO;
		notify_post("com.max.pulltorespring2.respring");
	}
}
- (void)dealloc {
	// Weak ref is nil once the table has deallocated, so this only fires while
	// the table is still alive — avoids the "observer deallocated" KVO crash.
	[_scrollView removeObserver:self forKeyPath:@"contentOffset"];
}
@end

%group Settings

// PSUIPrefsListController is the root Settings list controller on modern iOS.
%hook PSUIPrefsListController

- (void)viewDidAppear:(BOOL)animated {
	%orig;

	UITableView *table = [(PSListController *)self table];
	if (table && !table.refreshControl) {
		UIRefreshControl *rc = [[UIRefreshControl alloc] init];
		rc.attributedTitle = [[NSAttributedString alloc] initWithString:@"Pull to respring"];
		[rc addTarget:self
		       action:@selector(ptr2_pulled:)
		     forControlEvents:UIControlEventValueChanged];
		table.refreshControl = rc;

		PTR2PullWatcher *watcher = [PTR2PullWatcher new];
		watcher.scrollView = table;
		[table addObserver:watcher forKeyPath:@"contentOffset" options:0 context:NULL];
		objc_setAssociatedObject(table, _cmd, watcher, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	}
}

%new
- (void)ptr2_pulled:(UIRefreshControl *)rc {
	[rc endRefreshing];
	notify_post("com.max.pulltorespring2.respring");
}

%end

%end // group Settings

// ---------------------------------------------------------------------------
// SpringBoard side
// ---------------------------------------------------------------------------

// Modern respring: FBSSystemService + SBSRelaunchAction (RestartRenderServer).
// The old _relaunchSpringBoardNow / _tearDownNow paths are dead on iOS 17.
@interface SBSRelaunchAction : NSObject
+ (id)actionWithReason:(NSString *)reason options:(NSUInteger)options targetURL:(id)url;
@end

@interface FBSSystemService : NSObject
+ (id)sharedService;
- (void)sendActions:(NSSet *)actions withResult:(id)result;
@end

// Legacy fallback for older iOS.
@interface SpringBoard : UIApplication
- (void)_relaunchSpringBoardNow;
@end

// SBSRelaunchActionOptionsRestartRenderServer == 1 << 2
static const NSUInteger kPTR2RestartRenderServer = (1 << 2);

static void ptr2_respring(CFNotificationCenterRef center, void *observer,
                          CFStringRef name, const void *object,
                          CFDictionaryRef userInfo) {
	Class relaunchCls = objc_getClass("SBSRelaunchAction");
	Class sysSvcCls = objc_getClass("FBSSystemService");
	if (relaunchCls && sysSvcCls) {
		id action = [relaunchCls actionWithReason:@"PullToRespring2"
		                                  options:kPTR2RestartRenderServer
		                                targetURL:nil];
		[[sysSvcCls sharedService] sendActions:[NSSet setWithObject:action]
		                            withResult:nil];
		return;
	}

	SpringBoard *sb = (SpringBoard *)[UIApplication sharedApplication];
	if ([sb respondsToSelector:@selector(_relaunchSpringBoardNow)]) {
		[sb _relaunchSpringBoardNow];
	}
}

%ctor {
	NSString *bundleID = NSBundle.mainBundle.bundleIdentifier;
	if ([bundleID isEqualToString:@"com.apple.springboard"]) {
		CFNotificationCenterAddObserver(
			CFNotificationCenterGetDarwinNotifyCenter(), NULL,
			ptr2_respring, (__bridge CFStringRef)kPTR2Notification, NULL,
			CFNotificationSuspensionBehaviorDeliverImmediately);
	} else {
		%init(Settings);
	}
}

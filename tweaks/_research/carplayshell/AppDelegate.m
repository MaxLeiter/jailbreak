#import "AppDelegate.h"
#import "RootViewController.h"

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.rootViewController = [RootViewController new];
    [self.window makeKeyAndVisible];
    NSLog(@"[carplayshell] didFinishLaunching, window=%@", self.window);
    return YES;
}

@end

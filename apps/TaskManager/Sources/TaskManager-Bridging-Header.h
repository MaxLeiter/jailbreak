#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

// libproc / sysctl / mach process-introspection ABI (no UIKit dependency).
#import "TMProcInfo.h"

// Private MobileCoreServices interfaces for mapping a pid's executable path to
// an installed app's identity (display name + icon). Same technique KioskMode
// uses for its app picker — resolved dynamically at runtime, undefined at link.
@interface LSApplicationProxy : NSObject
@property (nonatomic, readonly) NSString *applicationIdentifier;
@property (nonatomic, readonly) NSString *localizedName;
@property (nonatomic, readonly) NSString *applicationType;   // "User" / "System" / "Internal"
@property (nonatomic, readonly) NSURL *bundleURL;            // on-disk .app bundle
@property (nonatomic, readonly) NSURL *bundleExecutableURL;  // the Mach-O inside it
@end

@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (NSArray<LSApplicationProxy *> *)allApplications;
@end

// Private UIKit call that renders any installed app's real Home Screen icon.
// AppIcon.swift guards this with -respondsToSelector: before use.
@interface UIImage (TMPrivate)
+ (UIImage *)_applicationIconImageForBundleIdentifier:(NSString *)bundleIdentifier
                                               format:(int)format
                                                scale:(CGFloat)scale;
@end

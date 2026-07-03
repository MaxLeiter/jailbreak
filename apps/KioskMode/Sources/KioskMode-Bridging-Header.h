#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

// Private MobileCoreServices interfaces for enumerating installed apps.
// Used by InstalledApps.swift to build the target-app picker.

@interface LSApplicationProxy : NSObject
@property (nonatomic, readonly) NSString *applicationIdentifier;
@property (nonatomic, readonly) NSString *localizedName;
@property (nonatomic, readonly) NSString *applicationType;   // "User" / "System" / "Internal"
@end

@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (NSArray<LSApplicationProxy *> *)allApplications;
@end

// Private UIKit call that renders any installed app's real Home Screen icon.
// AppIcon.swift guards this with -respondsToSelector: before use.
@interface UIImage (KMPrivate)
+ (UIImage *)_applicationIconImageForBundleIdentifier:(NSString *)bundleIdentifier
                                               format:(int)format
                                                scale:(CGFloat)scale;
@end

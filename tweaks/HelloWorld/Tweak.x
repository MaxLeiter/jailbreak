#import <Foundation/Foundation.h>

// A .x file is processed by Logos (Theos's preprocessor). %hook / %orig / %end
// expand into MobileSubstrate / ElleKit method hooks at compile time.
//
// NOTE: This tweak is deliberately LOG-ONLY. An earlier version popped a
// UIAlertController from a UIWindow we created ourselves. On iOS 13+ a UIWindow
// created WITHOUT a UIWindowScene can still become the key window — it then
// swallows all touch input while displaying nothing, which freezes the UI even
// though SpringBoard is alive. Lesson for SpringBoard UI tweaks: always attach
// windows to an active UIWindowScene (or present on an existing window). For a
// "hello world" we don't need UI at all — verify via `bin/logs.sh HelloWorld`.

%hook SpringBoard

// Runs once, right after SpringBoard finishes launching (every boot / respring).
- (void)applicationDidFinishLaunching:(id)application {
    %orig; // always call the original implementation first

    // Proof-of-life. Stream it from your Mac with:  bin/logs.sh HelloWorld
    NSLog(@"[HelloWorld] SpringBoard finished launching — tweak is loaded! 👋");
}

%end

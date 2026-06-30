#import <Foundation/Foundation.h>
%hook SpringBoard
- (void)applicationDidFinishLaunching:(id)a {
  %orig;
  [@"injtest loaded\n" writeToFile:@"/tmp/injtest.log" atomically:YES encoding:NSUTF8StringEncoding error:nil];
}
%end

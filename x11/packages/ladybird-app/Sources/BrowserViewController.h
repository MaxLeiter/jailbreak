#pragma once
#import <UIKit/UIKit.h>
#import "LadybirdWebView.h"

// Minimal M0 browser chrome: one tab, address bar, back/forward/reload. See .mm.
@interface BrowserViewController : UIViewController <LadybirdWebViewObserver, UITextFieldDelegate>
@end

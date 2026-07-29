/*
 * LadybirdWebView — the UIView that hosts a WebContent view. UIKit analogue of
 * UI/AppKit/Interface/LadybirdWebView (an NSView). Objective-C++ (.mm) so it can
 * #include the LibWebView C++ headers and #import UIKit in one translation unit.
 *
 * Owns a LadybirdIOS::WebViewBridge (the ViewImplementation). Release builds present
 * WebContent's IOSurface through CAMetalLayer/Metal and fail closed if that path is
 * unavailable. The CGImage layer exists only in explicit diagnostic CPU builds.
 * Forwards UITouch/UIKey/gestures into the bridge.
 */
#import <UIKit/UIKit.h>

@class LadybirdWebView;

@protocol LadybirdWebViewObserver <NSObject>
- (void)webView:(LadybirdWebView*)webView didChangeTitle:(NSString*)title;
- (void)webView:(LadybirdWebView*)webView didChangeURL:(NSString*)url;
- (void)webViewDidStartLoading:(LadybirdWebView*)webView;
- (void)webViewDidFinishLoading:(LadybirdWebView*)webView;
@end

@interface LadybirdWebView : UIView <UIKeyInput>

@property (nonatomic, weak) id<LadybirdWebViewObserver> observer;

// Navigation surface the BrowserViewController drives (thin wrappers over the bridge).
- (void)loadURL:(NSString*)urlString;
- (void)reload;
- (void)goBack;
- (void)goForward;
- (void)zoomIn;
- (void)zoomOut;
- (void)resetZoom;

@end

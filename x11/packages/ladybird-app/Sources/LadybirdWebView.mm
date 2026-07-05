/*
 * LadybirdWebView.mm — see LadybirdWebView.h. Ported method-for-method from
 * UI/AppKit/Interface/LadybirdWebView.mm.
 *
 * Present:  on_ready_to_paint -> presentMetalFrame (IOSurface->MTLTexture blit) when a
 *           Metal device and IOSurface-backed front buffer exist; otherwise a CPU layer
 *           displays the same bitmap through CGImage.
 * Input:    UITouch -> Web::MouseEvent (tap=click, pan=MouseMove/drag), UIPanGesture ->
 *           MouseWheel scroll, UILongPress -> Secondary click/context menu, UIPinch ->
 *           Web::PinchEvent, UIKey (hardware) + UIKeyInput (software) -> Web::KeyEvent.
 *
 * Input-enum spellings and event field order are now confirmed against the engine tree
 * (92b0257): see Event.mm / IOSWebViewBridge.cpp.
 */
#import "LadybirdWebView.h"
#import "IOSWebViewBridge.h"
#import "Event.h"
#import "LBTrace.h"

#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreGraphics/CoreGraphics.h>
// iOS ships IOSurfaceRef.h (the C API used by the zero-copy present path) but NOT the macOS
// umbrella <IOSurface/IOSurface.h>. Include the concrete header directly.
#import <IOSurface/IOSurfaceRef.h>

#include <LibGfx/Bitmap.h>
#include <LibGfx/SharedImageBuffer.h>
#include <LibURL/URL.h>
#include <AK/ByteString.h>
#include <AK/Utf16String.h>
#include <LibWeb/HTML/VisibilityState.h>
#include <LibWeb/Page/InputEvent.h>
#include <LibWebView/Application.h>
#include <LibWebView/SearchEngine.h>
#include <LibWebView/URL.h>

// Custom CALayer subclass for the CPU path: its -display forwards to the view so we
// can push a CGImage. (AppKit uses LadybirdWebViewContentLayer the same way.)
@interface LadybirdContentLayer : CALayer
@property (nonatomic, weak) LadybirdWebView* owner;
@end

@interface LadybirdWebView ()
- (void)syncKeyboardWithFocusedInputSoon;
- (void)syncKeyboardWithAutofocusSoon;
- (void)syncKeyboardWithFocusedInputSoonAllowingProactive:(BOOL)allowProactive reason:(char const*)reason;
@end

static BOOL lb_string_has_whitespace(NSString* text)
{
    return [text rangeOfCharacterFromSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].location != NSNotFound;
}

static BOOL lb_string_has_url_scheme(NSString* text)
{
    NSRange colon = [text rangeOfString:@":"];
    if (colon.location == NSNotFound || colon.location == 0)
        return NO;

    NSUInteger firstSeparator = text.length;
    for (NSString* separator in @[ @"/", @"?", @"#" ]) {
        NSRange range = [text rangeOfString:separator];
        if (range.location != NSNotFound)
            firstSeparator = MIN(firstSeparator, range.location);
    }
    if (colon.location > firstSeparator)
        return NO;

    NSString* candidate = [text substringToIndex:colon.location];
    NSCharacterSet* invalidSchemeCharacters =
        [[NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+-."] invertedSet];
    if ([candidate rangeOfCharacterFromSet:invalidSchemeCharacters].location != NSNotFound)
        return NO;

    // Treat host:port inputs as bare addresses, not custom URL schemes. Common user-entered
    // schemes do not contain dots; hostnames commonly do.
    return [candidate rangeOfString:@"."].location == NSNotFound;
}

static NSString* lb_normalized_address_bar_input(NSString* input)
{
    NSString* trimmed = [input stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!trimmed.length || lb_string_has_whitespace(trimmed) || lb_string_has_url_scheme(trimmed))
        return trimmed;

    if ([trimmed hasPrefix:@"//"])
        return [@"https:" stringByAppendingString:trimmed];

    BOOL startsWithWWW = trimmed.length >= 4
        && [trimmed rangeOfString:@"www." options:NSCaseInsensitiveSearch range:NSMakeRange(0, 4)].location == 0;
    BOOL looksLikeHost = startsWithWWW
        || [trimmed rangeOfString:@"."].location != NSNotFound
        || [trimmed rangeOfString:@":"].location != NSNotFound;

    if (looksLikeHost)
        return [@"https://" stringByAppendingString:trimmed];

    return trimmed;
}

@implementation LadybirdWebView {
    OwnPtr<LadybirdIOS::WebViewBridge> _bridge;

    // Metal present path (preferred, zero-copy)
    id<MTLDevice> _metalDevice;
    id<MTLCommandQueue> _metalQueue;
    CAMetalLayer* _metalLayer;

    // CPU present path (fallback)
    LadybirdContentLayer* _cpuLayer;

    BOOL _usingMetal;
}

+ (Class)layerClass { return [CALayer class]; } // real layer chosen in -init below

- (instancetype)initWithFrame:(CGRect)frame
{
    if ((self = [super initWithFrame:frame])) {
        self.multipleTouchEnabled = YES;
        self.userInteractionEnabled = YES;
        self.contentMode = UIViewContentModeTopLeft;

        CGFloat scale = self.window.screen.scale ?: UIScreen.mainScreen.scale;

        // Create the bridge (ViewImplementation). Viewport in logical points; the bridge
        // scales by DPR to device pixels internally.
        Gfx::IntSize viewport { (int)frame.size.width, (int)frame.size.height };
        _bridge = LadybirdIOS::WebViewBridge::create(viewport, (float)scale);

        [self setupPresentLayer:scale];
        lb_trace("LadybirdWebView init: present layer up (metal=%d)", (int)_usingMetal);
        [self setupBridgeCallbacks];
        [self setupGestures];

        // Spawn WebContent + connect (async_set_viewport happens via handle_resize).
        lb_trace("LadybirdWebView init: calling initialize_client (spawn WebContent)");
        _bridge->initialize_client(); // defaults to CreateNewClient::Yes (see bridge override)
        lb_trace("LadybirdWebView init: initialize_client returned");

        // CRITICAL: ViewImplementation::m_system_visibility_state defaults to Hidden, and the HTML
        // event loop's "update the rendering" step (EventLoop::update_the_rendering) filters out every
        // Document whose visibility state is "hidden" -> paint_next_frame() never runs -> WebContent
        // never records/ships a display list -> the Compositor never presents a frame -> the content
        // area stays blank. Every upstream frontend (AppKit/Qt/GTK/Android) explicitly marks its view
        // Visible; the UIKit frontend must too. Setting it here (before the first document loads) means
        // the initial document is created Visible; didMoveToWindow keeps it in sync with occlusion.
        _bridge->set_system_visibility_state(Web::HTML::VisibilityState::Visible);
        lb_trace("LadybirdWebView init: system visibility -> Visible");
    }
    return self;
}

#pragma mark - Present layer setup

- (void)setupPresentLayer:(CGFloat)scale
{
    _metalDevice = MTLCreateSystemDefaultDevice(); // needs the GPU IOKit entitlements
    if (_metalDevice) {
        _usingMetal = YES;
        _metalQueue = [_metalDevice newCommandQueue];
        _metalLayer = [CAMetalLayer layer];
        _metalLayer.device = _metalDevice;
        _metalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        _metalLayer.framebufferOnly = NO; // we blitCopy into the drawable
        _metalLayer.contentsScale = scale;
        _metalLayer.contentsGravity = kCAGravityTopLeft;
        [self.layer addSublayer:_metalLayer];
    } else {
        // Fakesigned app without the GPU entitlement, or Metal unavailable: CPU-only path.
        _usingMetal = NO;
    }

    _cpuLayer = [LadybirdContentLayer layer];
    _cpuLayer.owner = self;
    _cpuLayer.contentsGravity = kCAGravityTopLeft;
    _cpuLayer.contentsScale = scale;
    _cpuLayer.hidden = _usingMetal;
    [self.layer addSublayer:_cpuLayer];
}

#pragma mark - Bridge callbacks

- (void)setupBridgeCallbacks
{
    __weak LadybirdWebView* weakSelf = self;

    _bridge->on_ready_to_paint = [weakSelf]() {
        static int s_paint_count = 0;
        if (s_paint_count++ < 3)
            lb_trace("on_ready_to_paint fired (#%d)", s_paint_count);
        LadybirdWebView* strongSelf = weakSelf;
        if (!strongSelf) return;
        if (strongSelf->_usingMetal)
            [strongSelf presentMetalFrame];
        else
            [strongSelf->_cpuLayer setNeedsDisplay];
    };

    _bridge->on_title_change = [weakSelf](Utf16String const& title) {
        LadybirdWebView* s = weakSelf;
        [s.observer webView:s didChangeTitle:@(title.to_byte_string().characters())];
    };
    _bridge->on_url_change = [weakSelf](URL::URL const& url) {
        LadybirdWebView* s = weakSelf;
        [s.observer webView:s didChangeURL:@(url.serialize().to_byte_string().characters())];
    };
    _bridge->on_load_start = [weakSelf](URL::URL const&, bool) {
        LadybirdWebView* s = weakSelf;
        [s.observer webViewDidStartLoading:s];
    };
    _bridge->on_load_finish = [weakSelf](URL::URL const&) {
        LadybirdWebView* s = weakSelf;
        [s.observer webViewDidFinishLoading:s];
        [s syncKeyboardWithAutofocusSoon];
    };
    // on_cursor_change, on_request_alert/confirm/prompt, on_favicon_change, etc. wire
    // to UIKit here as the chrome matures (see AppKit setWebViewCallbacks for the full list).
}

#pragma mark - Metal present (zero-copy IOSurface blit)

- (void)presentMetalFrame
{
    auto paintable = _bridge->paintable();
    if (!paintable.bitmap)
        return;

    // The shared bitmap is IOSurface-backed; wrap it as an MTLTexture and blit into the drawable.
    IOSurfaceRef surface = (IOSurfaceRef)_bridge->front_iosurface();
    if (!surface) { // no IOSurface handle -> fall back to CPU CGImage this frame
        static int s_cpu_fallback_count = 0;
        if (s_cpu_fallback_count++ < 3)
            lb_trace("present: no IOSurface; CPU layer fallback");
        _cpuLayer.hidden = NO;
        [_cpuLayer setNeedsDisplay];
        return;
    }

    CGSize dpx = CGSizeMake(paintable.size.width(), paintable.size.height());
    _metalLayer.drawableSize = dpx;

    MTLTextureDescriptor* desc =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                           width:(NSUInteger)dpx.width
                                                          height:(NSUInteger)dpx.height
                                                       mipmapped:NO];
    desc.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> src = [_metalDevice newTextureWithDescriptor:desc iosurface:surface plane:0];
    if (!src) {
        lb_trace("present: newTextureWithDescriptor:iosurface failed; CPU layer fallback");
        _cpuLayer.hidden = NO;
        [_cpuLayer setNeedsDisplay];
        return;
    }

    id<CAMetalDrawable> drawable = [_metalLayer nextDrawable];
    if (!drawable) {
        lb_trace("present: nextDrawable failed; CPU layer fallback");
        _cpuLayer.hidden = NO;
        [_cpuLayer setNeedsDisplay];
        return;
    }

    static int s_metal_present_count = 0;
    if (s_metal_present_count++ < 3)
        lb_trace("present: IOSurface Metal blit %.0fx%.0f", dpx.width, dpx.height);
    _cpuLayer.hidden = YES;

    id<MTLCommandBuffer> cb = [_metalQueue commandBuffer];
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    MTLSize copySize = MTLSizeMake(MIN(src.width, drawable.texture.width),
                                   MIN(src.height, drawable.texture.height), 1);
    [blit copyFromTexture:src sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
               sourceSize:copySize toTexture:drawable.texture destinationSlice:0
         destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
    [blit endEncoding];
    [cb presentDrawable:drawable];
    [cb commit];
}

#pragma mark - CPU present (CGImage -> layer.contents)

- (void)displayContentLayer:(CALayer*)layer
{
    auto paintable = _bridge->paintable();
    if (!paintable.bitmap)
        return;
    Gfx::Bitmap const* bmp = paintable.bitmap;

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGDataProviderRef provider =
        CGDataProviderCreateWithData(nullptr, bmp->scanline_u8(0), bmp->size_in_bytes(), nullptr);
    // BGRA8 premultiplied, little-endian: byteOrder32Little + alphaFirst (matches AppKit).
    CGImageRef image = CGImageCreate(paintable.size.width(), paintable.size.height(), 8, 32,
        bmp->pitch(), cs,
        (CGBitmapInfo)(kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst),
        provider, nullptr, NO, kCGRenderingIntentDefault);
    layer.contents = (__bridge_transfer id)image;
    CGDataProviderRelease(provider);
    CGColorSpaceRelease(cs);
}

#pragma mark - Layout / DPI

- (void)layoutSubviews
{
    [super layoutSubviews];
    _metalLayer.frame = self.bounds;
    _cpuLayer.frame = self.bounds;
    _bridge->set_viewport_rect(Gfx::IntRect { 0, 0, (int)self.bounds.size.width, (int)self.bounds.size.height });
}

- (void)didMoveToWindow
{
    [super didMoveToWindow];
    CGFloat scale = self.window.screen.scale;
    if (scale > 0) {
        _bridge->set_device_pixel_ratio((float)scale);
        _metalLayer.contentsScale = scale;
        _cpuLayer.contentsScale = scale;
    }
    // Keep the page's visibility state in sync with on-screen occlusion (mirrors AppKit's
    // handleVisibility:). Hidden pages are skipped by EventLoop::update_the_rendering, so a view
    // that is off-window must be Hidden and an on-window view must be Visible to paint.
    _bridge->set_system_visibility_state(self.window != nil
            ? Web::HTML::VisibilityState::Visible
            : Web::HTML::VisibilityState::Hidden);
}

#pragma mark - Input: touches

- (void)touchesBegan:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event
{
    UITouch* t = touches.anyObject;
    CGPoint p = [t locationInView:self];
    lb_trace("web touch begin %.1f,%.1f first=%d", p.x, p.y, self.isFirstResponder);
    _bridge->enqueue_input_event(LadybirdIOS::mouse_event_from_touch(self, t, Web::MouseEvent::Type::MouseDown, Web::UIEvents::MouseButton::Primary));
}
- (void)touchesMoved:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event
{
    UITouch* t = touches.anyObject;
    // A moving touch with a button held reads as a drag in web content.
    _bridge->enqueue_input_event(LadybirdIOS::mouse_event_from_touch(self, t, Web::MouseEvent::Type::MouseMove, Web::UIEvents::MouseButton::Primary));
}
- (void)touchesEnded:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event
{
    UITouch* t = touches.anyObject;
    CGPoint p = [t locationInView:self];
    lb_trace("web touch end %.1f,%.1f first=%d", p.x, p.y, self.isFirstResponder);
    _bridge->enqueue_input_event(LadybirdIOS::mouse_event_from_touch(self, t, Web::MouseEvent::Type::MouseUp, Web::UIEvents::MouseButton::Primary));
    [self ensureKeyboardResponder:"touch-end"];
    [self syncKeyboardWithFocusedInputSoon];
}
- (void)touchesCancelled:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event
{
    UITouch* t = touches.anyObject;
    _bridge->enqueue_input_event(LadybirdIOS::mouse_event_from_touch(self, t, Web::MouseEvent::Type::MouseUp, Web::UIEvents::MouseButton::Primary));
}

#pragma mark - Input: gestures (scroll / context / pinch)

- (void)setupGestures
{
    // Two-finger pan = scroll wheel. (One-finger drag stays a content drag/selection.)
    UIPanGestureRecognizer* pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onScroll:)];
    pan.minimumNumberOfTouches = 2;
    pan.maximumNumberOfTouches = 2;
    [self addGestureRecognizer:pan];

    UILongPressGestureRecognizer* lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(onLongPress:)];
    [self addGestureRecognizer:lp];

    UIPinchGestureRecognizer* pinch = [[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(onPinch:)];
    [self addGestureRecognizer:pinch];
}

- (void)onScroll:(UIPanGestureRecognizer*)g
{
    CGPoint delta = [g translationInView:self];
    [g setTranslation:CGPointZero inView:self];
    CGPoint at = [g locationInView:self];
    _bridge->enqueue_input_event(LadybirdIOS::wheel_event(self, at, -delta.x, -delta.y));
}

- (void)onLongPress:(UILongPressGestureRecognizer*)g
{
    if (g.state != UIGestureRecognizerStateBegan) return;
    CGPoint at = [g locationInView:self];
    // Long-press == right/secondary click -> LibWeb context menu request.
    _bridge->enqueue_input_event(LadybirdIOS::mouse_event_at(self, at, Web::MouseEvent::Type::MouseDown, Web::UIEvents::MouseButton::Secondary));
    _bridge->enqueue_input_event(LadybirdIOS::mouse_event_at(self, at, Web::MouseEvent::Type::MouseUp, Web::UIEvents::MouseButton::Secondary));
}

- (void)onPinch:(UIPinchGestureRecognizer*)g
{
    CGPoint at = [g locationInView:self];
    _bridge->enqueue_input_event(LadybirdIOS::pinch_event(self, at, g.scale));
    g.scale = 1.0;
}

#pragma mark - Input: keyboard (UIKeyInput = software; UIKey/pressesBegan = hardware)

- (BOOL)canBecomeFirstResponder { return YES; }
- (BOOL)hasText { return YES; }

- (BOOL)becomeFirstResponder
{
    BOOL ok = [super becomeFirstResponder];
    lb_trace("web becomeFirstResponder -> %d first=%d", ok, self.isFirstResponder);
    return ok;
}

- (BOOL)resignFirstResponder
{
    BOOL ok = [super resignFirstResponder];
    lb_trace("web resignFirstResponder -> %d first=%d", ok, self.isFirstResponder);
    return ok;
}

- (UITextAutocapitalizationType)autocapitalizationType { return UITextAutocapitalizationTypeNone; }
- (UITextAutocorrectionType)autocorrectionType { return UITextAutocorrectionTypeNo; }
- (UIKeyboardType)keyboardType { return UIKeyboardTypeDefault; }
- (UIReturnKeyType)returnKeyType { return UIReturnKeyDefault; }

- (void)ensureKeyboardResponder:(char const*)reason
{
    bool hasFocusedInput = _bridge->get_input_caret_rect().has_value();
    BOOL wasFirstResponder = self.isFirstResponder;
    BOOL becameFirstResponder = YES;
    if (!wasFirstResponder)
        becameFirstResponder = [self becomeFirstResponder];
    if (self.isFirstResponder)
        [self reloadInputViews];
    lb_trace("keyboard ensure reason=%s caret=%d was=%d now=%d became=%d",
        reason, hasFocusedInput, wasFirstResponder, self.isFirstResponder, becameFirstResponder);
}

- (void)syncKeyboardWithFocusedInputSoon
{
    [self syncKeyboardWithFocusedInputSoonAllowingProactive:YES reason:"touch"];
}

- (void)syncKeyboardWithAutofocusSoon
{
    [self syncKeyboardWithFocusedInputSoonAllowingProactive:NO reason:"autofocus"];
}

- (void)syncKeyboardWithFocusedInputSoonAllowingProactive:(BOOL)allowProactive reason:(char const*)reason
{
    __weak LadybirdWebView* weakSelf = self;
    int delays[] = { 80, 180, 400, 800, 1400 };
    for (int delay : delays) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
            LadybirdWebView* strongSelf = weakSelf;
            if (!strongSelf)
                return;

            // WebContent publishes this rect only while editable content owns focus. Prefer this
            // signal, but do not require it before becoming first responder: on iOS, the responder
            // handoff is what lets UIKit deliver software-keyboard input to the web view.
            bool hasFocusedInput = strongSelf->_bridge->get_input_caret_rect().has_value();
            bool shouldEnsure = hasFocusedInput || (allowProactive && !strongSelf.isFirstResponder);
            lb_trace("keyboard sync reason=%s delay=%d caret=%d first=%d proactive=%d ensure=%d",
                reason, delay, hasFocusedInput, strongSelf.isFirstResponder, allowProactive, shouldEnsure);
            if (shouldEnsure)
                [strongSelf ensureKeyboardResponder:hasFocusedInput ? reason : "no-caret-yet"];
        });
    }
}

- (void)insertText:(NSString*)text
{
    lb_trace("web insertText length=%lu first=%d", (unsigned long)text.length, self.isFirstResponder);
    auto utf8 = ByteString { text.length > 0 ? text.UTF8String : "" };
    _bridge->commit_text_from_input_method(Utf16String::from_utf8(utf8));
}
- (void)deleteBackward
{
    lb_trace("web deleteBackward first=%d", self.isFirstResponder);
    _bridge->enqueue_input_event(LadybirdIOS::key_event_backspace(Web::KeyEvent::Type::KeyDown));
}

- (void)pressesBegan:(NSSet<UIPress*>*)presses withEvent:(UIPressesEvent*)event
{
    for (UIPress* p in presses) {
        if (p.key)
            _bridge->enqueue_input_event(LadybirdIOS::key_event_from_uikey(p.key, Web::KeyEvent::Type::KeyDown));
    }
}
- (void)pressesEnded:(NSSet<UIPress*>*)presses withEvent:(UIPressesEvent*)event
{
    for (UIPress* p in presses) {
        if (p.key)
            _bridge->enqueue_input_event(LadybirdIOS::key_event_from_uikey(p.key, Web::KeyEvent::Type::KeyUp));
    }
}

#pragma mark - Navigation wrappers

- (void)loadURL:(NSString*)urlString
{
    NSString* raw = urlString ?: @"";
    NSString* normalized = lb_normalized_address_bar_input(raw);
    lb_trace("loadURL: raw=%s normalized=%s", raw.UTF8String, normalized.UTF8String);
    // Sanitize user input the way the AppKit/Qt address bars do: bare domains like
    // "github.com" get an "https://" scheme prepended, and non-URL text falls back to the
    // configured search engine. See WebView::sanitize_url / TabController.mm.
    auto input = StringView { normalized.UTF8String, strlen(normalized.UTF8String) };
    auto url = WebView::sanitize_url(input, WebView::Application::settings().search_engine());
    if (url.has_value())
        _bridge->load(url.value());
    else
        lb_trace("loadURL: sanitize_url produced no URL");
}
- (void)reload { _bridge->reload(); }
- (void)goBack { _bridge->traverse_the_history_by_delta(-1); }
- (void)goForward { _bridge->traverse_the_history_by_delta(1); }
- (void)zoomIn { _bridge->zoom_in(); }
- (void)zoomOut { _bridge->zoom_out(); }
- (void)resetZoom { _bridge->reset_zoom(); }

@end

@implementation LadybirdContentLayer
- (void)display { [self.owner displayContentLayer:self]; }
@end

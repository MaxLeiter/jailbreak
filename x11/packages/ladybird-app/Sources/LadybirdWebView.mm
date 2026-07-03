/*
 * LadybirdWebView.mm — see LadybirdWebView.h. Ported method-for-method from
 * UI/AppKit/Interface/LadybirdWebView.mm.
 *
 * Present:  on_ready_to_paint -> presentMetalFrame (IOSurface->MTLTexture blit) if a
 *           Metal device exists, else CALayer.contents = CGImage (CPU path).
 * Input:    UITouch -> Web::MouseEvent (tap=click, pan=MouseMove/drag), UIPanGesture ->
 *           MouseWheel scroll, UILongPress -> Secondary click/context menu, UIPinch ->
 *           Web::PinchEvent, UIKey (hardware) + UIKeyInput (software) -> Web::KeyEvent.
 *
 * Input-enum spellings and event field order are now confirmed against the engine tree
 * (92b0257): see Event.mm / IOSWebViewBridge.cpp. One engine gate remains — the shared
 * image buffer's IOSurface accessor is #ifdef AK_OS_MACOS only, so front_iosurface()
 * returns null on iOS until the engine M0 patch exposes it under AK_OS_IOS. When it does
 * not, presentMetalFrame's `if (!surface)` guard falls back to the CPU CGImage path.
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
#include <LibWeb/Page/InputEvent.h>

// Custom CALayer subclass for the CPU path: its -display forwards to the view so we
// can push a CGImage. (AppKit uses LadybirdWebViewContentLayer the same way.)
@interface LadybirdContentLayer : CALayer
@property (nonatomic, weak) LadybirdWebView* owner;
@end

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
        // Fakesigned app without the GPU entitlement, or Metal unavailable: CPU path.
        _usingMetal = NO;
        _cpuLayer = [LadybirdContentLayer layer];
        _cpuLayer.owner = self;
        _cpuLayer.contentsGravity = kCAGravityTopLeft;
        _cpuLayer.contentsScale = scale;
        [self.layer addSublayer:_cpuLayer];
    }
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
        [self.layer setNeedsDisplay];
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
    if (!src) return;

    id<CAMetalDrawable> drawable = [_metalLayer nextDrawable];
    if (!drawable) return;

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
}

#pragma mark - Input: touches

- (void)touchesBegan:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event
{
    UITouch* t = touches.anyObject;
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
    _bridge->enqueue_input_event(LadybirdIOS::mouse_event_from_touch(self, t, Web::MouseEvent::Type::MouseUp, Web::UIEvents::MouseButton::Primary));
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
- (BOOL)hasText { return NO; }

- (void)insertText:(NSString*)text
{
    _bridge->enqueue_input_event(LadybirdIOS::key_event_from_text(text, Web::KeyEvent::Type::KeyDown));
}
- (void)deleteBackward
{
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
    lb_trace("loadURL: %s", urlString.UTF8String);
    auto url = URL::create_with_url_or_path(ByteString(urlString.UTF8String));
    if (url.has_value())
        _bridge->load(url.value());
    else
        lb_trace("loadURL: URL parse FAILED");
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

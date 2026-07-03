/*
 * IOSWebViewBridge — the platform-agnostic LibWebView::ViewImplementation subclass
 * for the iOS/UIKit frontend. Ported from UI/AppKit/Interface/LadybirdWebViewBridge.h.
 *
 * This file is PURE C++ (compiles as .cpp, no UIKit) so it can be shared unchanged
 * with any future frontend. All the ObjC++ lives in LadybirdWebView.mm which owns an
 * instance of this class and wires its on_* callbacks to UIKit.
 *
 * Mirrors the three mandatory ViewImplementation overrides + update_zoom +
 * initialize_client, exactly like the AppKit bridge does.
 */
#pragma once

#include <LibGfx/Point.h>
#include <LibGfx/Rect.h>
#include <LibGfx/Size.h>
#include <LibWeb/PixelUnits.h>
#include <LibWebView/ViewImplementation.h>

namespace LadybirdIOS {

class WebViewBridge final : public WebView::ViewImplementation {
public:
    static NonnullOwnPtr<WebViewBridge> create(Gfx::IntSize viewport_size, float device_pixel_ratio);
    virtual ~WebViewBridge() override = default;

    // --- The three mandatory ViewImplementation overrides ---
    virtual Web::DevicePixelSize viewport_size() const override { return m_viewport_size.to_type<Web::DevicePixels>(); }
    virtual Gfx::IntPoint to_content_position(Gfx::IntPoint widget_position) const override;
    virtual Gfx::IntPoint to_widget_position(Gfx::IntPoint content_position) const override;

    // --- Usually-overridden ---
    virtual void update_zoom() override;
    // Default arg mirrors the base (ViewImplementation declares CreateNewClient::Yes as default);
    // lets external callers (LadybirdWebView.mm) invoke initialize_client() without naming the
    // protected CreateNewClient enum, exactly like the AppKit bridge.
    virtual void initialize_client(CreateNewClient = CreateNewClient::Yes) override;

    // --- Input: mirror the AppKit bridge's per-type overloads, which apply to_content_position
    //     (widget points -> device pixels) before forwarding to the base
    //     ViewImplementation::enqueue_input_event(Web::InputEvent). Without these, the base
    //     overload is selected and coordinates reach WebContent unscaled. ---
    void enqueue_input_event(Web::MouseEvent);
    void enqueue_input_event(Web::KeyEvent);
    void enqueue_input_event(Web::PinchEvent);

    // --- Driven by the UIView on layout / trait changes ---
    void set_viewport_rect(Gfx::IntRect); // logical points; scales by DPR internally, then handle_resize()
    void set_device_pixel_ratio(float);
    float inverse_device_pixel_ratio() const { return 1.0f / m_device_pixel_ratio; }

    // Convenience the host uses each frame: the front backing bitmap (BGRA8-premul) or a
    // backup, plus the IOSurface handle for the zero-copy Metal present path.
    struct Paintable {
        Gfx::Bitmap const* bitmap { nullptr };
        Gfx::IntSize size;
    };
    Paintable paintable() const;

    // The front backing store's IOSurface (as an opaque CF pointer, cast to IOSurfaceRef
    // by the host) for the zero-copy Metal present path. Null if the current buffer has no
    // IOSurface handle (fall back to the CPU CGImage path that frame).
    void* front_iosurface() const;

    // Fired by us after we adjust zoom so the host can update chrome.
    Function<void(double)> on_zoom_level_changed;

private:
    WebViewBridge(Gfx::IntSize viewport_size, float device_pixel_ratio);

    Gfx::IntSize m_viewport_size;
};

}

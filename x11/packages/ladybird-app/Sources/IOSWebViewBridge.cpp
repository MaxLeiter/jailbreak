/*
 * See IOSWebViewBridge.h. Ported from UI/AppKit/Interface/LadybirdWebViewBridge.cpp.
 *
 * ViewImplementation protected members used below are confirmed against
 * Libraries/LibWebView/ViewImplementation.h (engine 92b0257):
 *   m_client_state { front_bitmap { shared_image_buffer (OwnPtr<Gfx::SharedImageBuffer>),
 *                    last_painted_size }, has_usable_bitmap }, m_backup_shared_image_buffer,
 *   m_backup_bitmap_size, m_device_pixel_ratio, m_maximum_frames_per_second,
 *   device_pixel_ratio(), zoom_level(), handle_resize(), update_zoom(), initialize_client().
 * The one item that stays engine-gated is the IOSurface accessor — see front_iosurface().
 */
#include "IOSWebViewBridge.h"

#include <AK/Platform.h>
#include <LibGfx/Bitmap.h>
#include <LibGfx/SharedImageBuffer.h>
#include <LibWebView/Application.h>

namespace LadybirdIOS {

NonnullOwnPtr<WebViewBridge> WebViewBridge::create(Gfx::IntSize viewport_size, float device_pixel_ratio)
{
    return adopt_own(*new WebViewBridge(viewport_size, device_pixel_ratio));
}

WebViewBridge::WebViewBridge(Gfx::IntSize viewport_size, float device_pixel_ratio)
    : m_viewport_size(viewport_size)
{
    m_device_pixel_ratio = device_pixel_ratio;
    m_maximum_frames_per_second = 60; // A10; raise to 120 on ProMotion later.
}

Gfx::IntPoint WebViewBridge::to_content_position(Gfx::IntPoint widget_position) const
{
    // Widget space is logical points; content space is device pixels.
    return widget_position.scaled(device_pixel_ratio(), device_pixel_ratio());
}

Gfx::IntPoint WebViewBridge::to_widget_position(Gfx::IntPoint content_position) const
{
    return content_position.scaled(inverse_device_pixel_ratio(), inverse_device_pixel_ratio());
}

void WebViewBridge::update_zoom()
{
    WebView::ViewImplementation::update_zoom();
    if (on_zoom_level_changed)
        on_zoom_level_changed(zoom_level());
}

void WebViewBridge::set_device_pixel_ratio(float ratio)
{
    if (m_device_pixel_ratio == ratio)
        return;
    m_device_pixel_ratio = ratio;
    handle_resize();
}

void WebViewBridge::set_viewport_rect(Gfx::IntRect rect)
{
    // rect is in logical points (UIView bounds). Convert to device pixels.
    auto size = rect.size().scaled(device_pixel_ratio(), device_pixel_ratio());
    if (size == m_viewport_size)
        return;
    m_viewport_size = size;
    handle_resize(); // sends async_set_viewport(page_id, viewport_size(), dpr, ...)
}

void WebViewBridge::initialize_client(CreateNewClient create_new_client)
{
    WebView::ViewImplementation::initialize_client(create_new_client);
    // The AppKit bridge additionally pushes palette + screen rects here; the UIKit host
    // does the theme/screen-rect push from LadybirdWebView.mm once it has a UIScreen.
}

// The AppKit bridge does NOT transform input coordinates in its enqueue path; instead its
// per-type enqueue_input_event overloads apply to_content_position (widget points -> device
// pixels) before forwarding to the base ViewImplementation::enqueue_input_event(Web::InputEvent)
// (which itself only touches wheel deltas / async-scroll). We must mirror those overloads or the
// converters' logical-point coordinates would reach WebContent unscaled. (See
// UI/AppKit/Interface/LadybirdWebViewBridge.cpp:78-100.)
void WebViewBridge::enqueue_input_event(Web::MouseEvent event)
{
    event.position = to_content_position(event.position.to_type<int>()).to_type<Web::DevicePixels>();
    event.screen_position = to_content_position(event.screen_position.to_type<int>()).to_type<Web::DevicePixels>();
    WebView::ViewImplementation::enqueue_input_event(move(event));
}

void WebViewBridge::enqueue_input_event(Web::KeyEvent event)
{
    WebView::ViewImplementation::enqueue_input_event(move(event));
}

void WebViewBridge::enqueue_input_event(Web::PinchEvent event)
{
    // IOS DEVIATION: AppKit pre-multiplies the pinch position by DPR in the .mm and forwards it
    // untouched here. We instead scale it here (like the mouse path) so Event.mm can pass logical
    // points uniformly for every event type. Net effect on WebContent is identical.
    event.position = to_content_position(event.position.to_type<int>()).to_type<Web::DevicePixels>();
    WebView::ViewImplementation::enqueue_input_event(move(event));
}

void* WebViewBridge::front_iosurface() const
{
    if (!m_client_state.has_usable_bitmap || !m_client_state.front_bitmap.shared_image_buffer)
        return nullptr;

#if defined(AK_OS_MACOS)
    // Accessor spelling CONFIRMED against Gfx::SharedImageBuffer (engine 92b0257) and the AppkKit
    // present path (UI/AppKit/Interface/LadybirdWebView.mm:1070): iosurface_handle() returns a
    // Core::IOSurfaceHandle const&, and core_foundation_pointer() yields the IOSurfaceRef (as
    // void*) the host casts and blits into the CAMetalLayer drawable.
    return m_client_state.front_bitmap.shared_image_buffer->iosurface_handle().core_foundation_pointer();
#else
    // BLOCKED-ON-ENGINE (genuinely blocked, engine-owned): Gfx::SharedImageBuffer::iosurface_handle()
    // is compiled ONLY under `#ifdef AK_OS_MACOS` (SharedImageBuffer.h:36-37). iOS builds as
    // AK_OS_IOS (AK/Platform.h:90-96 defines AK_OS_MACOS only when !__IOS__), so the accessor and
    // the m_iosurface_handle member do not exist and the shared image is a plain bitmap with no
    // IOSurface backing. The Metal zero-copy present path therefore requires the engine agent's M0
    // patch to expose an IOSurface handle under AK_OS_IOS (broaden the AK_OS_MACOS guards in
    // SharedImageBuffer.{h,cpp}, LibCore/IOSurface, MetalContext). Until then this returns nullptr
    // and LadybirdWebView.mm falls back to the CPU CGImage present path (which needs only bitmap()).
    return nullptr;
#endif
}

WebViewBridge::Paintable WebViewBridge::paintable() const
{
    Paintable p;
    if (m_client_state.has_usable_bitmap) {
        auto const& fb = m_client_state.front_bitmap;
        if (fb.shared_image_buffer) {
            // bitmap() returns NonnullRefPtr<Gfx::Bitmap>; take the raw pointer. The Bitmap stays
            // alive via the buffer's own NonnullRefPtr member for as long as this SharedImageBuffer
            // lives (i.e. until the front bitmap is swapped), which outlasts this synchronous frame.
            p.bitmap = fb.shared_image_buffer->bitmap().ptr();
            p.size = fb.last_painted_size.to_type<int>();
            return p;
        }
    }
    if (m_backup_shared_image_buffer) {
        p.bitmap = m_backup_shared_image_buffer->bitmap().ptr();
        p.size = m_backup_bitmap_size.to_type<int>();
    }
    return p;
}

}

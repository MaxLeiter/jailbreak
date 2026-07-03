/*
 * IOSApplication — the WebView::Application subclass for the iOS frontend. UIKit
 * analogue of UI/AppKit/Application/Application (which subclasses both NSApplication
 * and WebView::Application). On iOS we do NOT subclass UIApplication; instead the
 * AppDelegate owns UIApplicationMain's runloop and this object provides the
 * cross-platform WebView::Application hooks (tabs, clipboard, dialogs) + the event loop.
 */
#pragma once

#include <AK/ByteString.h>
#include <AK/Optional.h>
#include <LibWebView/Application.h>

namespace LadybirdIOS {

class Application final : public WebView::Application {
    // WEB_VIEW_APPLICATION(Application) expands to the typed the()/create() helpers.
    // create(arguments, bundle_root()) direct-list-inits `new Application{ ByteString }`,
    // so we need a constructor that forwards the binary path to the (protected) base ctor.
    WEB_VIEW_APPLICATION(Application)

public:
    explicit Application(Optional<ByteString> ladybird_binary_path)
        : WebView::Application(move(ladybird_binary_path))
    {
    }

    virtual ~Application() override = default;

    // Called by AppDelegate once UIKit is up, before the first web view spawns WebContent.
    static ErrorOr<void> boot(int argc, char** argv);

private:
    // Event loop: reuse a CFRunLoop-backed Core::EventLoopImplementation so LibCore
    // sources ride UIApplicationMain's main runloop (port of EventLoopImplementationMacOS).
    virtual Core::EventLoop& create_platform_event_loop() override;

    // Clipboard via UIPasteboard, dialogs via UIAlertController, downloads via a
    // documents-dir picker. Stubbed for M0; fill in as chrome matures.
    virtual Optional<WebView::ViewImplementation&> active_web_view() const override;
};

}

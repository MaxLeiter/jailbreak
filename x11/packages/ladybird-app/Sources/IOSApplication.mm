/*
 * IOSApplication.mm + AppDelegate + main(). See IOSApplication.h.
 *
 * Bundle self-location (the multiprocess-in-bundle mechanism):
 *   - We pass the bundle root ([NSBundle mainBundle].bundlePath) to WebView::Application
 *     as the "ladybird binary path". LibWebView::application_directory() then returns the
 *     bundle root, so get_paths_for_helper_process()'s ALWAYS-compiled same-dir candidate
 *     ("<app_dir>/WebContent", Utilities.cpp:111) resolves to
 *     /var/jb/Applications/Ladybird.app/WebContent — the helper we ship in the bundle root.
 *   - The iOS resource path default (find_prefix(app_dir)/share/Lagom) points OUTSIDE the
 *     bundle, so we override it explicitly to <bundle>/share/Lagom after boot.
 *   - IPC uses socketpair + SOCKET_TAKEOVER (the AK_OS_MACOS #else branch; iOS is not
 *     AK_OS_MACOS), spawned with posix_spawn — both proven under this jailbreak.
 */
#import <UIKit/UIKit.h>
#import "IOSApplication.h"
#import "BrowserViewController.h"
#import "IOSEventLoop.h"
#import "LBTrace.h"

#include <AK/ByteString.h>
#include <AK/StringView.h>
#include <AK/Vector.h>
#include <LibCore/EventLoop.h>
#include <LibCore/EventLoopImplementation.h>
#include <LibCore/Resource.h>
#include <LibCore/ResourceImplementationFile.h>
#include <LibMain/Main.h>
#include <LibWebView/BrowserProcess.h>

namespace LadybirdIOS {

static ByteString bundle_root()
{
    return ByteString([[NSBundle mainBundle].bundlePath UTF8String]);
}

Core::EventLoop& Application::create_platform_event_loop()
{
    // Install the CFRunLoop-backed Core::EventLoopManager (ported from
    // UI/AppKit/Application/EventLoopImplementationMacOS -> IOSEventLoop) so LibCore's
    // notifiers/timers/signals/posted-events attach to UIApplicationMain's main CFRunLoop.
    // Mirrors macOS Application::create_platform_event_loop(), minus [NSApp sharedApplication]
    // (UIApplicationMain already stood up the app + main run loop before boot() runs). We skip
    // this in the (unused-on-iOS) headless path so a CLI/headless run keeps the default loop.
    if (!browser_options().headless_mode.has_value())
        Core::EventLoopManager::install(*new EventLoopManagerIOS);

    // Base call runs Core::EventLoop::initialize_for_current_thread(), which constructs the
    // main Core::EventLoop on top of the manager we just installed.
    return WebView::Application::create_platform_event_loop();
}

Optional<WebView::ViewImplementation&> Application::active_web_view() const
{
    return {}; // wired to the foreground BrowserViewController's web view as chrome matures
}

ErrorOr<void> Application::boot(int argc, char** argv)
{
    lb_trace("boot: enter (bundle=%s)", bundle_root().characters());
    // Core::ArgsParser::parse() iterates Arguments::strings (a Span<StringView>), NOT argc/argv,
    // and treats strings[0] as the program name. An empty span makes parse() print usage and
    // exit(), so we must build the span from argv. Keep the backing storage alive for the app's
    // lifetime (Application::initialize copies m_arguments and keeps the span).
    static Vector<StringView> s_arg_strings;
    s_arg_strings.clear_with_capacity();
    for (int i = 0; i < argc; ++i)
        s_arg_strings.append(StringView { argv[i], __builtin_strlen(argv[i]) });
    Main::Arguments arguments { argc, argv, s_arg_strings.span() };

    // Create + initialize the WebView::Application, passing the bundle root as the binary
    // path so helper resolution lands inside the .app (see file header).
    auto app = TRY(Application::create(arguments, bundle_root()));
    lb_trace("boot: Application::create OK");

    // Override the resource root to the in-bundle copy (default iOS path is outside .app).
    auto lagom = ByteString::formatted("{}/share/Lagom", bundle_root());
    Core::ResourceImplementation::install(make<Core::ResourceImplementationFile>(TRY(String::from_byte_string(lagom))));
    lb_trace("boot: resources installed at %s", lagom.characters());

    // Single-instance / new-tab plumbing (BrowserProcess), same as the desktop frontends.
    static WebView::BrowserProcess s_browser_process;

    // CRITICAL: WebView::Application is a process-lifetime singleton (WebView::Application::the()
    // returns s_the, set in its ctor). If we let this local NonnullOwnPtr go out of scope the
    // singleton is destroyed and every later the()/settings() call (e.g. ViewImplementation's
    // SettingsObserver) dereferences a dangling s_the -> crash. Leak it so it lives forever.
    (void)app.leak_ptr();
    lb_trace("boot: done");
    return {};
}

}

// ---- UIKit entry ----

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow* window;
@end

@implementation AppDelegate

- (BOOL)application:(UIApplication*)application didFinishLaunchingWithOptions:(NSDictionary*)opts
{
    lb_trace("didFinishLaunching: enter");
    // Boot the engine app object + launch RequestServer/ImageDecoder/Compositor services.
    static char* argv[] = { (char*)"Ladybird", nullptr };
    auto result = LadybirdIOS::Application::boot(1, argv);
    if (result.is_error()) {
        lb_trace("didFinishLaunching: boot ERROR: %s", result.error().string_literal().characters_without_null_termination());
        NSLog(@"Ladybird: engine boot failed: %s", result.error().string_literal().characters_without_null_termination());
    } else {
        lb_trace("didFinishLaunching: boot returned OK");
    }

    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [[UINavigationController alloc] initWithRootViewController:[BrowserViewController new]];
    [self.window makeKeyAndVisible];
    lb_trace("didFinishLaunching: window visible");
    return YES;
}

@end

int main(int argc, char* argv[])
{
    lb_trace("main: enter (argc=%d)", argc);
    @autoreleasepool {
        // Point HOME + XDG dirs at the app's writable sandbox container so LibWebView's data dir
        // (SQL cookies/history DB), config, and caches can be created. The engine defaults
        // (user_data_directory() = $XDG_DATA_HOME or $HOME/.local/share) otherwise resolve to a
        // non-writable path and launch_services() fails at mkdir. Set before UIApplicationMain so
        // the posix_spawn'd helpers (WebContent/WebWorker/RequestServer/ImageDecoder/Compositor)
        // inherit the same writable environment.
        @autoreleasepool {
            // Use /var/jb/tmp/ladybird as the writable root: the app has the /var/jb read-write
            // file exception and provably writes there (the boot log lives there), whereas the
            // fakesigned app's sandbox container is not reliably writable. Pre-create every XDG
            // dir (mkdir in LibWebView is not recursive) so launch_services()'s data-dir + DB
            // creation succeeds.
            NSString* root = @"/var/jb/tmp/ladybird";
            NSDictionary* xdg = @{
                @"HOME": root,
                @"XDG_DATA_HOME": [root stringByAppendingPathComponent:@"data"],
                @"XDG_CONFIG_HOME": [root stringByAppendingPathComponent:@"config"],
                @"XDG_CACHE_HOME": [root stringByAppendingPathComponent:@"cache"],
                @"XDG_STATE_HOME": [root stringByAppendingPathComponent:@"state"],
            };
            NSFileManager* fm = [NSFileManager defaultManager];
            for (NSString* key in xdg) {
                NSString* dir = xdg[key];
                [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
                // LibWebView creates a per-app "Ladybird" subdir under the data dir; make it too.
                [fm createDirectoryAtPath:[dir stringByAppendingPathComponent:@"Ladybird"] withIntermediateDirectories:YES attributes:nil error:nil];
                setenv(key.UTF8String, dir.UTF8String, 1);
            }
            lb_trace("main: HOME=%s", root.UTF8String);
        }
        int rc = UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
        lb_trace("main: UIApplicationMain returned %d", rc);
        return rc;
    }
}

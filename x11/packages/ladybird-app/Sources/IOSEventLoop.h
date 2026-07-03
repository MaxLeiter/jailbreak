/*
 * IOSEventLoop — CFRunLoop-backed Core::EventLoopImplementation + EventLoopManager for the
 * iOS/UIKit frontend. Port of UI/AppKit/Application/EventLoopImplementationMacOS.{h,mm}
 * (Ladybird 92b0257).
 *
 * CFRunLoop is shared between macOS and iOS, so LibCore's notifiers (CFSocket), timers
 * (CFRunLoopTimer), signals (kqueue + CFFileDescriptor) and posted-event dispatch
 * (CFRunLoopSource) port essentially verbatim. The macOS-only pieces we swap for iOS:
 *
 *   - NSApplication is gone. Under UIApplicationMain the MAIN CFRunLoop is owned by UIKit,
 *     so we attach every LibCore source to CFRunLoopGetCurrent() (== the main loop at boot
 *     time, since create_platform_event_loop() runs on the main thread inside
 *     -application:didFinishLaunchingWithOptions:). The engine's Core::EventLoop::exec() is
 *     never called for the main loop on iOS — UIApplicationMain spins it for us — so posted
 *     events, fd-readiness and timers are serviced while the UI run loop turns.
 *   - post_application_event() (an NSEventTypeApplicationDefined round-trip through
 *     -[NSApp sendEvent:], which drained the ThreadEventQueue on macOS) has no iOS analogue.
 *     Instead did_post_event() signals a CFRunLoopSource whose perform-callback calls
 *     ThreadEventQueue::process(). Any posted Core event (post_event OR deferred_invoke)
 *     therefore drains on the main run loop with no NSApp involvement.
 *   - exec()/pump()/quit()/was_exit_requested() are expressed with CFRunLoopRun /
 *     CFRunLoopRunInMode / CFRunLoopStop instead of [NSApp run]/nextEventMatchingMask/stop:.
 *
 * See IOSEventLoop.mm for the API-swap notes at each call site.
 */
#pragma once

#include <AK/Function.h>
#include <AK/NonnullOwnPtr.h>
#include <LibCore/EventLoopImplementation.h>

namespace LadybirdIOS {

class EventLoopManagerIOS final : public Core::EventLoopManager {
public:
    virtual NonnullOwnPtr<Core::EventLoopImplementation> make_implementation() override;

    virtual intptr_t register_timer(Core::EventReceiver&, int interval_milliseconds, bool should_reload) override;
    virtual void unregister_timer(intptr_t timer_id) override;

    virtual void register_notifier(Core::Notifier&) override;
    virtual void unregister_notifier(Core::Notifier&) override;

    virtual void did_post_event() override;

    virtual int register_signal(int, Function<void(int)>) override;
    virtual void unregister_signal(int) override;
};

class EventLoopImplementationIOS final : public Core::EventLoopImplementation {
public:
    // FIXME (inherited from the macOS port): this currently only manages the main run loop
    // (UIApplicationMain's CFRunLoop), as that is all we interact with. Supporting multiple
    // event loops, or an event loop that isn't the main one, will require creating our own
    // CFRunLoop rather than adopting CFRunLoopGetCurrent().
    static NonnullOwnPtr<EventLoopImplementationIOS> create();

    virtual int exec() override;
    virtual size_t pump(PumpMode) override;
    virtual void quit(int) override;
    virtual void wake() override;
    virtual void deferred_invoke(Function<void()>&&) override;
    virtual bool was_exit_requested() const override;

    virtual ~EventLoopImplementationIOS() override;

private:
    EventLoopImplementationIOS();

    struct Impl;
    NonnullOwnPtr<Impl> m_impl;

    int m_exit_code { 0 };
    bool m_exit_requested { false };
};

}

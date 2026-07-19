/*
 * IOSEventLoop.mm — see IOSEventLoop.h. Port of
 * UI/AppKit/Application/EventLoopImplementationMacOS.mm (Ladybird 92b0257).
 *
 * The timer/notifier/signal/deferred machinery below is pure CoreFoundation and is a
 * near-verbatim copy of the macOS implementation (CFRunLoop is common to both platforms).
 * Every deviation from the macOS source is a MACOS->IOS note inline. The substantive ones:
 *
 *   1. #import <Cocoa/Cocoa.h>  ->  #import <UIKit/UIKit.h>  (+ CoreFoundation, unchanged).
 *   2. post_application_event() [NSEvent/NSApp postEvent:]  ->  wake_main_run_loop()
 *      [CFRunLoopWakeUp(CFRunLoopGetMain())]. iOS has no NSApp event queue to inject a dummy
 *      event into; a plain wake is enough because our posted-event draining runs from a
 *      CFRunLoopSource (see did_post_event), not from an NSApp sendEvent: hook.
 *   3. did_post_event(): macOS only CFRunLoopWakeUp'd and relied on -[Application sendEvent:]
 *      to call ThreadEventQueue::process() when it saw the injected application event. There
 *      is no such hook under UIApplicationMain, so we instead signal the main event source
 *      (whose perform-callback processes the queue) and then wake the main loop. This covers
 *      both Core::EventLoop::post_event and deferred_invoke, which both route through here.
 *   4. exec()  = CFRunLoopRun()        (was [NSApp run]) — normally never called for the main
 *      loop on iOS: UIApplicationMain owns and spins it. Present for nested/secondary loops.
 *   5. pump()  = CFRunLoopRunInMode()  (was nextEventMatchingMask:/sendEvent:).
 *   6. quit()  = CFRunLoopStop()       (was [NSApp stop:]).
 *   7. wake()  = CFRunLoopWakeUp()     (unchanged from macOS).
 *   8. was_exit_requested() tracks an m_exit_requested flag (was ![NSApp isRunning]).
 *   9. Timers/notifiers/signal sources are attached in kCFRunLoopCommonModes so they keep
 *      firing while UIKit switches the main loop into UITrackingRunLoopMode during a scroll or
 *      touch drag — otherwise WebContent IPC (a Core::Notifier) would stall mid-gesture. The
 *      macOS port used kCFRunLoopDefaultMode for timers because the NSApp loop never leaves it.
 */

#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>

#include "IOSEventLoop.h"

#include <AK/Assertions.h>
#include <AK/HashMap.h>
#include <AK/IDAllocator.h>
#include <AK/Singleton.h>
#include <AK/TemporaryChange.h>
#include <LibCore/Event.h>
#include <LibCore/Notifier.h>
#include <LibCore/ThreadEventQueue.h>
#include <LibSync/RWLock.h>

#include <sys/event.h>
#include <sys/time.h>
#include <sys/types.h>

namespace LadybirdIOS {

// The single main-loop event source (signalled by did_post_event to drain the ThreadEventQueue)
// and the run loop it lives on. Consistent with the UIKit main-loop scope in the header; when
// multiple loops are supported these become per-loop and did_post_event uses the owner thread.
static CFRunLoopSourceRef s_main_event_source = nullptr;
static CFRunLoopRef s_main_run_loop = nullptr;

struct ThreadData;
static thread_local OwnPtr<ThreadData> s_this_thread_data;
static HashMap<pthread_t, ThreadData*> s_thread_data;
static thread_local pthread_t s_thread_id;
static Sync::RWLock s_thread_data_lock;

struct ThreadData {
    static ThreadData& the()
    {
        if (s_thread_id == 0)
            s_thread_id = pthread_self();
        if (!s_this_thread_data) {
            s_this_thread_data = make<ThreadData>();
            Sync::RWLockLocker<Sync::LockMode::Write> locker(s_thread_data_lock);
            s_thread_data.set(s_thread_id, s_this_thread_data);
        }
        return *s_this_thread_data;
    }

    static ThreadData* for_thread(pthread_t thread_id)
    {
        Sync::RWLockLocker<Sync::LockMode::Read> locker(s_thread_data_lock);
        return s_thread_data.get(thread_id).value_or(nullptr);
    }

    ~ThreadData()
    {
        Sync::RWLockLocker<Sync::LockMode::Write> locker(s_thread_data_lock);
        s_thread_data.remove(s_thread_id);
    }

    IDAllocator timer_id_allocator;
    HashMap<int, CFRunLoopTimerRef> timers;
    struct NotifierState {
        CFSocketRef socket { nullptr };
        CFRunLoopSourceRef source { nullptr };
        CFRunLoopRef run_loop { nullptr };
    };
    HashMap<Core::Notifier*, NotifierState> notifiers;
};

class SignalHandlers : public RefCounted<SignalHandlers> {
    AK_MAKE_NONCOPYABLE(SignalHandlers);
    AK_MAKE_NONMOVABLE(SignalHandlers);

public:
    SignalHandlers(int signal_number, CFFileDescriptorCallBack);
    ~SignalHandlers();

    void dispatch();
    int add(Function<void(int)>&& handler);
    bool remove(int handler_id);

    bool is_empty() const
    {
        if (m_calling_handlers) {
            for (auto const& handler : m_handlers_pending) {
                if (handler.value)
                    return false; // an add is pending
            }
        }
        return m_handlers.is_empty();
    }

    bool have(int handler_id) const
    {
        if (m_calling_handlers) {
            auto it = m_handlers_pending.find(handler_id);
            if (it != m_handlers_pending.end()) {
                if (!it->value)
                    return false; // a deletion is pending
            }
        }
        return m_handlers.contains(handler_id);
    }

    int m_signal_number;
    void (*m_original_handler)(int);
    HashMap<int, Function<void(int)>> m_handlers;
    HashMap<int, Function<void(int)>> m_handlers_pending;
    bool m_calling_handlers { false };
    CFRunLoopSourceRef m_source { nullptr };
    int m_kevent_fd = { -1 };
};

SignalHandlers::SignalHandlers(int signal_number, CFFileDescriptorCallBack handle_signal)
    : m_signal_number(signal_number)
    , m_original_handler(signal(signal_number, [](int) { }))
{
    m_kevent_fd = kqueue();
    if (m_kevent_fd < 0) {
        dbgln("Unable to create kqueue to register signal {}: {}", signal_number, strerror(errno));
        VERIFY_NOT_REACHED();
    }

    struct kevent changes = {};
    EV_SET(&changes, signal_number, EVFILT_SIGNAL, EV_ADD | EV_RECEIPT, 0, 0, nullptr);
    if (auto res = kevent(m_kevent_fd, &changes, 1, &changes, 1, NULL); res < 0) {
        dbgln("Unable to register signal {}: {}", signal_number, strerror(errno));
        VERIFY_NOT_REACHED();
    }

    CFFileDescriptorContext context = { 0, this, nullptr, nullptr, nullptr };
    CFFileDescriptorRef kq_ref = CFFileDescriptorCreate(kCFAllocatorDefault, m_kevent_fd, FALSE, handle_signal, &context);

    m_source = CFFileDescriptorCreateRunLoopSource(kCFAllocatorDefault, kq_ref, 0);
    // MACOS->IOS: kCFRunLoopCommonModes (was kCFRunLoopDefaultMode) so signals are handled even
    // while the UIKit main loop is in a tracking mode.
    CFRunLoopAddSource(CFRunLoopGetMain(), m_source, kCFRunLoopCommonModes);

    CFFileDescriptorEnableCallBacks(kq_ref, kCFFileDescriptorReadCallBack);
    CFRelease(kq_ref);
}

SignalHandlers::~SignalHandlers()
{
    CFRunLoopRemoveSource(CFRunLoopGetMain(), m_source, kCFRunLoopCommonModes);
    CFRelease(m_source);
    (void)::signal(m_signal_number, m_original_handler);
    ::close(m_kevent_fd);
}

struct SignalHandlersInfo {
    HashMap<int, NonnullRefPtr<SignalHandlers>> signal_handlers;
    IDAllocator signal_id_allocator;
};

static Singleton<SignalHandlersInfo> s_signals;
static SignalHandlersInfo* signals_info()
{
    return s_signals.ptr();
}

void SignalHandlers::dispatch()
{
    TemporaryChange change(m_calling_handlers, true);
    for (auto& handler : m_handlers)
        handler.value(m_signal_number);
    if (!m_handlers_pending.is_empty()) {
        // Apply pending adds/removes
        for (auto& handler : m_handlers_pending) {
            if (handler.value) {
                auto result = m_handlers.set(handler.key, move(handler.value));
                VERIFY(result == AK::HashSetResult::InsertedNewEntry);
            } else {
                m_handlers.remove(handler.key);
            }
        }
        m_handlers_pending.clear();
    }
}

int SignalHandlers::add(Function<void(int)>&& handler)
{
    int id = signals_info()->signal_id_allocator.allocate();
    if (m_calling_handlers)
        m_handlers_pending.set(id, move(handler));
    else
        m_handlers.set(id, move(handler));
    return id;
}

bool SignalHandlers::remove(int handler_id)
{
    VERIFY(handler_id != 0);
    if (m_calling_handlers) {
        auto it = m_handlers.find(handler_id);
        if (it != m_handlers.end()) {
            // Mark pending remove
            m_handlers_pending.set(handler_id, {});
            return true;
        }
        it = m_handlers_pending.find(handler_id);
        if (it != m_handlers_pending.end()) {
            if (!it->value)
                return false; // already was marked as deleted
            it->value = nullptr;
            return true;
        }
        return false;
    }
    return m_handlers.remove(handler_id);
}

// MACOS->IOS: replaces post_application_event(). On macOS a dummy NSEventTypeApplicationDefined
// was posted so that -[Application sendEvent:] would call ThreadEventQueue::process(); on iOS the
// queue is drained by the main event source (did_post_event signals it), so we only need to wake.
static void wake_main_run_loop()
{
    CFRunLoopWakeUp(s_main_run_loop ? s_main_run_loop : CFRunLoopGetMain());
}

struct EventLoopImplementationIOS::Impl {
    Impl(EventLoopImplementationIOS& event_loop_implementation)
        : run_loop(CFRunLoopGetCurrent())
    {
        CFRunLoopSourceContext context {};
        context.info = &event_loop_implementation;
        context.perform = [](void* info) {
            auto& self = *static_cast<EventLoopImplementationIOS*>(info);
            self.m_thread_event_queue.process();
        };

        event_source = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &context);
        CFRunLoopAddSource(run_loop, event_source, kCFRunLoopCommonModes);

        // Adopt this as the main loop under UIApplicationMain (first loop created wins), so the
        // manager's did_post_event() can reach the source that drains the ThreadEventQueue.
        if (s_main_event_source == nullptr) {
            s_main_event_source = event_source;
            s_main_run_loop = run_loop;
        }
    }

    ~Impl()
    {
        if (s_main_event_source == event_source) {
            s_main_event_source = nullptr;
            s_main_run_loop = nullptr;
        }
        CFRunLoopRemoveSource(run_loop, event_source, kCFRunLoopCommonModes);
        CFRelease(event_source);
    }

    CFRunLoopRef run_loop { nullptr };
    CFRunLoopSourceRef event_source { nullptr };
};

EventLoopImplementationIOS::EventLoopImplementationIOS()
    : m_impl(make<Impl>(*this))
{
}

EventLoopImplementationIOS::~EventLoopImplementationIOS() = default;

NonnullOwnPtr<Core::EventLoopImplementation> EventLoopManagerIOS::make_implementation()
{
    return EventLoopImplementationIOS::create();
}

intptr_t EventLoopManagerIOS::register_timer(Core::EventReceiver& receiver, int interval_milliseconds, bool should_reload)
{
    auto& thread_data = ThreadData::the();

    auto timer_id = thread_data.timer_id_allocator.allocate();
    auto weak_receiver = receiver.make_weak_ptr();

    auto interval_seconds = static_cast<double>(interval_milliseconds) / 1000.0;
    auto first_fire_time = CFAbsoluteTimeGetCurrent() + interval_seconds;

    auto* timer = CFRunLoopTimerCreateWithHandler(
        kCFAllocatorDefault, first_fire_time, should_reload ? interval_seconds : 0, 0, 0,
        ^(CFRunLoopTimerRef) {
            auto receiver = weak_receiver.strong_ref();
            if (!receiver) {
                return;
            }

            Core::TimerEvent event;
            receiver->dispatch_event(event);
        });

    // MACOS->IOS: kCFRunLoopCommonModes (was kCFRunLoopDefaultMode) so Core::Timers keep firing
    // while UIKit is tracking a touch/scroll. WebContent's repaint/IPC timers depend on this.
    CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, kCFRunLoopCommonModes);
    thread_data.timers.set(timer_id, timer);

    return timer_id;
}

void EventLoopManagerIOS::unregister_timer(intptr_t timer_id)
{
    auto& thread_data = ThreadData::the();
    thread_data.timer_id_allocator.deallocate(static_cast<int>(timer_id));

    auto timer = thread_data.timers.take(static_cast<int>(timer_id));
    VERIFY(timer.has_value());
    CFRunLoopTimerInvalidate(*timer);
    CFRelease(*timer);
}

struct SocketNotifierCallbackContext : public RefCounted<SocketNotifierCallbackContext> {
    WeakPtr<Core::EventReceiver> notifier;
};

static void const* retain_socket_notifier_callback_context(void const* info)
{
    auto const* context = static_cast<SocketNotifierCallbackContext const*>(info);
    context->ref();
    return context;
}

static void release_socket_notifier_callback_context(void const* info)
{
    auto const* context = static_cast<SocketNotifierCallbackContext const*>(info);
    context->unref();
}

static void socket_notifier(CFSocketRef socket, CFSocketCallBackType notification_type, CFDataRef, void const*, void* info)
{
    if (!info)
        return;
    auto& callback_context = *static_cast<SocketNotifierCallbackContext*>(info);
    if (!callback_context.notifier)
        return;
    auto& notifier = as<Core::Notifier>(*callback_context.notifier);

    // This socket callback is not quite re-entrant. If Core::Notifier::dispatch_event blocks, e.g.
    // to wait upon a Core::Promise, this socket will not receive any more notifications until that
    // promise is resolved or rejected. So we mark this socket as able to receive more notifications
    // before dispatching the event, which allows it to be triggered again.
    CFSocketEnableCallBacks(socket, notification_type);

    Core::NotifierActivationEvent event;
    notifier.dispatch_event(event);

    // Re-enabling the callbacks manually also requires waking the run loop, otherwise it can hang
    // indefinitely in an ongoing pump(PumpMode::WaitForEvents). (MACOS->IOS: was
    // post_application_event(); a plain wake suffices on iOS — see wake_main_run_loop.)
    wake_main_run_loop();
}

void EventLoopManagerIOS::register_notifier(Core::Notifier& notifier)
{
    auto notification_type = kCFSocketNoCallBack;

    switch (notifier.type()) {
    case Core::Notifier::Type::Read:
        notification_type = kCFSocketReadCallBack;
        break;
    case Core::Notifier::Type::Write:
        notification_type = kCFSocketWriteCallBack;
        break;
    default:
        VERIFY_NOT_REACHED();
    }

    auto callback_context = adopt_ref(*new SocketNotifierCallbackContext);
    callback_context->notifier = notifier.make_weak_ptr();
    CFSocketContext context { .version = 0, .info = callback_context, .retain = retain_socket_notifier_callback_context, .release = release_socket_notifier_callback_context, .copyDescription = nullptr };
    auto* socket = CFSocketCreateWithNative(kCFAllocatorDefault, notifier.fd(), notification_type, &socket_notifier, &context);

    CFOptionFlags sockopt = CFSocketGetSocketFlags(socket);
    sockopt &= ~kCFSocketAutomaticallyReenableReadCallBack;
    sockopt &= ~kCFSocketCloseOnInvalidate;
    CFSocketSetSocketFlags(socket, sockopt);

    auto* source = CFSocketCreateRunLoopSource(kCFAllocatorDefault, socket, 0);
    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, kCFRunLoopCommonModes);

    CFRelease(socket);

    ThreadData::the().notifiers.set(&notifier, { socket, source, CFRunLoopGetCurrent() });
    notifier.set_owner_thread(s_thread_id);
}

void EventLoopManagerIOS::unregister_notifier(Core::Notifier& notifier)
{
    auto* thread_data = ThreadData::for_thread(notifier.owner_thread());
    if (!thread_data)
        return;
    auto state = thread_data->notifiers.take(&notifier);
    VERIFY(state.has_value());
    CFSocketInvalidate(state->socket);
    CFRunLoopRemoveSource(state->run_loop, state->source, kCFRunLoopCommonModes);
    CFRelease(state->source);
}

void EventLoopManagerIOS::did_post_event()
{
    // MACOS->IOS: macOS only woke the loop here and relied on -[Application sendEvent:] to drain
    // the ThreadEventQueue when it saw the injected application event. UIApplicationMain gives us
    // no such hook, so signal the main event source (its perform-callback runs
    // ThreadEventQueue::process()) and then wake the main loop so it services the source.
    if (s_main_event_source != nullptr)
        CFRunLoopSourceSignal(s_main_event_source);
    wake_main_run_loop();
}

static void handle_signal(CFFileDescriptorRef f, CFOptionFlags callback_types, void* info)
{
    VERIFY(callback_types & kCFFileDescriptorReadCallBack);
    auto* signal_handlers = static_cast<SignalHandlers*>(info);

    struct kevent event {};

    // returns number of events that have occurred since last call
    (void)::kevent(CFFileDescriptorGetNativeDescriptor(f), nullptr, 0, &event, 1, nullptr);
    CFFileDescriptorEnableCallBacks(f, kCFFileDescriptorReadCallBack);

    signal_handlers->dispatch();
}

int EventLoopManagerIOS::register_signal(int signal_number, Function<void(int)> handler)
{
    VERIFY(signal_number != 0);
    auto& info = *signals_info();
    auto handlers = info.signal_handlers.find(signal_number);
    if (handlers == info.signal_handlers.end()) {
        auto signal_handlers = adopt_ref(*new SignalHandlers(signal_number, &handle_signal));
        auto handler_id = signal_handlers->add(move(handler));
        info.signal_handlers.set(signal_number, move(signal_handlers));
        return handler_id;
    } else {
        return handlers->value->add(move(handler));
    }
}

void EventLoopManagerIOS::unregister_signal(int handler_id)
{
    VERIFY(handler_id != 0);
    int remove_signal_number = 0;
    auto& info = *signals_info();
    for (auto& h : info.signal_handlers) {
        auto& handlers = *h.value;
        if (handlers.remove(handler_id)) {
            info.signal_id_allocator.deallocate(handler_id);
            if (handlers.is_empty())
                remove_signal_number = handlers.m_signal_number;
            break;
        }
    }
    if (remove_signal_number != 0)
        info.signal_handlers.remove(remove_signal_number);
}

NonnullOwnPtr<EventLoopImplementationIOS> EventLoopImplementationIOS::create()
{
    return adopt_own(*new EventLoopImplementationIOS);
}

int EventLoopImplementationIOS::exec()
{
    // MACOS->IOS: was [NSApp run]. On iOS the main loop is owned and spun by UIApplicationMain, so
    // this is normally never reached for the main Core::EventLoop; it exists for nested/secondary
    // loops (e.g. a modal sub-loop). CFRunLoopRun spins m_impl->run_loop until quit() stops it.
    while (!m_exit_requested)
        CFRunLoopRun();
    return m_exit_code;
}

size_t EventLoopImplementationIOS::pump(PumpMode mode)
{
    // MACOS->IOS: was nextEventMatchingMask:/sendEvent:. Run the current run loop once (blocking
    // until the first source fires when WaitForEvents, non-blocking otherwise), then drain any
    // further immediately-ready sources without blocking.
    auto timeout = mode == PumpMode::WaitForEvents ? 1.0e10 : 0.0;
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, timeout, true);
    while (CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.0, true) == kCFRunLoopRunHandledSource)
        ;
    return 0;
}

void EventLoopImplementationIOS::quit(int exit_code)
{
    // MACOS->IOS: was [NSApp stop:nil].
    m_exit_code = exit_code;
    m_exit_requested = true;
    CFRunLoopStop(m_impl->run_loop);
}

void EventLoopImplementationIOS::wake()
{
    CFRunLoopWakeUp(m_impl->run_loop);
}

void EventLoopImplementationIOS::deferred_invoke(Function<void()>&& invokee)
{
    m_thread_event_queue.deferred_invoke(move(invokee));
    CFRunLoopSourceSignal(m_impl->event_source);
    if (&m_thread_event_queue != Core::ThreadEventQueue::current_or_null())
        CFRunLoopWakeUp(m_impl->run_loop);
}

bool EventLoopImplementationIOS::was_exit_requested() const
{
    // MACOS->IOS: was ![NSApp isRunning].
    return m_exit_requested;
}

}

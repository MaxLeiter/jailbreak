import Foundation

/// The system-integration links of one desktop (volume and appearance to its
/// xios-sysintd, output rotation and haptics over its iosc input socket).
///
/// The C handle is unsynchronized and its lazy connects block, so every call on it
/// (open, send, poll, close) runs on one serial queue and nothing here touches the
/// main thread's time. Events it drains are handed to main.
final class SysIntLink {
    enum Event {
        case haptic(UInt32)
        case volume(UInt32)
        case brightness(UInt32)
    }

    private static let queue = DispatchQueue(label: "com.max.xios.sysint", qos: .userInitiated)
    private static let maxEventsPerPoll = 4

    private var handle: OpaquePointer?          // sysint_link_t*, queue only
    private var timer: DispatchSourceTimer?     // queue only
    private var closed = false                  // queue only

    /// `sysint` / `iosc` may be nil: that link stays disabled (never guessed).
    init(sysint: String?, iosc: String?, onEvent: @escaping (Event) -> Void) {
        Self.queue.async { [self] in
            handle = sysint_link_open(sysint, iosc)
            let t = DispatchSource.makeTimerSource(queue: Self.queue)
            t.schedule(deadline: .now() + 0.05, repeating: 0.05, leeway: .milliseconds(10))
            t.setEventHandler { [weak self] in self?.poll(onEvent) }
            t.resume()
            timer = t
        }
    }

    func sendVolume(_ v16: UInt32) {
        Self.queue.async { [self] in
            guard !closed else { return }
            sysint_send_volume(handle, v16)
        }
    }

    func sendAppearance(dark: Bool) {
        Self.queue.async { [self] in
            guard !closed else { return }
            sysint_send_appearance(handle, dark ? 1 : 0)
        }
    }

    /// 0,0 logical size = iosc derives the size by swapping on quarter-turns.
    func sendOutput(transform: Int32) {
        Self.queue.async { [self] in
            guard !closed else { return }
            sysint_send_output(handle, transform, 0, 0)
        }
    }

    func close() {
        Self.queue.async { [self] in
            guard !closed else { return }
            closed = true
            timer?.cancel(); timer = nil
            sysint_link_close(handle)
            handle = nil
        }
    }

    private func poll(_ onEvent: @escaping (Event) -> Void) {
        guard !closed, let h = handle else { return }
        var events: [Event] = []
        var v: UInt32 = 0
        var n = 0
        while n < Self.maxEventsPerPoll, sysint_poll_haptic(h, &v) == 1 {
            events.append(.haptic(v)); n += 1
        }
        n = 0
        while n < Self.maxEventsPerPoll, sysint_poll_volume_set(h, &v) == 1 {
            events.append(.volume(v)); n += 1
        }
        // Must run every poll: it shares one socket with the volume drain and each
        // stashes only ONE of the other's records (invariant 53).
        n = 0
        while n < Self.maxEventsPerPoll, sysint_poll_brightness_set(h, &v) == 1 {
            events.append(.brightness(v)); n += 1
        }
        guard !events.isEmpty else { return }
        DispatchQueue.main.async { events.forEach(onEvent) }
    }
}

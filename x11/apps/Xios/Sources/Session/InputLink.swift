import Foundation

/// One connection to a compositor's input socket (handle-based IoscInput.c).
/// Created off the main thread (open blocks in connect), then used only on main:
/// writes are non-blocking and queue under backpressure (invariant 44).
/// After the link drops, every call is a no-op and `isOpen` is false.
final class InputLink {
    enum TraitsPoll {
        case none
        case record(hint: UInt32, purpose: UInt32, enabled: UInt32)
        case closed
    }

    private var handle: OpaquePointer?

    /// Blocking: call off the main thread. nil if the compositor is not listening.
    static func open(socket path: String) -> InputLink? {
        // Window 0: the classic unbound client (no XIOS_IN_BIND on the wire).
        guard let h = iosc_input_open(path, 0) else { return nil }
        return InputLink(handle: h)
    }

    private init(handle: OpaquePointer) { self.handle = handle }

    deinit { close() }

    var isOpen: Bool { handle != nil && iosc_input_is_open(handle) }

    func close() {
        guard let h = handle else { return }
        handle = nil
        iosc_input_close(h)
    }

    func motion(_ x: Int32, _ y: Int32) { iosc_input_motion(handle, x, y) }

    func button(_ button: Int32, down: Bool, at p: (Int32, Int32)) {
        iosc_input_button(handle, button, down, p.0, p.1)
    }

    func key(_ keysym: UInt32, down: Bool, mods: UInt32) {
        iosc_input_key(handle, keysym, down, mods)
    }

    /// A key tap with the given modifier snapshot: down with `mods`, up with none.
    func keyTap(_ keysym: UInt32, mods: UInt32 = 0) {
        iosc_input_key(handle, keysym, true, mods)
        iosc_input_key(handle, keysym, false, 0)
    }

    func text(_ s: String) { s.withCString { iosc_input_text(handle, $0) } }

    func touch(slot: Int32, phase: Int32, _ x: Int32, _ y: Int32) {
        iosc_input_touch(handle, slot, phase, x, y)
    }

    func tablet(phase: Int32, _ x: Int32, _ y: Int32, pressure16: UInt32,
                tiltX: Int32, tiltY: Int32) {
        iosc_input_tablet(handle, phase, x, y, pressure16, tiltX, tiltY)
    }

    func axis(dx256: Int32, dy256: Int32, source: UInt32, stop: Bool) {
        iosc_input_axis(handle, dx256, dy256, source, 0, stop)
    }

    func gesture(kind: UInt32, phase: UInt32, fingers: UInt32, dx256: Int32, dy256: Int32,
                 scale256: UInt32, rot256: Int32) {
        iosc_input_gesture(handle, kind, phase, fingers, dx256, dy256, scale256, rot256)
    }

    /// One TRAITS record per call; also flushes input queued while the
    /// compositor was not reading, so call it every tick.
    func pollTraits() -> TraitsPoll {
        var hint: UInt32 = 0, purpose: UInt32 = 0, enabled: UInt32 = 0
        let r = iosc_input_poll_traits(handle, &hint, &purpose, &enabled)
        if r < 0 { return .closed }
        if r == 0 { return .none }
        return .record(hint: hint, purpose: purpose, enabled: enabled)
    }
}

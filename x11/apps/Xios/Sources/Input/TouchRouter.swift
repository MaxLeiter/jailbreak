import UIKit

/// What the router needs from the view it routes for.
protocol TouchHost: AnyObject {
    /// The presented desktop's input link, only while it is open.
    var inputLink: InputLink? { get }
    var touchView: UIView { get }
    func fitTransform() -> FitTransform?
    /// Whether direct touch replaces the emulated pointer for this desktop.
    var touchReplacesPointer: Bool { get }
    var framebufferSize: (width: Int, height: Int) { get }
    /// Fingers and Pencil hide our cursor overlay; a mouse brings it back.
    func touchInputBegan(_ touches: Set<UITouch>)
    func hardwarePointerBegan()
    func logTouch(viewPoint: CGPoint, framebuffer: (x: Int32, y: Int32))
}

/// Touches, Pencil and the mouse/trackpad button lane: everything that arrives as
/// UITouch and leaves as wl_touch, wl_tablet or wl_pointer records.
///
/// Per-gesture lane (LaneTracker), the deferred finger press, the 0.55 s hold that
/// becomes a right click, stable touch slots, three-finger suppression, and the
/// indirect-pointer button state. All of it main-thread; nothing here does file
/// I/O (the committed-press diagnostic is handed to the status queue).
final class TouchRouter {
    private unowned let host: TouchHost
    private var lanes = LaneTracker()

    /// Stable per-touch slot ids (0..9), assigned on first use, freed on up/cancel
    /// (invariant 40).
    private var touchSlots: [UITouch: Int32] = [:]
    /// Last point in output pixels, so a touch-up whose UIKit location we cannot map
    /// can still send its release at the right spot.
    private(set) var lastTouchPt: (Int32, Int32)?

    // Deferred left press: a stationary single finger only commits to a left press
    // when it moves (drag) or lifts (tap); held past the threshold it becomes a right
    // click instead (invariant 38).
    private var pendingPress: (x: Int32, y: Int32)?
    private var pendingPressTimer: Timer?
    private var pendingPressViewPoint = CGPoint.zero
    private var leftPressSent = false
    private var longPressFired = false
    static let longPressSeconds: TimeInterval = 0.55
    static let longPressSlopPt: CGFloat = 12

    /// 3+ fingers belong to the app (switcher tap): cancel every wl_touch and ignore
    /// the rest of the gesture until all lift (invariant 39).
    private var appGestureSuppression = false

    // Indirect pointer (mouse / trackpad).
    private(set) var hardwarePointerTouchDown = false
    private var hardwareButtonMask = 0

    init(host: TouchHost) { self.host = host }

    // MARK: points

    private func framebufferPoint(_ p: CGPoint) -> (Int32, Int32)? {
        guard let fp = host.fitTransform()?.framebufferPoint(from: p) else { return nil }
        return (Int32(fp.x), Int32(fp.y))
    }

    private func ioscPoint(_ t: UITouch) -> (Int32, Int32)? {
        framebufferPoint(t.location(in: host.touchView)) ?? lastTouchPt
    }

    /// A direct view-point -> framebuffer mapping for gesture code (hover, taps).
    func framebufferPoint(from p: CGPoint, remember: Bool) -> (Int32, Int32)? {
        guard let pt = framebufferPoint(p) else { return nil }
        if remember { lastTouchPt = pt }
        return pt
    }

    func noteTouchPoint(_ p: (Int32, Int32)) { lastTouchPt = p }

    private func sendButton(_ button: Int32, _ down: Bool, at p: (Int32, Int32)?) {
        let q = p ?? lastTouchPt ?? (0, 0)
        host.inputLink?.button(button, down: down, at: q)
    }

    private func sendMotion(_ x: Int32, _ y: Int32) { host.inputLink?.motion(x, y) }

    // MARK: latches

    /// The connection dropped, or is being closed or replaced: let go of every
    /// button and touch the app still believes is held, so none of it stays latched
    /// into the next connection (invariant 42). Releases go out only if the current
    /// link is still open; after a drop this just clears app-side state. A trackpad
    /// button still physically held presses again on its next event, because the
    /// touch phase, not buttonMask, decides it.
    func resetLatches() {
        releaseHardwarePointerButtons()
        cancelPendingPress()
        longPressFired = false
        releaseLeftPress()
        leftPressSent = false
        for slot in touchSlots.values { host.inputLink?.touch(slot: slot, phase: 3, 0, 0) }
        touchSlots.removeAll()
        lanes.reset()
    }

    // MARK: touches

    func touchesBegan(_ touches: Set<UITouch>, event: UIEvent?) {
        if handleHardwarePointer(touches, event: event, phase: .down) { return }
        host.touchInputBegan(touches)
        if appGestureSuppression { return }
        let touchCount = event?.allTouches?.count ?? touches.count
        if touchCount >= 3 {
            beginAppGestureSuppression(event: event)
            return
        }
        let anyDirect = touches.contains { $0.type == .direct }
        let lane = lanes.began(
            isGestureStart: touchCount == touches.count,
            newTouches: touches.count,
            allDirect: touches.allSatisfy { $0.type == .direct },
            replacesPointer: anyDirect && host.touchReplacesPointer)
        if lane.forwardsTouch {
            forward(touches, phase: 1, event: event)
            if lane.consumesPointer { return }
        }
        guard touchCount == 1 else {
            cancelPendingPress()   // a second finger means gesture, not click
            return
        }
        guard host.inputLink != nil, let t = touches.first,
              let (x, y) = framebufferPoint(t.location(in: host.touchView)) else { return }
        lastTouchPt = (x, y)
        longPressFired = false
        if t.type == .direct {
            // Finger: defer the press so a still hold can become a right click.
            pendingPress = (x, y)
            pendingPressViewPoint = t.location(in: host.touchView)
            pendingPressTimer?.invalidate()
            pendingPressTimer = Timer.scheduledTimer(withTimeInterval: Self.longPressSeconds,
                                                     repeats: false) { [weak self] _ in
                self?.fireLongPress()
            }
        } else {
            // Pencil / trackpad: press immediately, no long-press synthesis.
            host.logTouch(viewPoint: t.location(in: host.touchView), framebuffer: (x, y))
            sendMotion(x, y)
            sendButton(1, true, at: (x, y))
            leftPressSent = true
        }
    }

    func touchesMoved(_ touches: Set<UITouch>, event: UIEvent?) {
        if handleHardwarePointer(touches, event: event, phase: .move) { return }
        host.touchInputBegan(touches)
        if appGestureSuppression { return }
        let lane = lanes.lane
        if lane.forwardsTouch {
            forward(touches, phase: 2, event: event)
            if lane.consumesPointer { return }
        }
        guard (event?.allTouches?.count ?? touches.count) == 1,
              host.inputLink != nil, let t = touches.first,
              let (x, y) = framebufferPoint(t.location(in: host.touchView)) else { return }
        if longPressFired { return }          // the hold became a right click
        if pendingPress != nil {
            let l = t.location(in: host.touchView)
            if hypot(l.x - pendingPressViewPoint.x,
                     l.y - pendingPressViewPoint.y) < Self.longPressSlopPt { return }
            flushPendingPress()               // it moved: press at the origin
        }
        lastTouchPt = (x, y)
        sendMotion(x, y)
    }

    func touchesEnded(_ touches: Set<UITouch>, event: UIEvent?) {
        if handleHardwarePointer(touches, event: event, phase: .up) { return }
        host.touchInputBegan(touches)
        defer { if allTouchesEndedOrCancelled(event) { lanes.reset() } }
        if appGestureSuppression {
            if allTouchesEndedOrCancelled(event) { appGestureSuppression = false }
            return
        }
        let lane = lanes.lane
        if lane.forwardsTouch {
            forward(touches, phase: 0, event: event)
            if lane.consumesPointer { return }
        }
        guard host.inputLink != nil else {
            cancelPendingPress(); longPressFired = false
            return
        }
        if longPressFired { longPressFired = false; return }
        if pendingPress != nil { flushPendingPress() }   // stationary tap = click
        releaseLeftPress()
    }

    func touchesCancelled(_ touches: Set<UITouch>, event: UIEvent?) {
        if handleHardwarePointer(touches, event: event, phase: .up) { return }
        host.touchInputBegan(touches)
        defer { if allTouchesEndedOrCancelled(event) { lanes.reset() } }
        if appGestureSuppression {
            if allTouchesEndedOrCancelled(event) {
                appGestureSuppression = false
                touchSlots.removeAll()
            }
            return
        }
        let lane = lanes.lane
        if lane.forwardsTouch {
            forward(touches, phase: 3, event: event)
            if lane.consumesPointer { return }
        }
        cancelPointerInteraction()
    }

    private func allTouchesEndedOrCancelled(_ event: UIEvent?) -> Bool {
        guard let all = event?.allTouches, !all.isEmpty else { return true }
        return all.allSatisfy { $0.phase == .ended || $0.phase == .cancelled }
    }

    private func beginAppGestureSuppression(event: UIEvent?) {
        appGestureSuppression = true
        cancelPointerInteraction()
        if host.inputLink != nil, let all = event?.allTouches {
            forward(Set(all), phase: 3, event: event)
            touchSlots.removeAll()
        }
    }

    // MARK: wire forwarding (wl_touch / wl_tablet)

    private func touchSlot(for t: UITouch) -> Int32 {
        if let s = touchSlots[t] { return s }
        var s: Int32 = 0
        while touchSlots.values.contains(s) { s += 1 }
        touchSlots[t] = s
        return s
    }

    /// phase: 0 up, 1 down, 2 motion, 3 cancel (the wire's encoding).
    private func forward(_ touches: Set<UITouch>, phase: Int32, event: UIEvent?) {
        for t in touches { forward(t, phase: phase, event: event) }
    }

    private func forward(_ t: UITouch, phase: Int32, event: UIEvent?) {
        guard let link = host.inputLink else { return }
        if t.type == .pencil {
            if phase == 0 || phase == 3 {          // iosc ignores coords on up/cancel
                let p = ioscPoint(t) ?? (0, 0)
                link.tablet(phase: phase, p.0, p.1, pressure16: 0, tiltX: 0, tiltY: 0)
                return
            }
            // Coalesced touches carry the full 240 Hz Pencil sample train. No file
            // I/O anywhere on this path (invariant 41).
            let samples = (phase == 2 ? event?.coalescedTouches(for: t) : nil) ?? [t]
            for s in samples {
                guard let (x, y) = ioscPoint(s) else { continue }
                lastTouchPt = (x, y)
                let force = s.maximumPossibleForce > 0
                    ? Double(s.force / s.maximumPossibleForce) : 1.0
                let mag = 90.0 - Double(s.altitudeAngle) * 180.0 / .pi  // 0 = pen vertical
                let az = Double(s.azimuthAngle(in: host.touchView))
                link.tablet(phase: phase, x, y,
                            pressure16: UInt32((force * 65535.0).rounded()),
                            tiltX: Int32((mag * cos(az)).rounded()),
                            tiltY: Int32((mag * sin(az)).rounded()))
            }
            return
        }
        let slot = touchSlot(for: t)
        if phase == 0 || phase == 3 { touchSlots[t] = nil }
        guard let (x, y) = ioscPoint(t) else {
            // Outside the framebuffer: still deliver up/cancel so iosc frees the id.
            if phase == 0 || phase == 3 { link.touch(slot: slot, phase: phase, 0, 0) }
            return
        }
        lastTouchPt = (x, y)
        link.touch(slot: slot, phase: phase, x, y)
    }

    // MARK: deferred press

    func cancelPendingPress() {
        pendingPressTimer?.invalidate()
        pendingPressTimer = nil
        pendingPress = nil
    }

    /// Commit the deferred left press at its original point (drag start / tap).
    private func flushPendingPress() {
        guard let p = pendingPress else { return }
        cancelPendingPress()
        host.logTouch(viewPoint: pendingPressViewPoint, framebuffer: p)
        sendMotion(p.x, p.y)
        sendButton(1, true, at: (p.x, p.y))
        leftPressSent = true
    }

    /// Long-press is ALWAYS right click now: the iosc context menu that used to eat
    /// it is gone.
    private func fireLongPress() {
        guard let p = pendingPress, host.inputLink != nil else { cancelPendingPress(); return }
        cancelPendingPress()
        longPressFired = true
        host.logTouch(viewPoint: pendingPressViewPoint, framebuffer: p)
        // Physical confirmation the hold promoted (no-op without a Taptic Engine).
        SystemIntegration.shared.rightClickHaptic()
        sendMotion(p.x, p.y)
        sendButton(3, true, at: (p.x, p.y))
        sendButton(3, false, at: (p.x, p.y))
    }

    /// Release the emulated left button if it is down (guarded, idempotent).
    func releaseLeftPress() {
        if host.inputLink != nil && leftPressSent {
            sendButton(1, false, at: lastTouchPt)
            leftPressSent = false
        }
    }

    func cancelPointerInteraction() {
        cancelPendingPress()
        longPressFired = false
        releaseLeftPress()
    }

    // MARK: indirect pointer (mouse, trackpad)

    enum HardwarePointerPhase { case down, move, up }

    private func handleHardwarePointer(_ touches: Set<UITouch>, event: UIEvent?,
                                       phase: HardwarePointerPhase) -> Bool {
        guard let touch = touches.first(where: { $0.type == .indirectPointer }) else { return false }
        host.hardwarePointerBegan()
        if host.inputLink != nil, let point = framebufferPoint(touch.location(in: host.touchView)) {
            lastTouchPt = point
            sendMotion(point.0, point.1)
        }
        hardwarePointerTouchDown = phase != .up
        updateHardwarePointerButtons(hardwarePointerMask(event, phase: phase))
        return true
    }

    /// Button state for a mouse/trackpad press. The touch phase is authoritative and
    /// `buttonMask` only refines it: an `.indirectPointer` touch exists solely while a
    /// button is held, so a press with an empty mask is still a press and an ended
    /// touch is always all-up (invariant 35).
    private func hardwarePointerMask(_ event: UIEvent?, phase: HardwarePointerPhase) -> Int {
        if phase == .up { return 0 }
        let mask = event?.buttonMask.rawValue ?? 0
        if mask != 0 { return mask }
        // Something is held but iPadOS did not say which: keep what we had, else
        // assume the primary button (bit 0).
        return hardwareButtonMask != 0 ? hardwareButtonMask : 1
    }

    private func updateHardwarePointerButtons(_ nextMask: Int) {
        let changed = hardwareButtonMask ^ nextMask
        guard changed != 0 else { return }
        let ioscButtons: [Int32] = [1, 3, 2, 0x113, 0x114]
        for index in 0..<ioscButtons.count where changed & (1 << index) != 0 {
            sendButton(ioscButtons[index], nextMask & (1 << index) != 0, at: lastTouchPt)
        }
        hardwareButtonMask = nextMask
    }

    func releaseHardwarePointerButtons() {
        hardwarePointerTouchDown = false
        guard hardwareButtonMask != 0 else { return }
        updateHardwarePointerButtons(0)
    }

    /// Hover means the pointer is moving with no touch of its own. A button still
    /// marked down here outlived its touch (a cancelled sequence, or a release UIKit
    /// never delivered) and every motion from now on would be a drag: let it go.
    func hoverMoved(to point: CGPoint) {
        host.hardwarePointerBegan()
        if hardwareButtonMask != 0 && !hardwarePointerTouchDown {
            releaseHardwarePointerButtons()
        }
        guard host.inputLink != nil, let p = framebufferPoint(point) else { return }
        lastTouchPt = p
        sendMotion(p.0, p.1)
    }
}

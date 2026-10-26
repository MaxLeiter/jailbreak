import UIKit

/// What the gesture layer needs on top of the touch host.
protocol GestureHost: TouchHost {
    var viewport: ViewportState { get set }
    func viewportGeometry() -> ViewportState.Geometry?
    func requestPresent()
    /// Three-finger tap or the top-edge pull.
    func openSwitcher()
    /// Swipe up from the lower edge.
    func raiseKeyboard()
}

/// Every UIGestureRecognizer on the desktop view: app zoom, scroll, the trackpad's
/// pinch/rotate, two-finger right click, hover, and the two edge gestures that open
/// the switcher and the keyboard. Raw touches live in TouchRouter; these are the
/// recognised gestures.
final class GestureController: NSObject, UIGestureRecognizerDelegate {
    private unowned let host: GestureHost
    private unowned let router: TouchRouter
    private unowned let view: UIView

    private var keyboardRevealPan: UIPanGestureRecognizer?
    private var switcherRevealPan: UIPanGestureRecognizer?
    private var discreteScrollPan: UIPanGestureRecognizer?
    private var keyboardSwipeTriggered = false
    private var switcherSwipeTriggered = false

    // View transform gesture state.
    private var pinchStartZoom: CGFloat = 1
    private var pinchAnchorFramebuffer: CGPoint?
    private var panStartOffset = CGPoint.zero
    private var panLastTranslation = CGPoint.zero

    // Scroll. Sub-1/256-px remainder for the AXIS path (invariant 33).
    private var axisRemainder = CGPoint.zero
    private var axisActive = false
    private var axisSource: UInt32 = 0

    /// Two-finger arbitration: the first gesture to cross its threshold claims the
    /// finger pair (scroll vs pinch app-zoom) for the rest of the session.
    private enum TwoFingerMode { case undecided, scroll, zoom }
    private var twoFingerMode = TwoFingerMode.undecided
    private var twoFingerActive = 0     // live pan/pinch recognizers (0..2)

    // Trackpad pinch/rotate become ONE Wayland gesture: the first recognizer to
    // start opens it, the last to end closes it; scale and rotation are absolute
    // since begin (invariant 34).
    private var trackpadGestureActive = 0
    private var trackpadPinchScale: CGFloat = 1
    private var trackpadRotationDegrees: CGFloat = 0
    private var trackpadGestureCenter: CGPoint?

    init(host: GestureHost, router: TouchRouter, view: UIView) {
        self.host = host
        self.router = router
        self.view = view
        super.init()
    }

    func install() {
        func add(_ g: UIGestureRecognizer) {
            g.delegate = self
            view.addGestureRecognizer(g)
        }

        let switcherTap = UITapGestureRecognizer(target: self, action: #selector(handleSwitcherTap))
        switcherTap.numberOfTouchesRequired = 3
        add(switcherTap)

        add(UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:))))
        // Harmless if iPadOS never delivers indirect rotation: it just never fires.
        add(UIRotationGestureRecognizer(target: self, action: #selector(handleRotation(_:))))

        let keyboardPan = UIPanGestureRecognizer(target: self, action: #selector(handleKeyboardRevealPan(_:)))
        keyboardPan.minimumNumberOfTouches = 1
        keyboardPan.maximumNumberOfTouches = 1
        keyboardPan.cancelsTouchesInView = true
        add(keyboardPan)
        keyboardRevealPan = keyboardPan

        let switcherPan = UIPanGestureRecognizer(target: self, action: #selector(handleSwitcherRevealPan(_:)))
        switcherPan.minimumNumberOfTouches = 1
        switcherPan.maximumNumberOfTouches = 1
        switcherPan.cancelsTouchesInView = true
        add(switcherPan)
        switcherRevealPan = switcherPan

        let twoFingerPan = UIPanGestureRecognizer(target: self, action: #selector(handleTwoFingerPan(_:)))
        twoFingerPan.minimumNumberOfTouches = 2
        twoFingerPan.maximumNumberOfTouches = 2
        add(twoFingerPan)

        // Trackpad / Magic Keyboard two-finger scrolling arrives as scroll events (no
        // touches), which the two-touch pan never sees.
        let wheelPan = UIPanGestureRecognizer(target: self, action: #selector(handleTwoFingerPan(_:)))
        wheelPan.allowedScrollTypesMask = .continuous
        wheelPan.allowedTouchTypes = []
        wheelPan.maximumNumberOfTouches = 0
        add(wheelPan)

        // A physical mouse wheel is discrete input; keep it distinct from a trackpad
        // so Wayland clients receive the right axis source.
        let discretePan = UIPanGestureRecognizer(target: self, action: #selector(handleTwoFingerPan(_:)))
        discretePan.allowedScrollTypesMask = .discrete
        discretePan.allowedTouchTypes = []
        discretePan.maximumNumberOfTouches = 0
        add(discretePan)
        discreteScrollPan = discretePan

        let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerTap(_:)))
        twoFingerTap.numberOfTouchesRequired = 2
        add(twoFingerTap)

        let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
        hover.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        add(hover)
    }

    /// The connection dropped or is being replaced (invariant 42): end an open
    /// scroll and trackpad gesture on the outgoing link, then clear.
    func resetLatches() {
        sendScrollStop()
        if trackpadGestureActive > 0 {
            trackpadGestureActive = 1
            trackpadGestureEnded(cancelled: true)
        }
        twoFingerActive = 0
        twoFingerMode = .undecided
        pinchAnchorFramebuffer = nil
    }

    // MARK: viewport helpers

    private func fit() -> FitTransform? { host.fitTransform() }

    private func updateViewport(_ change: (inout ViewportState, ViewportState.Geometry) -> Void) {
        guard let geometry = host.viewportGeometry() else { return }
        var vp = host.viewport
        change(&vp, geometry)
        host.viewport = vp
        host.requestPresent()
    }

    // MARK: pinch / rotate

    /// A pinch or rotate with no touches on the glass came from the trackpad. Finger
    /// pinches keep zooming our own framebuffer; only indirect ones are the
    /// compositor's business.
    private func isTrackpadGesture(_ g: UIGestureRecognizer) -> Bool {
        g.numberOfTouches == 0 && host.inputLink != nil
    }

    private func trackpadGestureBegan(at point: CGPoint) {
        trackpadGestureActive += 1
        guard trackpadGestureActive == 1 else { return }
        trackpadPinchScale = 1
        trackpadRotationDegrees = 0
        trackpadGestureCenter = point
        sendTrackpadGesture(phase: 0)
    }

    private func trackpadGestureEnded(cancelled: Bool) {
        guard trackpadGestureActive > 0 else { return }
        trackpadGestureActive -= 1
        guard trackpadGestureActive == 0 else { return }
        sendTrackpadGesture(phase: cancelled ? 3 : 2)
        trackpadGestureCenter = nil
    }

    /// One gesture frame: scale and rotation absolute since begin, translation the
    /// centre's movement since the previous frame converted pt -> fb px.
    private func sendTrackpadGesture(phase: UInt32, at point: CGPoint? = nil) {
        guard let link = host.inputLink else { return }
        var dx256: Int32 = 0, dy256: Int32 = 0
        if let point, let last = trackpadGestureCenter, let fit = fit(), fit.scale > 0 {
            let ptToFb = 256 / fit.scale
            dx256 = Int32(clamping: Int(((point.x - last.x) * ptToFb).rounded()))
            dy256 = Int32(clamping: Int(((point.y - last.y) * ptToFb).rounded()))
        }
        if let point { trackpadGestureCenter = point }
        let scale256 = UInt32(max(0, (trackpadPinchScale * 256).rounded()))
        let rot256 = Int32(clamping: Int((trackpadRotationDegrees * 256).rounded()))
        link.gesture(kind: 2 /* pinch */, phase: phase, fingers: 2,
                     dx256: dx256, dy256: dy256, scale256: scale256, rot256: rot256)
    }

    @objc private func handleRotation(_ g: UIRotationGestureRecognizer) {
        guard isTrackpadGesture(g) || (trackpadGestureActive > 0 && g.numberOfTouches == 0) else { return }
        switch g.state {
        case .began:
            trackpadGestureBegan(at: g.location(in: view))
        case .changed:
            trackpadRotationDegrees = g.rotation * 180 / .pi
            sendTrackpadGesture(phase: 1, at: g.location(in: view))
        case .ended, .cancelled, .failed:
            trackpadGestureEnded(cancelled: g.state != .ended)
        default:
            break
        }
    }

    @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
        // Trackpad pinch belongs to the desktop (KDE/GTK zoom); finger pinch stays
        // ours. The second test keeps a gesture that a rotation opened flowing
        // through the same path even if this recognizer's touch count is read at an
        // awkward moment.
        if isTrackpadGesture(g) || (trackpadGestureActive > 0 && g.numberOfTouches == 0) {
            switch g.state {
            case .began:
                trackpadGestureBegan(at: g.location(in: view))
            case .changed:
                trackpadPinchScale = g.scale
                sendTrackpadGesture(phase: 1, at: g.location(in: view))
            case .ended, .cancelled, .failed:
                trackpadGestureEnded(cancelled: g.state != .ended)
            default:
                break
            }
            return
        }
        switch g.state {
        case .began:
            twoFingerBegan()
            pinchStartZoom = host.viewport.zoom
            pinchAnchorFramebuffer = fit()?.framebufferPoint(from: g.location(in: view))
        case .changed:
            let location = g.location(in: view)
            let start = pinchStartZoom, scale = g.scale
            let anchor = pinchAnchorFramebuffer
            updateViewport { vp, geo in
                vp.setZoom(start * scale, around: location, geo)
                if let fp = anchor, let t = vp.transform(geo) {
                    let rect = t.contentRect
                    vp.pan.x = location.x - geo.bounds.midX + rect.width * (0.5 - fp.x / CGFloat(geo.fbWidth))
                    vp.pan.y = location.y - geo.bounds.midY + rect.height * (0.5 - fp.y / CGFloat(geo.fbHeight))
                    vp.pan = vp.clampedPan(vp.pan, zoom: vp.zoom, geo)
                }
            }
        case .ended, .cancelled, .failed:
            pinchAnchorFramebuffer = nil
            twoFingerEnded()
        default:
            break
        }
    }

    // MARK: two-finger pan = scroll (or pan when zoomed)

    @objc private func handleTwoFingerPan(_ g: UIPanGestureRecognizer) {
        let isIndirectScroll = g.numberOfTouches == 0
        let source: UInt32 = (g === discreteScrollPan) ? 1 : 0
        switch g.state {
        case .began:
            twoFingerBegan()
            panStartOffset = host.viewport.pan
            panLastTranslation = .zero
            axisRemainder = .zero
        case .changed:
            let t = g.translation(in: view)
            if host.viewport.zoom > 1.01 {
                let start = panStartOffset
                updateViewport { vp, geo in
                    vp.pan = vp.clampedPan(CGPoint(x: start.x + t.x, y: start.y + t.y),
                                           zoom: vp.zoom, geo)
                }
            } else {
                if twoFingerMode == .undecided, isIndirectScroll || abs(t.x) + abs(t.y) > 12 {
                    twoFingerMode = .scroll
                    // Focus the surface under the fingers.
                    if let p = router.framebufferPoint(from: g.location(in: view), remember: true) {
                        host.inputLink?.motion(p.0, p.1)
                    }
                }
                if twoFingerMode == .scroll {
                    sendScroll(dx: t.x - panLastTranslation.x,
                               dy: t.y - panLastTranslation.y, source: source)
                }
            }
            panLastTranslation = t
        default:
            sendScrollStop()
            panLastTranslation = .zero
            twoFingerEnded()
        }
    }

    private func twoFingerBegan() {
        twoFingerActive += 1
        if twoFingerActive == 1 { twoFingerMode = .undecided }
        router.cancelPendingPress()   // two fingers on glass: never a click or hold
    }

    private func twoFingerEnded() {
        twoFingerActive = max(0, twoFingerActive - 1)
        if twoFingerActive == 0 { twoFingerMode = .undecided }
    }

    /// dx/dy are view-point finger deltas. AXIS records use 1/256 framebuffer pixels
    /// with wl_pointer's sign (fingers up means content scrolls down). Never
    /// synthesizes momentum: clients fling on axis_stop (invariant 33).
    private func sendScroll(dx: CGFloat, dy: CGFloat, source: UInt32) {
        guard let link = host.inputLink, let fit = fit(), fit.scale > 0 else { return }
        let ptToFb = 256 / fit.scale
        axisRemainder.x -= dx * ptToFb
        axisRemainder.y -= dy * ptToFb
        let sx = axisRemainder.x.rounded(.towardZero)
        let sy = axisRemainder.y.rounded(.towardZero)
        if sx != 0 || sy != 0 {
            axisRemainder.x -= sx
            axisRemainder.y -= sy
            axisSource = source
            link.axis(dx256: Int32(sx), dy256: Int32(sy), source: source, stop: false)
            axisActive = true
        }
    }

    /// Fingers left the glass: end the axis gesture so clients kinetic-fling.
    private func sendScrollStop() {
        axisRemainder = .zero
        guard axisActive else { return }
        axisActive = false
        host.inputLink?.axis(dx256: 0, dy256: 0, source: axisSource, stop: true)
        axisSource = 0
    }

    // MARK: taps, hover

    @objc private func handleTwoFingerTap(_ g: UITapGestureRecognizer) {
        guard let link = host.inputLink,
              let p = router.framebufferPoint(from: g.location(in: view), remember: true) else { return }
        link.motion(p.0, p.1)
        link.button(3, down: true, at: p)
        link.button(3, down: false, at: p)
    }

    @objc private func handleSwitcherTap() { host.openSwitcher() }

    @objc private func handleHover(_ g: UIHoverGestureRecognizer) {
        router.hoverMoved(to: g.location(in: view))
    }

    // MARK: edge gestures

    @objc private func handleKeyboardRevealPan(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began:
            keyboardSwipeTriggered = false
        case .changed:
            guard !keyboardSwipeTriggered else { return }
            let t = g.translation(in: view)
            guard t.y < -36, abs(t.y) > abs(t.x) * 1.4 else { return }
            keyboardSwipeTriggered = true
            router.cancelPointerInteraction()
            host.raiseKeyboard()
        case .ended, .cancelled, .failed:
            keyboardSwipeTriggered = false
        default:
            break
        }
    }

    @objc private func handleSwitcherRevealPan(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began:
            switcherSwipeTriggered = false
            router.cancelPointerInteraction()
        case .changed:
            guard !switcherSwipeTriggered else { return }
            let t = g.translation(in: view)
            guard t.y > 28, abs(t.y) > abs(t.x) * 1.25 else { return }
            switcherSwipeTriggered = true
            host.openSwitcher()
        case .ended, .cancelled, .failed:
            switcherSwipeTriggered = false
        default:
            break
        }
    }

    // MARK: delegate

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        if pan === keyboardRevealPan {
            let p = pan.location(in: view)
            let v = pan.velocity(in: view)
            return p.y >= view.bounds.height * 0.72 && v.y < -40 && abs(v.y) > abs(v.x)
        }
        if pan === switcherRevealPan {
            let p = pan.location(in: view)
            let v = pan.velocity(in: view)
            let topBand = max(view.safeAreaInsets.top + 72, view.bounds.height * 0.12)
            return p.y <= topBand && v.y > 40 && abs(v.y) > abs(v.x)
        }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldReceive touch: UITouch) -> Bool {
        var current = touch.view
        while let v = current {
            if v is UIControl || v is UITextField || v is UITextView || v is UIScrollView {
                return false
            }
            current = v.superview
        }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // Pinch and rotation must run together: one Wayland gesture carries both, so
        // letting either win exclusively would drop half of it.
        gestureRecognizer is UIPinchGestureRecognizer || other is UIPinchGestureRecognizer
            || gestureRecognizer is UIRotationGestureRecognizer
            || other is UIRotationGestureRecognizer
    }
}

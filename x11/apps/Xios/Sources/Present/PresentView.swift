import UIKit

/// The one full-screen view that shows whichever desktop is presented: a
/// CAMetalLayer, the display link, the cursor plane and all input. It knows no
/// socket and no file. Frames, input links and the clipboard come from the
/// presented SessionConnection; this view just draws, routes touches, and runs the
/// per-tick service.
///
/// Inside a desktop there is nothing but the desktop: a status pill that shows
/// briefly, and two ways out (three-finger tap, top-edge pull) that call
/// `onOpenSwitcher`.
final class PresentView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    var onOpenSwitcher: (() -> Void)?

    private let manager: SessionManager
    private var renderer: Renderer?
    private let clock = FrameClock()
    private var tickCount = 0
    var viewport = ViewportState()
    private var needsPresent = false

    /// The holding frame is black, not the last desktop's pixels: presented on a
    /// switch immediately, and after a short grace on a lost stream (a rotation
    /// reconnects within it and never shows black).
    private var blackPending = true
    private var blackAfter: Date?
    private static let blackGrace: TimeInterval = 0.6

    private lazy var router = TouchRouter(host: self)
    private lazy var gestures = GestureController(host: self, router: router, view: self)
    private lazy var keyboard = KeyboardController(view: self)
    let hardwareKeyboard = XiosHardwareKeyboard()
    private lazy var cursorPlane = CursorPlane(parent: layer)
    private let pill = StatusPill()
    private var pointerInteraction: UIPointerInteraction?

    // UITextInputTraits: keep the keyboard literal so one tap is one char (no
    // autocorrect/autocapitalize substitutions to replay). Settable and @objc so they
    // satisfy the optional UIKeyInput requirements UIKit actually reads.
    @objc var autocorrectionType: UITextAutocorrectionType = .no
    @objc var autocapitalizationType: UITextAutocapitalizationType = .none
    @objc var spellCheckingType: UITextSpellCheckingType = .no
    @objc var keyboardType: UIKeyboardType = .default
    @objc var returnKeyType: UIReturnKeyType = .default
    @objc var isSecureTextEntry: Bool = false

    init(manager: SessionManager) {
        self.manager = manager
        super.init(frame: .zero)
        backgroundColor = .black
        isMultipleTouchEnabled = true
        isAccessibilityElement = false
        pill.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pill)
        NSLayoutConstraint.activate([
            pill.centerXAnchor.constraint(equalTo: centerXAnchor),
            pill.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 18),
            pill.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.8),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Bring the view to life once Metal exists. Safe to call again.
    func bind(renderer: Renderer) {
        guard self.renderer !== renderer else { return }
        self.renderer = renderer
        renderer.attach(layer: metalLayer)
        renderer.onNeedsPresent = { [weak self] in self?.needsPresent = true }
        if clock.onTick == nil {
            gestures.install()
            installPointerInteraction()
            hardwareKeyboard.start { [weak self] keysym, down, modifiers in
                self?.inputLink?.key(keysym, down: down, mods: modifiers)
            }
            clock.onTick = { [weak self] link in self?.tick(link) }
            clock.start()
        }
        setNeedsLayout()
    }

    private func installPointerInteraction() {
        // Dress iPadOS's own pointer as the desktop's cursor while a mouse or
        // trackpad is connected. Where the system draws no pointer this stays unused
        // and the cursor plane draws ours.
        guard UIDevice.current.userInterfaceIdiom == .pad else { return }
        let pointer = UIPointerInteraction(delegate: self)
        addInteraction(pointer)
        pointerInteraction = pointer
        cursorPlane.systemPointerInteraction = pointer
    }

    /// The display link only runs while a desktop is on screen.
    func setPresenting(_ on: Bool) {
        clock.isPaused = !on
        if on {
            needsPresent = true
            setNeedsLayout()
        } else {
            pill.hide()
        }
    }

    // MARK: layout

    override func layoutSubviews() {
        super.layoutSubviews()
        let s = metalLayer.contentsScale
        metalLayer.drawableSize = CGSize(width: bounds.width * s, height: bounds.height * s)
        if let geometry = viewportGeometry() {
            viewport.pan = viewport.clampedPan(viewport.pan, zoom: viewport.zoom, geometry)
        }
        needsPresent = true
        writeGeometry()
        // Rotation or resize moved the content rect: force-resend OUTPUT (it is
        // idempotent on the wire) and re-place an idle cursor (invariant 55).
        if connection != nil { SystemIntegration.shared.syncOutputNow() }
        cursorPlane.invalidatePosition()
    }

    private var connection: SessionConnection? { manager.presented }

    func viewportGeometry() -> ViewportState.Geometry? {
        guard let surface = connection?.surface, surface.fbWidth > 0, surface.fbHeight > 0
        else { return nil }
        return ViewportState.Geometry(
            fbWidth: surface.fbWidth, fbHeight: surface.fbHeight, bounds: bounds,
            drawableSize: metalLayer.drawableSize, contentsScale: metalLayer.contentsScale)
    }

    func fitTransform() -> FitTransform? {
        guard let g = viewportGeometry() else { return nil }
        return viewport.transform(g)
    }

    /// One-line geometry snapshot for diagnosing display sizing (letterboxing).
    /// orient rawValue: 1=portrait 2=portraitUpsideDown 3=landscapeRight 4=landscapeLeft.
    private func writeGeometry() {
        let ds = metalLayer.drawableSize
        let nb = UIScreen.main.nativeBounds
        let orient = window?.windowScene?.interfaceOrientation.rawValue ?? -1
        let surface = connection?.surface
        let text = "bounds=\(Int(bounds.width))x\(Int(bounds.height)) "
            + "drawable=\(Int(ds.width))x\(Int(ds.height)) "
            + "scale=\(metalLayer.contentsScale) "
            + "fb=\(surface?.fbWidth ?? 0)x\(surface?.fbHeight ?? 0) "
            + "native=\(Int(nb.width))x\(Int(nb.height)) "
            + "orient=\(orient) ios=\(surface != nil)\n"
        StatusWriter.shared.geometry(text)
    }

    // MARK: the tick

    private func tick(_ link: CADisplayLink) {
        guard !manager.isBackgrounded, let conn = connection, let renderer else { return }
        tickCount += 1
        conn.tick(pacing: link, range: clock.range, tickCount: tickCount) {
            [clock] in clock.lastIntervalUs = $0
        }
        // Republish once the real interval is known, so `pacing=` reports the rate
        // CoreAnimation settled on rather than only the range we asked for.
        if tickCount % 120 == 0 { clock.publishStatus() }

        guard let surface = conn.surface else {
            // Holding frame: ask for very little, and show black (never the
            // previous desktop) once its grace is up.
            clock.setRange(FrameClock.holding)
            if blackPending, blackAfter.map({ Date() >= $0 }) ?? true, renderer.presentBlack() {
                blackPending = false
                blackAfter = nil
            }
            return
        }
        clock.setRange(FrameClock.live)

        let pumped = surface.pump { viewport.reset() }
        if pumped.result == .lost { conn.surfaceLost(); return }
        if pumped.newFrame { needsPresent = true }
        // Reposition the cursor independently of surface damage: a pure pointer move
        // updates the CALayer without re-presenting the framebuffer.
        cursorPlane.update(link: surface, fit: fitTransform())
        guard needsPresent else { return }
        switch surface.present(fit: fitTransform()) {
        case .presented: needsPresent = false
        case .notYet: break
        case .lost: conn.surfaceLost()
        }
    }

    // MARK: status

    /// One-off feedback while a desktop is on screen (the launcher's toast is hidden).
    func showMessage(_ text: String) { pill.show(text, sticky: false, for: 4) }

    private func refreshStatus() {
        guard let conn = connection else { return }
        let surface = conn.surface
        let size = surface.map { "\($0.fbWidth)x\($0.fbHeight)" }
            ?? conn.info.size.map { "\($0.width)x\($0.height)" } ?? "1024x768"
        let fb = surface != nil
            ? "iosurface-zerocopy \(size) [metal]"
            : "holding-frame awaiting iosurface \(size) [metal]"
        let inp: String
        if conn.openInput == nil {
            inp = "input-not-connected"
        } else {
            switch surface?.compositorID ?? "" {
            case "": inp = "input-connected wayland"
            case "mutter-ios": inp = "input-connected mutter(wayland)"
            case "iosc": inp = "input-connected iosc(wayland)"
            case let id: inp = "input-connected \(id)(wayland)"
            }
        }
        var lines = [fb, inp]
        if let error = conn.info.endpoints.configurationError, conn.info.state == .running {
            lines.append("configuration-error \(error)")
        }
        lines.append("session slot=\(conn.slot) preset=\(conn.info.preset) "
                     + "state=\(conn.info.rawState) phase=\(conn.phase)")
        StatusWriter.shared.write("xios-status.txt", lines.joined(separator: "\n") + "\n")

        let title = conn.info.title
        switch conn.phase {
        case .live:
            if conn.openInput == nil {
                pill.show("\(title): input offline", sticky: false, for: 4)
            }
        case .connecting, .reconnecting:
            pill.show("\(title): \(conn.info.message.isEmpty ? "connecting..." : conn.info.message)",
                      sticky: true)
        case .waiting:
            pill.show("\(title): \(conn.waitingReason ?? conn.info.state.title)", sticky: true)
        case .detached:
            break
        }
    }

    // MARK: keyboard responder

    override var canBecomeFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { keyboard.didBecomeFirstResponder() }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { keyboard.didResignFirstResponder() }
        return ok
    }

    override var inputAccessoryView: UIView? { keyboard.accessoryView }

    // MARK: key pad + accessibility entry points

    /// Everything the Keyboard pad sends goes through here.
    func send(keysym: UInt32, ctrl: Bool, alt: Bool, shift: Bool) {
        keyboard.sendKeysym(keysym, ctrl: ctrl, alt: alt, shift: shift)
    }

    func send(text: String) { inputLink?.text(text) }

    func sendClick(button: Int32) {
        guard let link = inputLink, let surface = connection?.surface else { return }
        let p = router.lastTouchPt ?? (Int32(surface.fbWidth / 2), Int32(surface.fbHeight / 2))
        link.motion(p.0, p.1)
        link.button(button, down: true, at: p)
        link.button(button, down: false, at: p)
    }

    /// wheel: 4 up, 5 down, 6 left, 7 right.
    func sendWheel(button: Int32) {
        guard let link = inputLink else { return }
        let step: Int32 = 36 * 256
        switch button {
        case 4: link.axis(dx256: 0, dy256: -step, source: 1, stop: false)
        case 5: link.axis(dx256: 0, dy256: step, source: 1, stop: false)
        case 6: link.axis(dx256: -step, dy256: 0, source: 1, stop: false)
        case 7: link.axis(dx256: step, dy256: 0, source: 1, stop: false)
        default: return
        }
        link.axis(dx256: 0, dy256: 0, source: 1, stop: true)
    }

    func fitToScreen() {
        viewport.reset()
        needsPresent = true
    }

    /// Inverse of the fit/zoom/pan mapping: framebuffer-px rect -> view points, then
    /// UIAccessibility converts the result to screen coordinates.
    func viewRect(fromFramebuffer r: CGRect) -> CGRect {
        guard let fit = fitTransform(), fit.scale > 0 else { return .zero }
        return fit.viewRect(fromFramebuffer: r)
    }

    /// VoiceOver escape gesture: Esc through the active desktop's input.
    func a11yEscape() { inputLink?.keyTap(0xff1b) }

    /// Helper-requested fallback tap at framebuffer px (element had no AT-SPI Action).
    func a11ySynthTap(x: Int32, y: Int32) {
        guard let link = inputLink else { return }
        router.noteTouchPoint((x, y))
        link.motion(x, y)
        link.button(1, down: true, at: (x, y))
        link.button(1, down: false, at: (x, y))
    }

    // MARK: touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        router.touchesBegan(touches, event: event)
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        router.touchesMoved(touches, event: event)
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        router.touchesEnded(touches, event: event)
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        router.touchesCancelled(touches, event: event)
    }
}

// MARK: - TouchHost / GestureHost

extension PresentView: GestureHost {
    var inputLink: InputLink? { connection?.openInput }
    var touchView: UIView { self }

    var touchReplacesPointer: Bool {
        guard let info = connection?.info else { return false }
        // Plasma Desktop is still a mouse-first shell on this stack: sending a real
        // wl_touch sequence there made taps depend on KWin/Qt touch activation while
        // the proven pointer lane sat idle. Mobile is the touch-native flavor and
        // keeps wl_touch (invariant 37).
        return info.config.touchReplacesPointer ?? (info.preset.lowercased() == "kde-mobile")
    }

    var framebufferSize: (width: Int, height: Int) {
        (connection?.surface?.fbWidth ?? 0, connection?.surface?.fbHeight ?? 0)
    }

    func touchInputBegan(_ touches: Set<UITouch>) {
        if touches.contains(where: { $0.type == .direct || $0.type == .pencil }) {
            cursorPlane.touchBegan()
        }
    }

    func hardwarePointerBegan() { cursorPlane.hardwarePointerBegan() }

    func requestPresent() { needsPresent = true }

    func openSwitcher() { onOpenSwitcher?() }

    func raiseKeyboard() { _ = becomeFirstResponder() }

    /// The committed-press diagnostic the deploy-verify workflow reads after a tap.
    /// Written only where a press commits and off the main thread; the motion and
    /// Pencil path stays free of file I/O.
    func logTouch(viewPoint p: CGPoint, framebuffer fb: (x: Int32, y: Int32)) {
        guard let fit = fitTransform() else { return }
        let rect = fit.contentRect
        let ds = metalLayer.drawableSize
        let text = "p=(\(Int(p.x)),\(Int(p.y))) bounds=\(Int(bounds.width))x\(Int(bounds.height)) "
            + "fb=\(fit.fbWidth)x\(fit.fbHeight) drawable=\(Int(ds.width))x\(Int(ds.height)) "
            + "cs=\(metalLayer.contentsScale) zoom=\(viewport.zoom) "
            + "pan=(\(Int(viewport.pan.x)),\(Int(viewport.pan.y))) "
            + "rect=(\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))) "
            + "fitScale=\(fit.scale) -> fb=(\(fb.x),\(fb.y))\n"
        StatusWriter.shared.touchLog(text)
    }
}

// MARK: - UIKeyInput

extension PresentView: UIKeyInput {
    var hasText: Bool { true }
    func insertText(_ text: String) { keyboard.insertText(text) }
    func deleteBackward() { keyboard.deleteBackward() }
}

// MARK: - pointer

extension PresentView: UIPointerInteractionDelegate {
    /// The whole screen is one region: the desktop decides the cursor, not UIKit hit
    /// testing, so the style never varies by position.
    func pointerInteraction(_ interaction: UIPointerInteraction,
                            regionFor request: UIPointerRegionRequest,
                            defaultRegion: UIPointerRegion) -> UIPointerRegion? {
        defaultRegion
    }

    func pointerInteraction(_ interaction: UIPointerInteraction,
                            styleFor region: UIPointerRegion) -> UIPointerStyle? {
        cursorPlane.systemPointerStyle()
    }
}

// MARK: - SessionPresenter

extension PresentView: SessionPresenter {
    func presenterWillRelease(_ connection: SessionConnection) {
        // Keys first, then buttons and touches; releases reach the outgoing
        // compositor only if its input link is still open (invariants 42, 43).
        hardwareKeyboard.releasePressedKeys()
        router.resetLatches()
        gestures.resetLatches()
    }

    func presenterDidPresent(_ connection: SessionConnection) {
        viewport.reset()
        cursorPlane.reset()
        keyboard.reset()
        blackPending = true
        blackAfter = nil
        needsPresent = true
        renderer?.setCompositorUpscaleHint(connection.info.config.upscaleHint)
        A11yBridge.shared.setSocket(connection.info.endpoints.a11y)
        pill.show("\(connection.info.title)", sticky: true)
        refreshStatus()
    }

    func presenterDidAdopt(_ connection: SessionConnection) {
        // A stale zoom over-scales the new framebuffer and makes the inverse touch
        // mapping land offset (invariant 17).
        viewport.reset()
        cursorPlane.reset()
        blackPending = false
        blackAfter = nil
        needsPresent = true
        renderer?.setCompositorUpscaleHint(connection.info.config.upscaleHint)
        // OUTPUT after every adopt: a compositor restarted in the same orientation
        // has forgotten it (invariant 55).
        SystemIntegration.shared.syncOutputNow()
        let size = connection.surface.map { "\($0.fbWidth)\u{00d7}\($0.fbHeight)" } ?? ""
        pill.show("\(connection.info.title)  \(size)", sticky: false)
        refreshStatus()
    }

    func presenterLostSurface(_ connection: SessionConnection) {
        cursorPlane.reset()
        needsPresent = false
        blackPending = true
        blackAfter = Date().addingTimeInterval(Self.blackGrace)
        refreshStatus()
    }

    func presenterInputOpened(_ connection: SessionConnection) { refreshStatus() }

    func presenterTraits(hint: UInt32, purpose: UInt32, enabled: UInt32) {
        keyboard.applyTraits(hint: hint, purpose: purpose, enabled: enabled)
    }

    func presenterRefresh() {
        refreshStatus()
        A11yBridge.shared.setSocket(connection?.info.endpoints.a11y)
    }
}

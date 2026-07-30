import UIKit
import Metal
import QuartzCore
import IOSurface

/// Presents ONE Linux window's canvas IOSurface in its UIWindowScene, and forwards
/// that scene's input to iosc scoped to the window.
///
/// This is the Xios app's Metal-present + input path (XScreen.swift) reduced to a
/// single window: no display picker, no zoom/pan (the compositor reflows the app to
/// the scene via RESIZE, so the canvas already fills the scene), no X/XTEST path.
/// The canvas is delivered by NativeManager over iosc-native.sock; DIRTY events
/// drive re-present; input goes over a per-scene iosc-native-input connection
/// bound to the window id.
final class HostScreenView: UIView, UIGestureRecognizerDelegate {
    let window_id: UInt32
    private weak var manager: NativeManager?

    private var canvasW = 1
    private var canvasH = 1

    // Metal
    private var device: MTLDevice!
    private var queue: MTLCommandQueue!
    private var pipeline: MTLRenderPipelineState!
    private var canvasTexture: MTLTexture?
    private var placeholderTexture: MTLTexture!
    private var metalReady = false
    private var needsPresent = false
    private var canvasFrameReady = false
    private var presentFenceToken: Data?
    private var presentFenceEvent: MTLSharedEvent?
    private var presentFenceValue: UInt64 = 0
    private var fenceFailureLogged = false
    private var displayLink: CADisplayLink?
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    override class var layerClass: AnyClass { CAMetalLayer.self }

    // iosc input (Wayland), one connection bound to this window.
    private let inputSock = "/var/jb/tmp/iosc-native-input.sock"
    private var input: OpaquePointer?          // iosc_input_t*
    private var lastInputConnectAttempt = Date.distantPast
    private var lastPt: (Int32, Int32)?
    private var touchSlots: [UITouch: Int32] = [:]
    private var pointerTouch: UITouch?         // owns the emulated wl_pointer press
    private weak var keyboardRevealPan: UIPanGestureRecognizer?
    private var keyboardSwipeTriggered = false

    // Two-finger / trackpad scroll -> AXIS (wire type 9). Mirrors XScreen.swift's
    // handleTwoFingerPan/sendScroll; single-finger pointer emulation above is
    // untouched, this is additive.
    private enum TwoFingerMode { case undecided, scroll }
    private var twoFingerMode = TwoFingerMode.undecided
    private var twoFingerActive = 0            // live two-finger/wheel recognizers (0..2)
    private var panLastTranslation = CGPoint.zero
    private var axisRemainder = CGPoint.zero
    private var axisActive = false
    private var axisSource: UInt32 = 0
    private weak var discreteScrollPan: UIPanGestureRecognizer?
    private var hardwareButtonMask = 0
    // An `.indirectPointer` touch is live, i.e. at least one button is held.
    private var hardwarePointerTouchDown = false
    private let hardwareKeyboard = XiosHardwareKeyboard()

    // UITextInputTraits — literal keyboard (one tap one char).
    @objc var autocorrectionType: UITextAutocorrectionType = .no
    @objc var autocapitalizationType: UITextAutocapitalizationType = .none
    @objc var spellCheckingType: UITextSpellCheckingType = .no
    @objc var keyboardType: UIKeyboardType = .default
    @objc var returnKeyType: UIReturnKeyType = .default
    @objc var isSecureTextEntry: Bool = false

    // Sticky one-shot modifiers (from the accessory row).
    private var modCtrl = false, modAlt = false, modShift = false

    // Auto keyboard (x11/docs/osk-plan.md): TRAITS enable raises the iOS keyboard,
    // disable lowers it. Classic/fallback paths can still broadcast broadly, so
    // only the key window's view pops.
    private var lastTraitEnabled: UInt32 = 0
    private var oskAutoShown = false          // the auto path raised the keyboard
    private var oskUserDismissed = false      // user hid it while the field was still enabled
    private var oskProgrammaticResign = false // our resign vs the user's
    private var oskHideTimer: Timer?
    private var lifecycleObservers: [NSObjectProtocol] = []

    init(window_id: UInt32, manager: NativeManager) {
        self.window_id = window_id
        self.manager = manager
        super.init(frame: .zero)
        backgroundColor = .black
        isMultipleTouchEnabled = true
        installGestures()
    }
    required init?(coder: NSCoder) { fatalError() }

    func start() {
        guard setupMetal() else {
            // GPU unreachable (background launch); retry when active.
            NotificationCenter.default.addObserver(
                self, selector: #selector(retryStart),
                name: UIApplication.didBecomeActiveNotification, object: nil)
            return
        }
        metalReady = true
        makePlaceholder()
        openInput()
        installLifecycleObservers()
        hardwareKeyboard.start { [weak self] keysym, down, modifiers in
            self?.sendHardwareKey(keysym, down: down, modifiers: modifiers)
        }
        let dl = CADisplayLink(target: self, selector: #selector(tick))
        // Asked for nothing before, which means the panel's maximum. A range lets
        // CoreAnimation throttle a thermally constrained A10 on its own instead of
        // us insisting on 60 while it is already `serious` at idle. Same lever the
        // classic Xios path uses (XScreen.liveFrameRate) and the same seam the
        // thermal track clamps.
        //
        // The rest of the classic path's pacing work does NOT apply here: the native
        // flavor draws per-window canvases via the NATIVE_FRAME record family rather
        // than one shared output surface, so there is no single dirty/present channel
        // to carry targetTimestamp back over, and presentation feedback for these
        // windows is the compositor's business. Pacing the native path properly means
        // per-window pacing state on the 0x40-0x5f records — a separate change.
        dl.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        dl.add(to: .main, forMode: .common)
        displayLink = dl
        needsPresent = true
    }

    @objc private func retryStart() {
        if metalReady { return }
        start()
    }

    /// Adopt a canvas IOSurface (WINDOW_NEW / WINDOW_GEOM). Zero-copy Metal texture.
    func adoptCanvas(_ surface: IOSurfaceRef, width: Int, height: Int) {
        guard metalReady else { return }
        canvasW = max(1, width); canvasH = max(1, height)
        let td = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: canvasW, height: canvasH, mipmapped: false)
        td.usage = .shaderRead
        td.storageMode = .shared
        canvasTexture = device.makeTexture(descriptor: td, iosurface: surface, plane: 0)
        // The port hand-off only identifies the storage. Do not sample it until
        // the matching NATIVE_FRAME arrives with a producer completion fence.
        canvasFrameReady = false
        presentFenceValue = 0
        needsPresent = false
    }

    /// Repaint only the placeholder. A disconnected compositor leaves the last
    /// completed drawable frozen; re-sampling its single-buffer canvas without a
    /// fresh producer fence would race a restart.
    func markDirty() {
        if canvasTexture == nil { needsPresent = true }
    }

    /// Adopt one producer completion. Every frame carries a broker token/value.
    func markDirty(fenceToken token: Data, value: UInt64) {
        guard metalReady, canvasTexture != nil else { return }
        guard token.count == Int(XIOS_GPU_FENCE_TOKEN_SIZE), value > 0 else {
            logFenceFailure("invalid broker token/value")
            return
        }
        if token != presentFenceToken {
            let event: MTLSharedEvent? = token.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return nil }
                return xios_metal_event_broker_copy_event(device, base, raw.count)
            }
            guard let event else {
                logFenceFailure("broker token import failed")
                return
            }
            presentFenceToken = token
            presentFenceEvent = event
        }
        guard presentFenceEvent != nil else {
            logFenceFailure("broker event unavailable")
            return
        }
        presentFenceValue = value
        fenceFailureLogged = false
        canvasFrameReady = true
        needsPresent = true
    }

    private func logFenceFailure(_ reason: String) {
        guard !fenceFailureLogged else { return }
        fenceFailureLogged = true
        NSLog("IOSCHost: refusing unfenced native frame window=%u: %@",
              window_id, reason)
    }

    // MARK: Metal

    private func setupMetal() -> Bool {
        guard let dev = MTLCreateSystemDefaultDevice(),
              let q = dev.makeCommandQueue() else { return false }
        device = dev; queue = q
        metalLayer.device = dev
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.contentsScale = UIScreen.main.scale
        guard let lib = dev.makeDefaultLibrary(),
              let vfn = lib.makeFunction(name: "v_main"),
              let ffn = lib.makeFunction(name: "f_main") else { return false }
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = vfn
        pd.fragmentFunction = ffn
        pd.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline = try? dev.makeRenderPipelineState(descriptor: pd)
        return pipeline != nil
    }

    /// A dim tile shown until the first canvas arrives (cold-launch gap).
    private func makePlaceholder() {
        let td = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 2, height: 2, mipmapped: false)
        td.usage = .shaderRead
        placeholderTexture = device.makeTexture(descriptor: td)
        var px = [UInt8](repeating: 0, count: 2 * 2 * 4)
        for i in stride(from: 0, to: px.count, by: 4) {
            px[i] = 24; px[i+1] = 24; px[i+2] = 28; px[i+3] = 255   // #1c1c1c-ish
        }
        placeholderTexture.replace(region: MTLRegionMake2D(0, 0, 2, 2),
                                   mipmapLevel: 0, withBytes: &px, bytesPerRow: 2 * 4)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let s = metalLayer.contentsScale
        metalLayer.drawableSize = CGSize(width: bounds.width * s, height: bounds.height * s)
        needsPresent = true
        // The scene's pixel size is authoritative; tell the compositor to reflow the
        // app to it (it re-lays-out and hands back a WINDOW_GEOM canvas).
        manager?.sceneResized(window_id,
                              w: Int(bounds.width * s), h: Int(bounds.height * s))
    }

    @objc private func tick() {
        serviceTraits()
        guard needsPresent, canvasTexture == nil || canvasFrameReady else { return }
        if render() {
            needsPresent = false
            if canvasTexture != nil {
                // One producer completion authorizes one sampling submission.
                // Layout waits for the next compositor frame instead of reusing
                // an old value while the single-buffer canvas may be rewritten.
                canvasFrameReady = false
                presentFenceValue = 0
            }
        }
    }

    private func installGestures() {
        let keyboardPan = UIPanGestureRecognizer(target: self, action: #selector(handleKeyboardRevealPan(_:)))
        keyboardPan.minimumNumberOfTouches = 1
        keyboardPan.maximumNumberOfTouches = 1
        keyboardPan.cancelsTouchesInView = true
        keyboardPan.delegate = self
        addGestureRecognizer(keyboardPan)
        keyboardRevealPan = keyboardPan

        let twoFingerPan = UIPanGestureRecognizer(target: self, action: #selector(handleTwoFingerPan(_:)))
        twoFingerPan.minimumNumberOfTouches = 2
        twoFingerPan.maximumNumberOfTouches = 2
        twoFingerPan.delegate = self
        addGestureRecognizer(twoFingerPan)

        // Trackpad pinch/rotate -> zwp_pointer_gestures_v1. Unlike the Xios app there is
        // no framebuffer zoom competing for the gesture here (native mode gives each
        // surface its own 1:1 window), so every indirect pinch goes to the desktop.
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self
        addGestureRecognizer(pinch)
        let rotation = UIRotationGestureRecognizer(target: self, action: #selector(handleRotation(_:)))
        rotation.delegate = self
        addGestureRecognizer(rotation)

        // Trackpad / Magic-Keyboard two-finger scrolling arrives as scroll events
        // (no touches), which the two-touch pan above never sees; a dedicated
        // recognizer feeds the same handler (mirrors XScreen.swift's wheelPan).
        let wheelPan = UIPanGestureRecognizer(target: self, action: #selector(handleTwoFingerPan(_:)))
        wheelPan.allowedScrollTypesMask = .continuous
        wheelPan.allowedTouchTypes = []
        wheelPan.maximumNumberOfTouches = 0
        wheelPan.delegate = self
        addGestureRecognizer(wheelPan)

        let discreteWheelPan = UIPanGestureRecognizer(target: self, action: #selector(handleTwoFingerPan(_:)))
        discreteWheelPan.allowedScrollTypesMask = .discrete
        discreteWheelPan.allowedTouchTypes = []
        discreteWheelPan.maximumNumberOfTouches = 0
        discreteWheelPan.delegate = self
        addGestureRecognizer(discreteWheelPan)
        discreteScrollPan = discreteWheelPan

        if #available(iOS 13.4, *) {
            let hover = UIHoverGestureRecognizer(target: self, action: #selector(handlePointerHover(_:)))
            hover.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
            hover.delegate = self
            addGestureRecognizer(hover)
        }
    }

    @objc private func handleKeyboardRevealPan(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began:
            keyboardSwipeTriggered = false
        case .changed:
            guard !keyboardSwipeTriggered else { return }
            let t = g.translation(in: self)
            guard t.y < -36, abs(t.y) > abs(t.x) * 1.4 else { return }
            keyboardSwipeTriggered = true
            releasePointerPress()
            oskUserDismissed = false
            oskHideTimer?.invalidate()
            oskHideTimer = nil
            _ = becomeFirstResponder()
        case .ended, .cancelled, .failed:
            keyboardSwipeTriggered = false
        default:
            break
        }
    }

    // MARK: trackpad gestures (pinch / rotate -> zwp_pointer_gestures_v1)

    /// One Wayland gesture carries both scale and rotation, but UIKit splits them across
    /// two recognizers that run simultaneously, so they share this state: first to start
    /// opens the gesture, last to end closes it. Mirrors XScreen.swift.
    private var trackpadGestureActive = 0
    private var trackpadPinchScale: CGFloat = 1
    private var trackpadRotationDegrees: CGFloat = 0
    private var trackpadGestureCenter: CGPoint?

    private enum XiosGesturePhase {
        static let begin: UInt32 = 0, update: UInt32 = 1, end: UInt32 = 2, cancel: UInt32 = 3
    }

    /// No touches on the glass means the trackpad drove it, the same test the indirect
    /// scroll recognizers use.
    private func isTrackpadGesture(_ g: UIGestureRecognizer) -> Bool {
        g.numberOfTouches == 0 && input != nil
    }

    private func trackpadGestureBegan(at point: CGPoint) {
        trackpadGestureActive += 1
        guard trackpadGestureActive == 1 else { return }
        trackpadPinchScale = 1
        trackpadRotationDegrees = 0
        trackpadGestureCenter = point
        sendTrackpadGesture(phase: XiosGesturePhase.begin)
    }

    private func trackpadGestureEnded(cancelled: Bool) {
        guard trackpadGestureActive > 0 else { return }
        trackpadGestureActive -= 1
        guard trackpadGestureActive == 0 else { return }
        sendTrackpadGesture(phase: cancelled ? XiosGesturePhase.cancel : XiosGesturePhase.end)
        trackpadGestureCenter = nil
    }

    /// Scale and rotation are absolute since begin (UIKit and wl_pointer agree on that);
    /// translation is the centre's movement since the last frame in canvas px.
    private func sendTrackpadGesture(phase: UInt32, at point: CGPoint? = nil) {
        guard let h = input else { return }
        var dx256: Int32 = 0, dy256: Int32 = 0
        if let point, let last = trackpadGestureCenter,
           let from = canvasPoint(from: last), let to = canvasPoint(from: point) {
            dx256 = Int32(clamping: (to.0 - from.0) * 256)
            dy256 = Int32(clamping: (to.1 - from.1) * 256)
        }
        if let point { trackpadGestureCenter = point }
        let scale256 = UInt32(max(0, (trackpadPinchScale * 256).rounded()))
        let rot256 = Int32(clamping: Int((trackpadRotationDegrees * 256).rounded()))
        iosc_input_gesture(h, 2 /* pinch */, phase, 2, dx256, dy256, scale256, rot256)
    }

    @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
        guard isTrackpadGesture(g) || (trackpadGestureActive > 0 && g.numberOfTouches == 0) else { return }
        switch g.state {
        case .began:
            trackpadGestureBegan(at: g.location(in: self))
        case .changed:
            trackpadPinchScale = g.scale
            sendTrackpadGesture(phase: XiosGesturePhase.update, at: g.location(in: self))
        case .ended, .cancelled, .failed:
            trackpadGestureEnded(cancelled: g.state != .ended)
        default:
            break
        }
    }

    /// Fires only if iPadOS forwards indirect rotation; pinch works alone if it does not.
    @objc private func handleRotation(_ g: UIRotationGestureRecognizer) {
        guard isTrackpadGesture(g) || (trackpadGestureActive > 0 && g.numberOfTouches == 0) else { return }
        switch g.state {
        case .began:
            trackpadGestureBegan(at: g.location(in: self))
        case .changed:
            trackpadRotationDegrees = g.rotation * 180 / .pi
            sendTrackpadGesture(phase: XiosGesturePhase.update, at: g.location(in: self))
        case .ended, .cancelled, .failed:
            trackpadGestureEnded(cancelled: g.state != .ended)
        default:
            break
        }
    }

    /// Two-finger touch pan or trackpad/wheel scroll -> AXIS records. Mirrors
    /// XScreen.swift's handleTwoFingerPan: park the pointer under the fingers
    /// once (MOTION) when the gesture is recognized as a scroll, then forward
    /// view-point deltas as AXIS. The single-finger pointer-emulation path in
    /// touchesBegan/Moved/Ended above is untouched; UIKit's default
    /// cancelsTouchesInView on this recognizer cancels any in-flight single
    /// touch the same way it already does for keyboardRevealPan.
    @objc private func handleTwoFingerPan(_ g: UIPanGestureRecognizer) {
        let isIndirectScroll = g.numberOfTouches == 0
        let source: UInt32 = (g === discreteScrollPan) ? 1 : 0
        switch g.state {
        case .began:
            twoFingerBegan()
            panLastTranslation = .zero
            axisRemainder = .zero
        case .changed:
            let t = g.translation(in: self)
            if twoFingerMode == .undecided, isIndirectScroll || abs(t.x) + abs(t.y) > 12 {
                twoFingerMode = .scroll
                if let (x, y) = canvasPoint(from: g.location(in: self)), let h = input {
                    lastPt = (x, y)
                    iosc_input_motion(h, x, y)   // focus the surface under the fingers
                }
            }
            if twoFingerMode == .scroll {
                sendScroll(dx: t.x - panLastTranslation.x,
                           dy: t.y - panLastTranslation.y,
                           source: source)
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
    }

    private func twoFingerEnded() {
        twoFingerActive = max(0, twoFingerActive - 1)
        if twoFingerActive == 0 { twoFingerMode = .undecided }
    }

    /// dx/dy are view-point finger deltas. iosc gets AXIS records in 1/256
    /// canvas-pixel fixed point with wl_pointer's sign (natural scroll:
    /// fingers up = content scrolls down the page = positive).
    private func sendScroll(dx: CGFloat, dy: CGFloat, source: UInt32) {
        guard let h = input, iosc_input_is_open(h) else { return }
        let rect = canvasRectInView()
        guard rect.width > 0, canvasW > 0 else { return }
        let ptToCanvas = 256 * CGFloat(canvasW) / rect.width
        axisRemainder.x -= dx * ptToCanvas
        axisRemainder.y -= dy * ptToCanvas
        let sx = axisRemainder.x.rounded(.towardZero)
        let sy = axisRemainder.y.rounded(.towardZero)
        if sx != 0 || sy != 0 {
            axisRemainder.x -= sx
            axisRemainder.y -= sy
            axisSource = source
            iosc_input_axis(h, Int32(sx), Int32(sy), source, 0, false)
            axisActive = true
        }
    }

    /// Fingers left the glass: end the axis gesture so clients kinetic-fling.
    private func sendScrollStop() {
        axisRemainder = .zero
        guard axisActive, let h = input else { return }
        axisActive = false
        iosc_input_axis(h, 0, 0, axisSource, 0, true)
        axisSource = 0
    }

    private func refreshAutoKeyboardFromTraits() {
        serviceTraits()
        raiseKeyboardFromCurrentTraitsIfNeeded()
    }

    private func installLifecycleObservers() {
        guard lifecycleObservers.isEmpty else { return }
        let center = NotificationCenter.default
        lifecycleObservers.append(center.addObserver(
            forName: UIScene.didActivateNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, note.object as? UIScene === self.window?.windowScene else { return }
            self.refreshAutoKeyboardFromTraits()
        })
        lifecycleObservers.append(center.addObserver(
            forName: UIWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, note.object as? UIWindow === self.window else { return }
            self.refreshAutoKeyboardFromTraits()
        })
    }

    private func aspectFitRect(content: CGSize, in container: CGSize) -> CGRect {
        guard content.width > 0, content.height > 0,
              container.width > 0, container.height > 0 else { return .zero }
        let scale = min(container.width / content.width, container.height / content.height)
        let fitted = CGSize(width: content.width * scale, height: content.height * scale)
        return CGRect(x: (container.width - fitted.width) / 2,
                      y: (container.height - fitted.height) / 2,
                      width: fitted.width,
                      height: fitted.height)
    }

    private func canvasRectInView() -> CGRect {
        aspectFitRect(content: CGSize(width: CGFloat(canvasW), height: CGFloat(canvasH)), in: bounds.size)
    }

    @discardableResult
    private func render() -> Bool {
        guard metalReady else { return false }
        if canvasTexture != nil {
            guard canvasFrameReady else { return false }
        }
        guard let drawable = metalLayer.nextDrawable(),
              let cmd = queue.makeCommandBuffer() else { return false }
        if canvasTexture != nil, presentFenceValue > 0 {
            guard let event = presentFenceEvent else {
                logFenceFailure("missing imported broker event")
                return false
            }
            cmd.encodeWaitForEvent(event, value: presentFenceValue)
        }
        let tex = canvasTexture ?? placeholderTexture!
        let tw = canvasTexture != nil ? canvasW : 2
        let th = canvasTexture != nil ? canvasH : 2
        let dw = Float(metalLayer.drawableSize.width), dh = Float(metalLayer.drawableSize.height)
        guard dw > 0, dh > 0 else { return false }
        // Aspect-fit: at steady state canvas == scene so this is identity; during a
        // resize transition the canvas may briefly differ and this letterboxes it.
        let fit = aspectFitRect(content: CGSize(width: CGFloat(tw), height: CGFloat(th)),
                                in: CGSize(width: CGFloat(dw), height: CGFloat(dh)))
        let sx = Float(fit.width) / dw
        let sy = Float(fit.height) / dh
        var verts: [Float] = [
            -sx,  sy, 0, 0,
            -sx, -sy, 0, 1,
             sx,  sy, 1, 0,
             sx, -sy, 1, 1,
        ]
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = drawable.texture
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        rpd.colorAttachments[0].storeAction = .store
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return false }
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBytes(&verts, length: verts.count * MemoryLayout<Float>.size, index: 0)
        enc.setFragmentTexture(tex, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
        return true
    }

    // MARK: input

    private func openInput() {
        if let h = input, iosc_input_is_open(h) { return }
        if input != nil {
            hardwareKeyboard.releasePressedKeys()
            releaseHardwarePointerButtons()
            iosc_input_close(input); input = nil
        }
        // serviceTraits() retries from the 60 Hz display link while the
        // compositor is away; throttle the socket()+connect() attempts the
        // same way HostSystemAppearance.ensureConnected does.
        let now = Date()
        guard now.timeIntervalSince(lastInputConnectAttempt) >= 1 else { return }
        lastInputConnectAttempt = now
        input = iosc_input_open(inputSock, window_id)
    }

    private func serviceTraits() {
        guard let h = input, iosc_input_is_open(h) else {
            updateAutoKeyboard(enabled: false)   // compositor gone: let the keyboard drop
            openInput()
            return
        }
        // poll_traits returns one record per call; drain them all so every
        // enable/disable transition reaches the responder policy.
        while true {
            var hint: UInt32 = 0, purpose: UInt32 = 0, enabled: UInt32 = 0
            let r = iosc_input_poll_traits(h, &hint, &purpose, &enabled)
            if r < 0 { iosc_input_close(input); input = nil; return }
            if r == 0 { return }
            applyTraits(hint: hint, purpose: purpose, enabled: enabled)
        }
    }

    private func applyTraits(hint: UInt32, purpose: UInt32, enabled: UInt32) {
        lastTraitEnabled = enabled
        updateAutoKeyboard(enabled: enabled != 0)
        if enabled == 0 {
            isSecureTextEntry = false; keyboardType = .default; returnKeyType = .default
            autocorrectionType = .no; spellCheckingType = .no; autocapitalizationType = .none
            if isFirstResponder { reloadInputViews() }
            return
        }
        let hidden = (hint & 0x40) != 0, sensitive = (hint & 0x80) != 0
        let multiline = (hint & 0x200) != 0
        let secure = hidden || sensitive || purpose == 8 || purpose == 9
        isSecureTextEntry = secure
        returnKeyType = multiline ? .default : .done
        switch purpose {
        case 2, 9: keyboardType = .numberPad
        case 3:    keyboardType = .numbersAndPunctuation
        case 4:    keyboardType = .phonePad
        case 5:    keyboardType = .URL; returnKeyType = .go
        case 6:    keyboardType = .emailAddress
        default:   keyboardType = .default
        }
        if isFirstResponder { reloadInputViews() }
    }

    /// Map a view point to canvas pixels (aspect-fit, same rect render() uses).
    private func canvasPoint(from p: CGPoint) -> (Int32, Int32)? {
        guard canvasTexture != nil, canvasW > 0, canvasH > 0,
              bounds.width > 0, bounds.height > 0 else { return nil }
        let rect = canvasRectInView()
        guard rect.contains(p) else { return nil }
        let fx = (p.x - rect.minX) / rect.width * CGFloat(canvasW)
        let fy = (p.y - rect.minY) / rect.height * CGFloat(canvasH)
        return (Int32(max(0, min(CGFloat(canvasW - 1), fx))),
                Int32(max(0, min(CGFloat(canvasH - 1), fy))))
    }

    // MARK: accessibility (HostA11y.swift publishes onto this view)

    var canvasSize: CGSize { CGSize(width: canvasW, height: canvasH) }

    /// Inverse of canvasPoint's aspect-fit mapping: canvas-px rect -> view
    /// points (identity at steady state; letterboxed only mid-resize).
    func viewRect(fromCanvas r: CGRect) -> CGRect {
        guard canvasW > 0, canvasH > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let rect = canvasRectInView()
        let scale = rect.width / CGFloat(canvasW)
        return CGRect(x: rect.minX + r.minX * scale, y: rect.minY + r.minY * scale,
                      width: r.width * scale, height: r.height * scale)
    }

    /// VoiceOver escape gesture: Esc down this window's own input connection.
    func a11yEscape() { sendKeysym(0xff1b, ctrl: false, alt: false, shift: false) }

    /// Helper-requested fallback tap at canvas px (element had no AT-SPI Action).
    func a11ySynthTap(x: Int32, y: Int32) {
        guard let h = input, iosc_input_is_open(h) else { return }
        iosc_input_motion(h, x, y)
        iosc_input_button(h, 1, true, x, y)
        iosc_input_button(h, 1, false, x, y)
    }

    private func slot(for t: UITouch) -> Int32 {
        if let s = touchSlots[t] { return s }
        var s: Int32 = 0
        while touchSlots.values.contains(s) { s += 1 }
        touchSlots[t] = s
        return s
    }

    /// Forward one UITouch as touch (finger) or tablet (Pencil).
    private func forward(_ t: UITouch, phase: Int32, event: UIEvent?) {
        guard let h = input, iosc_input_is_open(h) else { return }
        if t.type == .pencil {
            if phase == 0 || phase == 3 {
                let p = canvasPoint(from: t.location(in: self)) ?? lastPt ?? (0, 0)
                iosc_input_tablet(h, phase, p.0, p.1, 0, 0, 0)
                return
            }
            let samples = (phase == 2 ? event?.coalescedTouches(for: t) : nil) ?? [t]
            for s in samples {
                guard let (x, y) = canvasPoint(from: s.location(in: self)) ?? lastPt else { continue }
                lastPt = (x, y)
                let force = s.maximumPossibleForce > 0 ? Double(s.force / s.maximumPossibleForce) : 1.0
                let mag = 90.0 - Double(s.altitudeAngle) * 180.0 / .pi
                let az = Double(s.azimuthAngle(in: self))
                iosc_input_tablet(h, phase, x, y,
                                  UInt32((force * 65535.0).rounded()),
                                  Int32((mag * cos(az)).rounded()),
                                  Int32((mag * sin(az)).rounded()))
            }
            return
        }
        let sl = slot(for: t)
        if phase == 0 || phase == 3 { touchSlots[t] = nil }
        guard let (x, y) = canvasPoint(from: t.location(in: self)) else {
            if phase == 0 || phase == 3 { iosc_input_touch(h, sl, phase, 0, 0) }
            return
        }
        lastPt = (x, y)
        iosc_input_touch(h, sl, phase, x, y)
    }

    // Touch handling: forward real multitouch/Pencil AND emulate a single-finger
    // pointer (so wl_pointer clients react even if they ignore wl_touch), same
    // additive policy as the Xios app.
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        refreshAutoKeyboardFromTraits()
        if #available(iOS 13.4, *), handleHardwarePointer(touches, event: event, phase: .down) { return }
        for t in touches { forward(t, phase: 1, event: event) }
        if (event?.allTouches?.count ?? touches.count) == 1, let t = touches.first,
           let (x, y) = canvasPoint(from: t.location(in: self)), let h = input {
            lastPt = (x, y); iosc_input_motion(h, x, y); iosc_input_button(h, 1, true, x, y)
            pointerTouch = t
        }
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if #available(iOS 13.4, *), handleHardwarePointer(touches, event: event, phase: .move) { return }
        for t in touches { forward(t, phase: 2, event: event) }
        if (event?.allTouches?.count ?? touches.count) == 1, let t = touches.first,
           let (x, y) = canvasPoint(from: t.location(in: self)), let h = input {
            lastPt = (x, y); iosc_input_motion(h, x, y)
        }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if #available(iOS 13.4, *), handleHardwarePointer(touches, event: event, phase: .up) { return }
        for t in touches { forward(t, phase: 0, event: event) }
        releasePointerIfNeeded(touches)
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        if #available(iOS 13.4, *), handleHardwarePointer(touches, event: event, phase: .up) {
            return
        }
        for t in touches { forward(t, phase: 3, event: event) }
        releasePointerIfNeeded(touches)
    }
    /// Balance the emulated press from touchesBegan: release only when the touch
    /// that sent it lifts (mirrors XScreen's leftPressSent gate; without this a
    /// multi-finger gesture emitted unmatched releases, which warp the pointer to
    /// a stale point and abort compositor drags/interactive ops).
    private func releasePointerIfNeeded(_ touches: Set<UITouch>) {
        guard let pt = pointerTouch, touches.contains(pt) else { return }
        releasePointerPress()
    }

    private func releasePointerPress() {
        pointerTouch = nil
        guard let h = input, let p = lastPt else { return }
        iosc_input_button(h, 1, false, p.0, p.1)
    }

    @available(iOS 13.4, *)
    @objc private func handlePointerHover(_ g: UIHoverGestureRecognizer) {
        // A button still marked down during hover outlived its touch, and every motion
        // from here would be a drag. Mirrors XScreen's hover self-heal.
        if hardwareButtonMask != 0 && !hardwarePointerTouchDown {
            releaseHardwarePointerButtons()
        }
        guard let point = canvasPoint(from: g.location(in: self)), let h = input else { return }
        lastPt = point
        iosc_input_motion(h, point.0, point.1)
    }

    /// Whether an `.indirectPointer` touch is starting, continuing, or finished.
    private enum HardwarePointerPhase { case down, move, up }

    @available(iOS 13.4, *)
    private func handleHardwarePointer(_ touches: Set<UITouch>, event: UIEvent?,
                                      phase: HardwarePointerPhase) -> Bool {
        guard let touch = touches.first(where: { $0.type == .indirectPointer }) else { return false }
        if let point = canvasPoint(from: touch.location(in: self)), let h = input {
            lastPt = point
            iosc_input_motion(h, point.0, point.1)
        }
        hardwarePointerTouchDown = phase != .up
        updateHardwarePointerButtons(hardwarePointerMask(event, phase: phase))
        return true
    }

    /// Button state for a mouse/trackpad press. The touch phase is authoritative and
    /// `buttonMask` only refines it: an `.indirectPointer` touch exists solely while a
    /// button is held, so a press with an empty mask is still a press and an ended touch
    /// is always all-up. Deriving the state from the mask alone latched the button down
    /// on the first click, so every later hover dragged and no click ever activated
    /// anything. Mirrors XScreen.hardwarePointerMask.
    private func hardwarePointerMask(_ event: UIEvent?, phase: HardwarePointerPhase) -> Int {
        if phase == .up { return 0 }
        let mask = event?.buttonMask.rawValue ?? 0
        if mask != 0 { return mask }
        return hardwareButtonMask != 0 ? hardwareButtonMask : 1   // bit 0 = primary
    }

    private func updateHardwarePointerButtons(_ nextMask: Int) {
        let changed = hardwareButtonMask ^ nextMask
        guard changed != 0, let h = input else { hardwareButtonMask = nextMask; return }
        let buttons: [Int32] = [1, 3, 2, 0x113, 0x114]
        let point = lastPt ?? (0, 0)
        for index in 0..<buttons.count where changed & (1 << index) != 0 {
            iosc_input_button(h, buttons[index], nextMask & (1 << index) != 0,
                              point.0, point.1)
        }
        hardwareButtonMask = nextMask
    }

    private func releaseHardwarePointerButtons() {
        hardwarePointerTouchDown = false
        guard hardwareButtonMask != 0 else { return }
        updateHardwarePointerButtons(0)
    }

    // MARK: keyboard

    override var canBecomeFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { oskUserDismissed = false }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok && !oskProgrammaticResign {
            // The user hid the keyboard (dismiss key) while the field
            // may still be focused: don't fight them on the next broadcast.
            if lastTraitEnabled != 0 { oskUserDismissed = true }
            oskAutoShown = false
        }
        return ok
    }

    // The responder half of the auto keyboard; runs on every TRAITS record,
    // before applyTraits' field mapping (design: x11/docs/osk-plan.md).
    private func updateAutoKeyboard(enabled: Bool) {
        if enabled {
            oskHideTimer?.invalidate()
            oskHideTimer = nil
            raiseKeyboardFromCurrentTraitsIfNeeded()
        } else {
            oskUserDismissed = false   // focus left the field; the next enable may raise again
            guard oskAutoShown, oskHideTimer == nil else { return }
            // Debounce: a focus hop between two fields is disable then enable
            // back to back; don't slide the keyboard down for the gap.
            oskHideTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
                guard let self else { return }
                self.oskHideTimer = nil
                guard self.oskAutoShown else { return }
                self.oskProgrammaticResign = true
                _ = self.resignFirstResponder()
                self.oskProgrammaticResign = false
                self.oskAutoShown = false
            }
        }
    }

    private func raiseKeyboardFromCurrentTraitsIfNeeded() {
        guard lastTraitEnabled != 0,
              !isFirstResponder,
              !oskUserDismissed,
              window?.isKeyWindow == true
        else { return }
        if becomeFirstResponder() { oskAutoShown = true }
    }

    fileprivate func keysym(for ch: Character) -> UInt? {
        if ch == "\n" || ch == "\r" { return 0xff0d }
        if ch == "\t" { return 0xff09 }
        let scalars = ch.unicodeScalars
        guard scalars.count == 1, let v = scalars.first?.value else { return nil }
        if (0x20...0x7e).contains(v) || (0xa0...0xff).contains(v) { return UInt(v) }
        return nil
    }

    fileprivate func sendKeysym(_ ks: UInt, ctrl: Bool, alt: Bool, shift: Bool) {
        guard let h = input else { return }
        var mods: UInt32 = 0
        if shift { mods |= 1 }; if ctrl { mods |= 2 }; if alt { mods |= 4 }
        iosc_input_key(h, UInt32(ks), true, mods)
        iosc_input_key(h, UInt32(ks), false, 0)
    }

    private func sendHardwareKey(_ keysym: UInt32, down: Bool, modifiers: UInt32) {
        guard let h = input, iosc_input_is_open(h) else { return }
        iosc_input_key(h, keysym, down, modifiers)
    }

    fileprivate func sendText(_ text: String) {
        guard let h = input else { return }
        text.withCString { iosc_input_text(h, $0) }
    }

    fileprivate func clearStickyMods() { modCtrl = false; modAlt = false; modShift = false }

    // Accessory row: esc/tab/ctrl/alt/shift/arrows, same idea as XScreen's modRow.
    // Built once and cached (as in XScreen): UIKit re-queries this on every responder
    // change and on reloadInputViews() (each TRAITS record while first responder), and
    // a fresh instance per query makes UIKit tear down and re-install the bar each time.
    private lazy var modRow: UIView = buildModRow()
    override var inputAccessoryView: UIView? { modRow }

    private func buildModRow() -> UIView {
        let bar = UIInputView(frame: CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: 48),
                              inputViewStyle: .keyboard)
        bar.autoresizingMask = .flexibleWidth
        let stack = UIStackView(); stack.axis = .horizontal; stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bar.safeAreaLayoutGuide.leadingAnchor, constant: 8),
            stack.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])
        func cap(_ t: String, _ a: @escaping () -> Void) -> UIButton {
            let b = UIButton(type: .system)
            b.setTitle(t, for: .normal); b.setTitleColor(.white, for: .normal)
            b.backgroundColor = UIColor(white: 0.28, alpha: 1); b.layer.cornerRadius = 6
            b.contentEdgeInsets = UIEdgeInsets(top: 7, left: 12, bottom: 7, right: 12)
            b.addAction(UIAction { _ in a() }, for: .touchUpInside)
            return b
        }
        // [weak self] throughout: self retains the cached row, so a strong capture
        // here would be a permanent self -> modRow -> button -> action -> self cycle
        // (and HostScreenView is per-window, torn down on window close).
        let special: (UInt) -> Void = { [weak self] ks in
            guard let self else { return }
            self.sendKeysym(ks, ctrl: self.modCtrl, alt: self.modAlt, shift: self.modShift)
            self.clearStickyMods()
        }
        stack.addArrangedSubview(cap("esc") { special(0xff1b) })
        stack.addArrangedSubview(cap("tab") { special(0xff09) })
        stack.addArrangedSubview(cap("ctrl") { [weak self] in self?.modCtrl.toggle() })
        stack.addArrangedSubview(cap("alt") { [weak self] in self?.modAlt.toggle() })
        stack.addArrangedSubview(cap("shift") { [weak self] in self?.modShift.toggle() })
        stack.addArrangedSubview(cap("←") { special(0xff51) })
        stack.addArrangedSubview(cap("↑") { special(0xff52) })
        stack.addArrangedSubview(cap("↓") { special(0xff54) })
        stack.addArrangedSubview(cap("→") { special(0xff53) })
        return bar
    }

    func teardown() {
        hardwareKeyboard.stop()
        releaseHardwarePointerButtons()
        displayLink?.invalidate(); displayLink = nil
        for obs in lifecycleObservers { NotificationCenter.default.removeObserver(obs) }
        lifecycleObservers.removeAll()
        oskHideTimer?.invalidate(); oskHideTimer = nil
        if input != nil { iosc_input_close(input); input = nil }
        canvasTexture = nil
        canvasFrameReady = false
        presentFenceToken = nil
        presentFenceEvent = nil
        presentFenceValue = 0
        accessibilityElements = nil
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if let keyboardRevealPan, gestureRecognizer === keyboardRevealPan {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let p = pan.location(in: self)
            let v = pan.velocity(in: self)
            return p.y >= bounds.height * 0.72 && v.y < -40 && abs(v.y) > abs(v.x)
        }
        return true
    }

    /// Pinch and rotation must run together: one Wayland gesture carries both scale and
    /// rotation, so letting either win exclusively would silently drop half of it.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        gestureRecognizer is UIPinchGestureRecognizer || other is UIPinchGestureRecognizer
            || gestureRecognizer is UIRotationGestureRecognizer
            || other is UIRotationGestureRecognizer
    }
}

extension HostScreenView: UIKeyInput {
    var hasText: Bool { true }
    func insertText(_ text: String) {
        if hardwareKeyboard.isLikelyUIKitEcho() { return }
        if !modCtrl && !modAlt && !modShift { sendText(text); return }
        for ch in text where keysym(for: ch) != nil {
            sendKeysym(keysym(for: ch)!, ctrl: modCtrl, alt: modAlt, shift: modShift)
        }
        clearStickyMods()
    }
    func deleteBackward() {
        if hardwareKeyboard.isLikelyUIKitEcho() { return }
        sendKeysym(0xff08, ctrl: modCtrl, alt: modAlt, shift: modShift)
        clearStickyMods()
    }
}

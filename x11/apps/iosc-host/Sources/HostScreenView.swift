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
/// drive re-present; input goes over a per-scene iosc-input connection bound to the
/// window id.
final class HostScreenView: UIView {
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
    private var displayLink: CADisplayLink?
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    override class var layerClass: AnyClass { CAMetalLayer.self }

    // iosc input (Wayland), one connection bound to this window.
    private let inputSock = "/var/jb/tmp/iosc-input.sock"
    private var input: OpaquePointer?          // iosc_input_t*
    private var lastPt: (Int32, Int32)?
    private var touchSlots: [UITouch: Int32] = [:]

    // UITextInputTraits — literal keyboard (one tap one char).
    @objc var autocorrectionType: UITextAutocorrectionType = .no
    @objc var autocapitalizationType: UITextAutocapitalizationType = .none
    @objc var spellCheckingType: UITextSpellCheckingType = .no
    @objc var keyboardType: UIKeyboardType = .default
    @objc var returnKeyType: UIReturnKeyType = .default
    @objc var isSecureTextEntry: Bool = false

    // Sticky one-shot modifiers (from the accessory row).
    private var modCtrl = false, modAlt = false, modShift = false

    init(window_id: UInt32, manager: NativeManager) {
        self.window_id = window_id
        self.manager = manager
        super.init(frame: .zero)
        backgroundColor = .black
        isMultipleTouchEnabled = true
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
        let dl = CADisplayLink(target: self, selector: #selector(tick))
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
        needsPresent = true
    }

    func markDirty() { needsPresent = true }

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
        guard needsPresent else { return }
        if render() { needsPresent = false }
    }

    @discardableResult
    private func render() -> Bool {
        guard metalReady, let drawable = metalLayer.nextDrawable(),
              let cmd = queue.makeCommandBuffer() else { return false }
        let tex = canvasTexture ?? placeholderTexture!
        let tw = canvasTexture != nil ? canvasW : 2
        let th = canvasTexture != nil ? canvasH : 2
        let dw = Float(metalLayer.drawableSize.width), dh = Float(metalLayer.drawableSize.height)
        guard dw > 0, dh > 0 else { return false }
        // Aspect-fit: at steady state canvas == scene so this is identity; during a
        // resize transition the canvas may briefly differ and this letterboxes it.
        let scale = min(dw / Float(tw), dh / Float(th))
        let sx = Float(tw) * scale / dw
        let sy = Float(th) * scale / dh
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
        if input != nil { iosc_input_close(input); input = nil }
        input = iosc_input_open(inputSock, window_id)
    }

    private func serviceTraits() {
        guard let h = input, iosc_input_is_open(h) else { openInput(); return }
        var hint: UInt32 = 0, purpose: UInt32 = 0, enabled: UInt32 = 0
        let r = iosc_input_poll_traits(h, &hint, &purpose, &enabled)
        if r < 0 { iosc_input_close(input); input = nil }
        else if r > 0 { applyTraits(hint: hint, purpose: purpose, enabled: enabled) }
    }

    private func applyTraits(hint: UInt32, purpose: UInt32, enabled: UInt32) {
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
        let scale = min(bounds.width / CGFloat(canvasW), bounds.height / CGFloat(canvasH))
        let sizeW = CGFloat(canvasW) * scale, sizeH = CGFloat(canvasH) * scale
        let ox = bounds.midX - sizeW / 2, oy = bounds.midY - sizeH / 2
        let rect = CGRect(x: ox, y: oy, width: sizeW, height: sizeH)
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
        let scale = min(bounds.width / CGFloat(canvasW), bounds.height / CGFloat(canvasH))
        let ox = bounds.midX - CGFloat(canvasW) * scale / 2
        let oy = bounds.midY - CGFloat(canvasH) * scale / 2
        return CGRect(x: ox + r.minX * scale, y: oy + r.minY * scale,
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
        for t in touches { forward(t, phase: 1, event: event) }
        if (event?.allTouches?.count ?? touches.count) == 1, let t = touches.first,
           let (x, y) = canvasPoint(from: t.location(in: self)), let h = input {
            lastPt = (x, y); iosc_input_motion(h, x, y); iosc_input_button(h, 1, true, x, y)
        }
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches { forward(t, phase: 2, event: event) }
        if (event?.allTouches?.count ?? touches.count) == 1, let t = touches.first,
           let (x, y) = canvasPoint(from: t.location(in: self)), let h = input {
            lastPt = (x, y); iosc_input_motion(h, x, y)
        }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches { forward(t, phase: 0, event: event) }
        if let h = input, let p = lastPt { iosc_input_button(h, 1, false, p.0, p.1) }
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches { forward(t, phase: 3, event: event) }
        if let h = input, let p = lastPt { iosc_input_button(h, 1, false, p.0, p.1) }
    }

    // MARK: keyboard

    override var canBecomeFirstResponder: Bool { true }

    func toggleKeyboard() {
        if isFirstResponder { _ = resignFirstResponder() } else { _ = becomeFirstResponder() }
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
        iosc_input_key(h, UInt32(ks), mods)
    }

    fileprivate func sendText(_ text: String) {
        guard let h = input else { return }
        text.withCString { iosc_input_text(h, $0) }
    }

    fileprivate func clearStickyMods() { modCtrl = false; modAlt = false; modShift = false }

    // Accessory row: esc/tab/ctrl/alt/shift/arrows, same idea as XScreen's modRow.
    override var inputAccessoryView: UIView? { buildModRow() }

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
        func special(_ ks: UInt) { sendKeysym(ks, ctrl: modCtrl, alt: modAlt, shift: modShift); clearStickyMods() }
        stack.addArrangedSubview(cap("esc") { special(0xff1b) })
        stack.addArrangedSubview(cap("tab") { special(0xff09) })
        stack.addArrangedSubview(cap("ctrl") { self.modCtrl.toggle() })
        stack.addArrangedSubview(cap("alt") { self.modAlt.toggle() })
        stack.addArrangedSubview(cap("shift") { self.modShift.toggle() })
        stack.addArrangedSubview(cap("←") { special(0xff51) })
        stack.addArrangedSubview(cap("↑") { special(0xff52) })
        stack.addArrangedSubview(cap("↓") { special(0xff54) })
        stack.addArrangedSubview(cap("→") { special(0xff53) })
        return bar
    }

    func teardown() {
        displayLink?.invalidate(); displayLink = nil
        if input != nil { iosc_input_close(input); input = nil }
        canvasTexture = nil
        accessibilityElements = nil
    }
}

extension HostScreenView: UIKeyInput {
    var hasText: Bool { true }
    func insertText(_ text: String) {
        if !modCtrl && !modAlt && !modShift { sendText(text); return }
        for ch in text where keysym(for: ch) != nil {
            sendKeysym(keysym(for: ch)!, ctrl: modCtrl, alt: modAlt, shift: modShift)
        }
        clearStickyMods()
    }
    func deleteBackward() {
        sendKeysym(0xff08, ctrl: modCtrl, alt: modAlt, shift: modShift)
        clearStickyMods()
    }
}

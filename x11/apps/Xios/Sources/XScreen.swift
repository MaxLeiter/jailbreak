import UIKit
import Metal
import QuartzCore
import IOSurface

/// Root VC: a full-screen view that displays the X server's framebuffer.
final class XServerViewController: UIViewController {
    private let screen = XScreenView()
    override func loadView() { view = screen }
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        screen.start()
    }
}

/// Displays an X11 framebuffer on a CAMetalLayer at native retina resolution and
/// injects touch as X pointer events via XTEST. Until a framebuffer exists, shows a
/// live test pattern.
///
/// Two display paths, selected by `xios.json`:
///  • IOSurface (zero-copy) — when `"ddx":"iosurface"`: the Xios DDX shares its
///    framebuffer as an IOSurface; we map it straight into a Metal texture
///    (`makeTexture(descriptor:iosurface:)`) and re-present only on damage. No
///    per-frame upload (vs. ~14 MB/frame at 2160×1620).
///  • Xvfb file (fallback) — the original `-fbdir` mmap path, uploaded each frame.
///
/// Pixel format is 32-bit BGRA on both paths.
final class XScreenView: UIView {
    private var fbWidth = 1024
    private var fbHeight = 768
    private var fbHeaderOffset = 0
    private let fbPath = "/var/jb/tmp/Xvfb_screen0"
    private let configPath = "/var/jb/tmp/xios.json"
    // Which X display to drive (XTEST input). The server advertises this in
    // xios.json so the app and the launch scripts can't disagree; `:3` is only a
    // fallback for an older server that doesn't write the field. Not pinned: the
    // picker can switch it to any open display (see discoverDisplays()/load()).
    private var xDisplay = ":3"
    private var xAuthPath: String?              // MIT-MAGIC-COOKIE-1 file from xios.json
    private let xunixDirs = ["/tmp/.X11-unix", "/var/jb/tmp/.X11-unix"]
    // Bumped on every load(); the async IOSurface connect captures it and bails if a
    // newer load() superseded it, so switching displays can't adopt a stale surface.
    private var loadGeneration = 0
    private var userPinned = false              // user picked a display → stop auto-reloading xios.json
    private var displayChip: UIButton?
    private var zoomButton: UIButton?
    private weak var keyboardButton: UIButton?
    private weak var toolsButton: UIButton?
    private weak var pickerOverlay: UIView?
    private let requestPath = "/var/jb/tmp/xios-request.json"
    private let debugPath = "/var/jb/tmp/xios-debug.txt"
    private var lastToolMessage = "No profile request sent"
    // UITextInputTraits — keep the keyboard literal so one tap is one char (no
    // autocorrect/autocapitalize substitutions to replay). Settable + @objc so they
    // satisfy the optional UIKeyInput requirements UIKit actually reads.
    @objc var autocorrectionType: UITextAutocorrectionType = .no
    @objc var autocapitalizationType: UITextAutocapitalizationType = .none
    @objc var spellCheckingType: UITextSpellCheckingType = .no
    @objc var keyboardType: UIKeyboardType = .default
    @objc var returnKeyType: UIReturnKeyType = .default
    @objc var isSecureTextEntry: Bool = false

    // Modifier row (docked above the keyboard). Ctrl/Alt/Shift are sticky one-shots:
    // armed by a tap, applied to the next key, then auto-cleared.
    private var modRow: UIView?
    private var modCtrl = false, modAlt = false, modShift = false
    private var lastIoscTraitHint: UInt32 = 0
    private var lastIoscTraitPurpose: UInt32 = 0
    private var lastIoscTraitEnabled: UInt32 = 0
    private weak var ctrlBtn: UIButton?
    private weak var altBtn: UIButton?
    private weak var shiftBtn: UIButton?
    private var activeDisplayNumber: Int? { Int(xDisplay.dropFirst()) }

    // View transform. The framebuffer is rendered aspect-fit at zoom=1, then scaled
    // and panned in view coordinates. Pointer mapping uses the same rect.
    private let minZoomScale: CGFloat = 1
    private let maxZoomScale: CGFloat = 6
    private var zoomScale: CGFloat = 1
    private var panOffset = CGPoint.zero
    private var pinchStartZoom: CGFloat = 1
    private var pinchAnchorFramebuffer: CGPoint?
    private var panStartOffset = CGPoint.zero
    private var panLastTranslation = CGPoint.zero
    private var scrollRemainder = CGPoint.zero

    // IOSurface (zero-copy) path
    private var ddxIsIOSurface = false
    private var ddxSockPath = "/var/jb/tmp/xios-ddx.sock"
    private var xconn: OpaquePointer?            // XSurfaceConn*
    private var iosTexture: MTLTexture?
    private var usingIOSurface = false
    private var iosConnectStarted = false
    private var needsPresent = false

    private var displayLink: CADisplayLink?
    private var mapped: UnsafeMutableRawPointer?
    private var mappedLen = 0
    private var testBuf: UnsafeMutablePointer<UInt8>?
    private var usingTestPattern = false
    private var inputConnected = false
    private var tickCount = 0

    // iosc (Wayland compositor) input path. When the app displays iosc's output rather
    // than an X server, single-finger touch + the keyboard are forwarded over this Unix
    // socket as Wayland pointer/keyboard events (see IoscInput.h) instead of via XTEST.
    // nil = not iosc mode (use the XTEST path). Resolved in loadConfig() from xios.json.
    private var ioscInputSock: String?
    private var ioscClipboardSock: String?
    private var pasteboardChangeCount = UIPasteboard.general.changeCount
    private var lastSentPasteboard: String?
    private var usingIosc: Bool { ioscInputSock != nil }
    // Last single-finger point in output px, so a touch-up (whose UIKit location we may
    // not be able to map) can send the iosc button-release at the right spot.
    private var lastTouchPt: (Int32, Int32)?

    private struct DisplayProfile {
        let name: String
        let width: Int
        let height: Int
        let dpi: Int
        let detail: String
    }

    // Metal
    private var device: MTLDevice!
    private var queue: MTLCommandQueue!
    private var pipeline: MTLRenderPipelineState!
    private var texture: MTLTexture!
    private var metalReady = false              // setupMetal() succeeded; guards the
    private var didRegisterActiveRetry = false  // background-launch foreground retry
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    override class var layerClass: AnyClass { CAMetalLayer.self }

    func start() {
        loadConfig()
        isMultipleTouchEnabled = true
        // MTLCreateSystemDefaultDevice() returns nil for a backgrounded app (a
        // SpringBoard relaunch, or uicache registration launching us off-screen), so a
        // background launch would otherwise leave us permanently black with no recovery.
        // Retry once we become active/foreground, where the GPU is reachable.
        if !setupMetal() { observeForegroundRetry(); return }
        metalReady = true

        if ddxIsIOSurface {
            // Zero-copy path. Connect off the main thread (the handshake does a
            // blocking mach_msg); show the test pattern until the surface arrives.
            startTestPattern()
            startIOSurfaceConnect()
        } else if !mapFramebuffer() {
            startTestPattern()
        } else {
            makeTexture()
        }
        connectInput()
        writeStatus()

        let dl = CADisplayLink(target: self, selector: #selector(tick))
        dl.preferredFramesPerSecond = usingTestPattern ? 20 : 60
        dl.add(to: .main, forMode: .common)
        displayLink = dl

        installChrome()
        // start() already loaded the display in xios.json (the default). If other
        // displays are also open, offer the picker so the user can choose.
        let displays = discoverDisplays()
        if displays.count > 1 { presentPicker(displays) }
    }

    /// If Metal wasn't available at launch (app started in the background), re-run
    /// start() the next time we become active. One-shot registration, guarded by
    /// metalReady so a successful setup never re-initialises.
    private func observeForegroundRetry() {
        if didRegisterActiveRetry { return }
        didRegisterActiveRetry = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(retryStartIfNeeded),
            name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    @objc private func retryStartIfNeeded() {
        if metalReady { return }   // already up; nothing to do
        start()                    // setupMetal() should now succeed in the foreground
    }

    /// Show the animated test pattern until a real framebuffer is available.
    private func startTestPattern() {
        usingTestPattern = true
        testBuf?.deallocate()       // safe to call when switching displays
        testBuf = .allocate(capacity: fbWidth * fbHeight * 4)
        makeTexture()
        displayLink?.preferredFramesPerSecond = 20
    }

    // MARK: IOSurface (zero-copy) path

    /// Begin connecting to the IOSurface backend (once). Safe to call from both
    /// start() and the poll path, in either app/server launch order.
    private func startIOSurfaceConnect() {
        if iosConnectStarted { return }
        iosConnectStarted = true
        let path = ddxSockPath
        let gen = loadGeneration
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Retry until the X server's socket is up (it may launch after the app),
            // but bail the moment a newer load() superseded this connect.
            for _ in 0..<120 {
                guard let self, self.loadGeneration == gen else { return }
                if let conn = xsurface_connect(path) {
                    DispatchQueue.main.async {
                        if self.loadGeneration == gen { self.adoptIOSurface(conn) }
                        else { xsurface_close(conn) }   // user switched away mid-connect
                    }
                    return
                }
                Thread.sleep(forTimeInterval: 0.5)
            }
            DispatchQueue.main.async {
                if let self, self.loadGeneration == gen { self.iosConnectStarted = false }  // allow retry
            }
        }
    }

    private func adoptIOSurface(_ conn: OpaquePointer) {
        // C owns the IOSurface ref (released in xsurface_close); borrow it here.
        let surface = xsurface_get(conn).takeUnretainedValue()
        xconn = conn
        fbWidth = Int(xsurface_width(conn))
        fbHeight = Int(xsurface_height(conn))

        let td = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: fbWidth, height: fbHeight, mipmapped: false)
        td.usage = .shaderRead
        td.storageMode = .shared
        // Metal reads the surface's own (possibly padded) bytesPerRow; zero-copy.
        guard let tex = device.makeTexture(descriptor: td, iosurface: surface, plane: 0) else {
            dbg("iosurface-texture-fail"); xsurface_close(conn); xconn = nil; return
        }
        iosTexture = tex
        usingIOSurface = true
        usingTestPattern = false
        testBuf?.deallocate(); testBuf = nil
        texture = nil                             // drop the test-pattern texture (~14 MB)
        needsPresent = true                       // present the initial frame
        displayLink?.preferredFramesPerSecond = 60
        connectInput()
        writeStatus()
    }

    // MARK: Metal setup

    private func dbg(_ s: String) {
        try? s.write(toFile: "/var/jb/tmp/xios-metal.txt", atomically: true, encoding: .utf8)
    }

    private func setupMetal() -> Bool {
        dbg("start")
        guard let dev = MTLCreateSystemDefaultDevice() else { dbg("no-device"); return false }
        guard let q = dev.makeCommandQueue() else { dbg("no-queue"); return false }
        device = dev; queue = q
        metalLayer.device = dev
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.contentsScale = UIScreen.main.scale   // render at native (retina) px
        guard let lib = dev.makeDefaultLibrary() else { dbg("no-library"); return false }
        guard let vfn = lib.makeFunction(name: "v_main"),
              let ffn = lib.makeFunction(name: "f_main") else { dbg("no-functions"); return false }
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = vfn
        pd.fragmentFunction = ffn
        pd.colorAttachments[0].pixelFormat = .bgra8Unorm
        do { pipeline = try dev.makeRenderPipelineState(descriptor: pd); dbg("ok"); return true }
        catch { dbg("pipeline-error \(error)"); return false }
    }

    private func makeTexture() {
        let td = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: fbWidth, height: fbHeight, mipmapped: false)
        td.usage = .shaderRead
        texture = device.makeTexture(descriptor: td)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let s = metalLayer.contentsScale
        metalLayer.drawableSize = CGSize(width: bounds.width * s, height: bounds.height * s)
        panOffset = clampedPanOffset(panOffset, zoom: zoomScale)
        needsPresent = true
        updateZoomButton()
        dumpGeom()
    }

    /// One-line geometry snapshot for diagnosing display sizing (letterboxing).
    /// orient rawValue: 1=portrait 2=portraitUpsideDown 3=landscapeRight 4=landscapeLeft.
    private func dumpGeom() {
        let ds = metalLayer.drawableSize
        let nb = UIScreen.main.nativeBounds
        let orient = window?.windowScene?.interfaceOrientation.rawValue ?? -1
        let txt = "bounds=\(Int(bounds.width))x\(Int(bounds.height)) "
            + "drawable=\(Int(ds.width))x\(Int(ds.height)) "
            + "scale=\(metalLayer.contentsScale) "
            + "fb=\(fbWidth)x\(fbHeight) "
            + "native=\(Int(nb.width))x\(Int(nb.height)) "
            + "orient=\(orient) ios=\(usingIOSurface)\n"
        try? txt.write(toFile: "/var/jb/tmp/xios-geom.txt", atomically: true, encoding: .utf8)
    }

    // MARK: framebuffer

    @discardableResult
    private func loadConfig() -> Bool {
        guard let data = FileManager.default.contents(atPath: configPath),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }

        let oldWidth = fbWidth
        let oldHeight = fbHeight
        let oldOffset = fbHeaderOffset
        let oldDisplay = xDisplay
        let oldAuth = xAuthPath
        let oldIsIOSurface = ddxIsIOSurface
        let oldSocket = ddxSockPath
        let oldIoscSock = ioscInputSock
        let oldIoscClipSock = ioscClipboardSock

        resetConfigDefaults(resetDisplay: true)
        if let w = obj["width"] as? Int, w > 0 { fbWidth = w }
        if let h = obj["height"] as? Int, h > 0 { fbHeight = h }
        if let o = obj["offset"] as? Int, o >= 0 { fbHeaderOffset = o }
        // Presence of "ddx":"iosurface" selects the zero-copy IOSurface path.
        ddxIsIOSurface = (obj["ddx"] as? String) == "iosurface"
        if let s = obj["socket"] as? String, !s.isEmpty { ddxSockPath = s }
        // Honor the display the server actually started on (set via $DISP), instead
        // of pinning XTEST input to :3.
        if let d = obj["display"] as? String, !d.isEmpty { xDisplay = d }
        // Cookie file locking the display (server uses xauth instead of -ac).
        if let a = obj["xauth"] as? String, !a.isEmpty { xAuthPath = a }
        // iosc advertises a Wayland input socket; route touch+keyboard there instead of
        // XTEST. Prefer an explicit "input_socket" field; otherwise infer it from an
        // iosc ddx socket (the compositor's rendezvous is /var/jb/tmp/iosc-ddx.sock).
        if ddxIsIOSurface {
            if let s = obj["input_socket"] as? String, !s.isEmpty {
                ioscInputSock = s
            } else if ddxSockPath.contains("iosc") {
                ioscInputSock = "/var/jb/tmp/iosc-input.sock"
            }
            if let s = obj["clipboard_socket"] as? String, !s.isEmpty {
                ioscClipboardSock = s
            } else if ddxSockPath.contains("iosc") {
                ioscClipboardSock = "/var/jb/tmp/iosc-clipboard.sock"
            }
        }

        let renderStateChanged = oldWidth != fbWidth || oldHeight != fbHeight ||
            oldOffset != fbHeaderOffset || oldIsIOSurface != ddxIsIOSurface ||
            oldSocket != ddxSockPath
        let inputStateChanged = oldDisplay != xDisplay || oldAuth != xAuthPath ||
            oldIoscSock != ioscInputSock || oldIoscClipSock != ioscClipboardSock
        if renderStateChanged || inputStateChanged {
            loadGeneration += 1
            iosConnectStarted = false
        }
        if inputStateChanged {
            closeInput()
        }
        return true
    }

    private func mapFramebuffer() -> Bool {
        let fd = open(fbPath, O_RDONLY)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var st = stat()
        let pixels = fbWidth * fbHeight * 4
        guard fstat(fd, &st) == 0, st.st_size >= off_t(pixels) else { return false }
        let len = Int(st.st_size)
        if fbHeaderOffset == 0 { fbHeaderOffset = len - pixels }   // XWD header + colormap
        // validate offset is within bounds (defensive)
        guard fbHeaderOffset >= 0, fbHeaderOffset + pixels <= len else { return false }
        let p = mmap(nil, len, PROT_READ, MAP_SHARED, fd, 0)
        guard p != MAP_FAILED else { return false }
        mapped = p; mappedLen = len
        return true
    }

    private func teardownIOSurface() {
        if let c = xconn { xsurface_close(c); xconn = nil }
        iosTexture = nil
        usingIOSurface = false
        if !userPinned { _ = loadConfig() }
        writeStatus()
        iosConnectStarted = false
        if ddxIsIOSurface {
            startIOSurfaceConnect()   // last frame stays frozen until the server returns
        } else if mapFramebuffer() {
            makeTexture()
            connectInput()
            displayLink?.preferredFramesPerSecond = 60
        } else {
            startTestPattern()
        }
    }

    @objc private func tick() {
        tickCount += 1
        serviceIoscClipboard()
        serviceIoscInputTraits()
        if inputConnected && !(usingIosc ? iosc_input_is_open() : xinput_is_open()) {
            inputConnected = false
            writeStatus()
        }
        if !inputConnected && tickCount % 30 == 0 {
            connectInput()
            if inputConnected { writeStatus() }
        }

        // Zero-copy IOSurface path: re-present only when the server signals a change
        // (or once for the initial frame, via needsPresent).
        if usingIOSurface {
            guard let conn = xconn, let tex = iosTexture else { return }
            let r = xsurface_drain(conn)
            if r < 0 { teardownIOSurface(); return }
            if r > 0 { needsPresent = true }
            if needsPresent, render(tex) { needsPresent = false }
            return
        }

        // Poll for a backend (handles the app launching before the X server, in
        // either IOSurface or Xvfb-file mode). Reached only when not yet on IOSurface.
        if mapped == nil && tickCount % 30 == 0 {
            if !userPinned { _ = loadConfig() }   // auto mode picks up xios.json; a manual
                                              // pick keeps its own display/backend choice
            if usingTestPattern, texture?.width != fbWidth || texture?.height != fbHeight {
                startTestPattern()
            }
            if ddxIsIOSurface {
                startIOSurfaceConnect()
            } else if mapFramebuffer() {
                usingTestPattern = false; makeTexture(); connectInput(); writeStatus()
                displayLink?.preferredFramesPerSecond = 60
            }
        }
        guard let texture = texture else { return }

        let base: UnsafeRawPointer
        if let m = mapped {
            base = UnsafeRawPointer(m).advanced(by: fbHeaderOffset)
        } else if let b = testBuf {
            renderTestPattern(into: b)
            base = UnsafeRawPointer(b)
        } else { return }

        texture.replace(region: MTLRegionMake2D(0, 0, fbWidth, fbHeight),
                        mipmapLevel: 0, withBytes: base, bytesPerRow: fbWidth * 4)
        _ = render(texture)
    }

    /// Draw the texture using the current fit/zoom/pan transform.
    @discardableResult
    private func render(_ tex: MTLTexture) -> Bool {
        guard let drawable = metalLayer.nextDrawable(),
              let cmd = queue.makeCommandBuffer() else { return false }
        let dw = Float(metalLayer.drawableSize.width), dh = Float(metalLayer.drawableSize.height)
        guard dw > 0, dh > 0 else { return false }
        let s = Float(metalLayer.contentsScale)
        let scale = min(dw / Float(fbWidth), dh / Float(fbHeight)) * Float(zoomScale)
        let sx = Float(fbWidth) * scale / dw
        let sy = Float(fbHeight) * scale / dh
        let cx = 2 * Float(panOffset.x) * s / dw
        let cy = -2 * Float(panOffset.y) * s / dh
        // triangle strip: TL, BL, TR, BR  (pos.xy, uv.xy); uv origin top-left
        var verts: [Float] = [
            cx - sx, cy + sy, 0, 0,
            cx - sx, cy - sy, 0, 1,
            cx + sx, cy + sy, 1, 0,
            cx + sx, cy - sy, 1, 1,
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

    private func writeStatus() {
        let fb: String
        if usingIOSurface {
            fb = "iosurface-zerocopy \(fbWidth)x\(fbHeight) [metal]"
        } else if mapped != nil {
            fb = "framebuffer-mapped \(fbWidth)x\(fbHeight) off=\(fbHeaderOffset) [metal]"
        } else {
            fb = "test-pattern (no framebuffer at \(fbPath)) [metal]"
        }
        let inp = !inputConnected ? "input-not-connected"
            : (usingIosc ? "input-connected iosc(wayland)" : "input-connected \(xDisplay)")
        try? "\(fb)\n\(inp)\n".write(toFile: "/var/jb/tmp/xios-status.txt", atomically: true, encoding: .utf8)
        updateChip()
    }

    private var displayProfiles: [DisplayProfile] {
        let nb = UIScreen.main.nativeBounds
        let nativeW = max(Int(nb.width), Int(nb.height))
        let nativeH = min(Int(nb.width), Int(nb.height))
        return [
            DisplayProfile(name: "Performance", width: 1024, height: 768, dpi: 96,
                           detail: "1024x768 @ 96 DPI"),
            DisplayProfile(name: "Balanced", width: 1366, height: 1024, dpi: 132,
                           detail: "1366x1024 @ 132 DPI"),
            DisplayProfile(name: "Native", width: nativeW, height: nativeH, dpi: 264,
                           detail: "\(nativeW)x\(nativeH) @ 264 DPI"),
            DisplayProfile(name: "Retina Text", width: nativeW, height: nativeH, dpi: 220,
                           detail: "\(nativeW)x\(nativeH) @ 220 DPI"),
            DisplayProfile(name: "Current", width: fbWidth, height: fbHeight, dpi: 0,
                           detail: "\(fbWidth)x\(fbHeight), keep DPI"),
        ]
    }

    private func writeDisplayRequest(_ profile: DisplayProfile) {
        var obj: [String: Any] = [
            "action": "display-profile",
            "profile": profile.name,
            "width": profile.width,
            "height": profile.height,
            "display": xDisplay,
            "backend": ddxIsIOSurface ? "iosurface" : "xvfb",
            "created_by": "Xios.app",
            "created_at": ISO8601DateFormatter().string(from: Date()),
        ]
        if profile.dpi > 0 { obj["dpi"] = profile.dpi }
        do {
            let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: requestPath), options: .atomic)
            lastToolMessage = "Wrote \(profile.detail)"
        } catch {
            lastToolMessage = "Request failed: \(error.localizedDescription)"
        }
        writeDebugSnapshot()
    }

    private func reloadRuntimeConfig() {
        _ = loadConfig()
        if ddxIsIOSurface, !usingIOSurface { startIOSurfaceConnect() }
        if !ddxIsIOSurface, mapped == nil, mapFramebuffer() {
            usingTestPattern = false
            makeTexture()
        }
        connectInput()
        needsPresent = true
        writeStatus()
    }

    /// Tear down whichever input backend is connected (XTEST or iosc).
    private func closeInput() {
        xinput_close()
        iosc_input_close()
        iosc_clipboard_close()
        inputConnected = false
    }

    private func reconnectInput() {
        closeInput()
        connectInput()
        writeStatus()
    }

    private func inputBackendName() -> String {
        usingIosc ? "iosc" : "XTEST"
    }

    private func debugSnapshot() -> String {
        let ds = metalLayer.drawableSize
        let nb = UIScreen.main.nativeBounds
        let cfg = (try? String(contentsOfFile: configPath, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "(missing)"
        let req = (try? String(contentsOfFile: requestPath, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "(missing)"
        return [
            "Xios Debug",
            "display=\(xDisplay)",
            "backend=\(usingIOSurface ? "iosurface" : (mapped != nil ? "xvfb-file" : "test-pattern"))",
            "ddx_iosurface=\(ddxIsIOSurface)",
            "fb=\(fbWidth)x\(fbHeight) offset=\(fbHeaderOffset)",
            "view=\(Int(bounds.width))x\(Int(bounds.height)) drawable=\(Int(ds.width))x\(Int(ds.height)) scale=\(metalLayer.contentsScale)",
            "native=\(Int(nb.width))x\(Int(nb.height)) zoom=\(Int((zoomScale * 100).rounded())) pan=\(Int(panOffset.x)),\(Int(panOffset.y))",
            "input=\(inputConnected ? "connected" : "not-connected") backend=\(inputBackendName())",
            "xauth=\(xAuthPath ?? "(none)")",
            "ddx_socket=\(ddxSockPath)",
            "iosc_input=\(ioscInputSock ?? "(none)")",
            "iosc_clipboard=\(ioscClipboardSock ?? "(none)")",
            "mapped_len=\(mappedLen) test_pattern=\(usingTestPattern)",
            "last_message=\(lastToolMessage)",
            "xios_json=\(cfg)",
            "xios_request=\(req)",
        ].joined(separator: "\n") + "\n"
    }

    private func writeDebugSnapshot() {
        try? debugSnapshot().write(toFile: debugPath, atomically: true, encoding: .utf8)
    }

    private func copyDebugSnapshot() {
        let text = debugSnapshot()
        UIPasteboard.general.string = text
        try? text.write(toFile: debugPath, atomically: true, encoding: .utf8)
        lastToolMessage = "Copied debug"
    }

    // MARK: input (XTEST)

    private func connectInput() {
        if let sock = ioscInputSock {
            // Wayland (iosc): one persistent Unix socket, no display/auth handshake.
            if inputConnected && iosc_input_is_open() { return }
            inputConnected = iosc_input_open(sock)
            return
        }
        if inputConnected && xinput_is_open() { return }
        if inputConnected { inputConnected = false }
        // Authenticate the XTEST connection with the per-display cookie the server
        // wrote (it locks the display with xauth instead of -ac). Harmless if absent.
        if let a = xAuthPath { setenv("XAUTHORITY", a, 1) }
        inputConnected = xinput_open(xDisplay)
    }

    private func serviceIoscInputTraits() {
        guard usingIosc, inputConnected, iosc_input_is_open() else {
            applyIoscInputTraits(hint: 0, purpose: 0, enabled: 0)
            return
        }
        var hint: UInt32 = 0, purpose: UInt32 = 0, enabled: UInt32 = 0
        let r = iosc_input_poll_traits(&hint, &purpose, &enabled)
        if r < 0 {
            inputConnected = false
            writeStatus()
        } else if r > 0 {
            applyIoscInputTraits(hint: hint, purpose: purpose, enabled: enabled)
        }
    }

    private func applyIoscInputTraits(hint: UInt32, purpose: UInt32, enabled: UInt32) {
        guard hint != lastIoscTraitHint || purpose != lastIoscTraitPurpose ||
              enabled != lastIoscTraitEnabled else { return }
        lastIoscTraitHint = hint
        lastIoscTraitPurpose = purpose
        lastIoscTraitEnabled = enabled

        if enabled == 0 {
            isSecureTextEntry = false
            keyboardType = .default
            returnKeyType = .default
            autocorrectionType = .no
            spellCheckingType = .no
            autocapitalizationType = .none
            if isFirstResponder { reloadInputViews() }
            return
        }

        let completion = (hint & 0x1) != 0
        let spellcheck = (hint & 0x2) != 0
        let autoCaps = (hint & 0x4) != 0
        let uppercase = (hint & 0x10) != 0
        let titlecase = (hint & 0x20) != 0
        let hidden = (hint & 0x40) != 0
        let sensitive = (hint & 0x80) != 0
        let multiline = (hint & 0x200) != 0
        let secure = enabled != 0 && (hidden || sensitive || purpose == 8 || purpose == 9)

        isSecureTextEntry = secure
        keyboardType = .default
        returnKeyType = multiline ? .default : .done
        autocorrectionType = (!secure && completion) ? .yes : .no
        spellCheckingType = (!secure && spellcheck) ? .yes : .no
        autocapitalizationType = .none

        switch purpose {
        case 2, 9:
            keyboardType = .numberPad
        case 3:
            keyboardType = .numbersAndPunctuation
        case 4:
            keyboardType = .phonePad
        case 5:
            keyboardType = .URL
            returnKeyType = .go
        case 6:
            keyboardType = .emailAddress
        case 8:
            keyboardType = .asciiCapable
        case 13:
            keyboardType = .asciiCapable
            returnKeyType = .default
            autocorrectionType = .no
            spellCheckingType = .no
        default:
            break
        }

        if uppercase {
            autocapitalizationType = .allCharacters
        } else if titlecase {
            autocapitalizationType = .words
        } else if autoCaps {
            autocapitalizationType = .sentences
        }

        if isFirstResponder { reloadInputViews() }
    }

    private func serviceIoscClipboard() {
        guard usingIosc, let sock = ioscClipboardSock else {
            if iosc_clipboard_is_open() { iosc_clipboard_close() }
            return
        }
        if !iosc_clipboard_is_open() {
            guard iosc_clipboard_open(sock) else { return }
            pasteboardChangeCount = UIPasteboard.general.changeCount
            let text = UIPasteboard.general.string ?? ""
            lastSentPasteboard = text
            _ = text.withCString { iosc_clipboard_set_text($0) }
        }

        var buf = [CChar](repeating: 0, count: 1024 * 1024 + 1)
        var n: Int32 = 0
        while buf.withUnsafeMutableBufferPointer({ p in
            iosc_clipboard_poll(p.baseAddress, Int32(p.count), &n)
        }) {
            let text = String(cString: buf)
            UIPasteboard.general.string = text.isEmpty ? nil : text
            pasteboardChangeCount = UIPasteboard.general.changeCount
            lastSentPasteboard = text
        }

        let pb = UIPasteboard.general
        guard pb.changeCount != pasteboardChangeCount else { return }
        pasteboardChangeCount = pb.changeCount
        let text = pb.string ?? ""
        if text == lastSentPasteboard { return }
        lastSentPasteboard = text
        _ = text.withCString { iosc_clipboard_set_text($0) }
    }

    // Route one pointer/key event to the active backend: iosc (Wayland) or XTEST.
    private func sendMotion(_ x: Int32, _ y: Int32) {
        if usingIosc { iosc_input_motion(x, y) } else { xinput_motion(x, y) }
    }
    private func sendButton(_ button: Int32, _ down: Bool, at p: (Int32, Int32)?) {
        if usingIosc {
            let q = p ?? lastTouchPt ?? (Int32(0), Int32(0))
            iosc_input_button(button, down, q.0, q.1)
        } else {
            xinput_button(button, down)
        }
    }
    private func sendKeysym(_ ks: UInt, ctrl: Bool, alt: Bool, shift: Bool) {
        if usingIosc {
            var mods: UInt32 = 0
            if shift { mods |= 1 }; if ctrl { mods |= 2 }; if alt { mods |= 4 }
            iosc_input_key(UInt32(ks), mods)   // iosc resolves the keysym + auto-Shift
        } else {
            _ = xinput_type_keysym_mods(ks, ctrl, alt, shift, false)
        }
    }

    private func sendText(_ text: String) {
        guard inputConnected else { return }
        if usingIosc {
            _ = text.withCString { iosc_input_text($0) }
            return
        }
        for ch in text {
            if let ks = keysym(for: ch) {
                sendKeysym(ks, ctrl: false, alt: false, shift: false)
            }
        }
    }

    private func sendClick(_ button: Int32) {
        guard inputConnected else { return }
        let p = lastTouchPt ?? (Int32(fbWidth / 2), Int32(fbHeight / 2))
        sendMotion(p.0, p.1)
        sendButton(button, true, at: p)
        sendButton(button, false, at: p)
    }

    private func sendWheel(_ button: Int32) {
        guard inputConnected, !usingIosc else { return }
        xinput_button(button, true)
        xinput_button(button, false)
    }

    private func fittedScale(in size: CGSize) -> CGFloat {
        guard fbWidth > 0, fbHeight > 0, size.width > 0, size.height > 0 else { return 1 }
        return min(size.width / CGFloat(fbWidth), size.height / CGFloat(fbHeight))
    }

    private func contentRect(zoom: CGFloat? = nil, pan: CGPoint? = nil) -> CGRect {
        let z = zoom ?? zoomScale
        let p = pan ?? panOffset
        let scale = fittedScale(in: bounds.size) * z
        let size = CGSize(width: CGFloat(fbWidth) * scale, height: CGFloat(fbHeight) * scale)
        let origin = CGPoint(
            x: bounds.midX - size.width / 2 + p.x,
            y: bounds.midY - size.height / 2 + p.y)
        return CGRect(origin: origin, size: size)
    }

    private func clampedPanOffset(_ p: CGPoint, zoom: CGFloat) -> CGPoint {
        guard bounds.width > 0, bounds.height > 0 else { return .zero }
        let rect = contentRect(zoom: zoom, pan: .zero)
        let maxX = max(0, (rect.width - bounds.width) / 2)
        let maxY = max(0, (rect.height - bounds.height) / 2)
        return CGPoint(
            x: min(max(p.x, -maxX), maxX),
            y: min(max(p.y, -maxY), maxY))
    }

    private func framebufferFloatPoint(from p: CGPoint) -> CGPoint? {
        guard fbWidth > 0, fbHeight > 0, bounds.width > 0, bounds.height > 0 else { return nil }
        let rect = contentRect()
        guard rect.contains(p) else { return nil }
        let fx = (p.x - rect.minX) / rect.width * CGFloat(fbWidth)
        let fy = (p.y - rect.minY) / rect.height * CGFloat(fbHeight)
        return CGPoint(
            x: max(0, min(CGFloat(fbWidth - 1), fx)),
            y: max(0, min(CGFloat(fbHeight - 1), fy)))
    }

    private func framebufferPoint(from p: CGPoint) -> (Int32, Int32)? {
        guard let fp = framebufferFloatPoint(from: p) else { return nil }
        return (Int32(fp.x), Int32(fp.y))
    }

    private func setZoom(_ z: CGFloat, around screenPoint: CGPoint? = nil) {
        let oldRect = contentRect()
        let anchor = screenPoint ?? CGPoint(x: bounds.midX, y: bounds.midY)
        let ux = oldRect.width > 0 ? (anchor.x - oldRect.minX) / oldRect.width : 0.5
        let uy = oldRect.height > 0 ? (anchor.y - oldRect.minY) / oldRect.height : 0.5
        let nextZoom = min(max(z, minZoomScale), maxZoomScale)
        let baseScale = fittedScale(in: bounds.size) * nextZoom
        let nextSize = CGSize(width: CGFloat(fbWidth) * baseScale, height: CGFloat(fbHeight) * baseScale)
        let nextPan = CGPoint(
            x: anchor.x - bounds.midX + nextSize.width * (0.5 - ux),
            y: anchor.y - bounds.midY + nextSize.height * (0.5 - uy))
        zoomScale = nextZoom
        panOffset = clampedPanOffset(nextPan, zoom: nextZoom)
        needsPresent = true
        updateZoomButton()
    }

    private func resetZoom() {
        zoomScale = minZoomScale
        panOffset = .zero
        scrollRemainder = .zero
        needsPresent = true
        updateZoomButton()
    }

    private func pixelPerfectZoom() -> CGFloat {
        let fit = fittedScale(in: bounds.size)
        guard fit > 0, metalLayer.contentsScale > 0 else { return 1 }
        return min(max(1 / (fit * metalLayer.contentsScale), minZoomScale), maxZoomScale)
    }

    private func sendScroll(dx: CGFloat, dy: CGFloat) {
        guard inputConnected else { return }
        if usingIosc { return }   // iosc input protocol currently has pointer/key only.
        scrollRemainder.x -= dx
        scrollRemainder.y -= dy
        let step: CGFloat = 36
        while scrollRemainder.y <= -step {
            xinput_button(4, true); xinput_button(4, false)
            scrollRemainder.y += step
        }
        while scrollRemainder.y >= step {
            xinput_button(5, true); xinput_button(5, false)
            scrollRemainder.y -= step
        }
        while scrollRemainder.x <= -step {
            xinput_button(6, true); xinput_button(6, false)
            scrollRemainder.x += step
        }
        while scrollRemainder.x >= step {
            xinput_button(7, true); xinput_button(7, false)
            scrollRemainder.x -= step
        }
    }

    @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
        switch g.state {
        case .began:
            pinchStartZoom = zoomScale
            pinchAnchorFramebuffer = framebufferFloatPoint(from: g.location(in: self))
        case .changed:
            let location = g.location(in: self)
            setZoom(pinchStartZoom * g.scale, around: location)
            if let fp = pinchAnchorFramebuffer {
                let rect = contentRect()
                panOffset.x = location.x - bounds.midX + rect.width * (0.5 - fp.x / CGFloat(fbWidth))
                panOffset.y = location.y - bounds.midY + rect.height * (0.5 - fp.y / CGFloat(fbHeight))
                panOffset = clampedPanOffset(panOffset, zoom: zoomScale)
                needsPresent = true
            }
        case .ended, .cancelled, .failed:
            pinchAnchorFramebuffer = nil
        default:
            break
        }
    }

    @objc private func handleTwoFingerPan(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began:
            panStartOffset = panOffset
            panLastTranslation = .zero
            scrollRemainder = .zero
        case .changed:
            let t = g.translation(in: self)
            if zoomScale > 1.01 {
                panOffset = clampedPanOffset(
                    CGPoint(x: panStartOffset.x + t.x, y: panStartOffset.y + t.y),
                    zoom: zoomScale)
                needsPresent = true
            } else {
                sendScroll(dx: t.x - panLastTranslation.x, dy: t.y - panLastTranslation.y)
            }
            panLastTranslation = t
        default:
            panLastTranslation = .zero
            scrollRemainder = .zero
        }
    }

    @objc private func handleTwoFingerTap(_ g: UITapGestureRecognizer) {
        guard inputConnected, let (x, y) = framebufferPoint(from: g.location(in: self)) else { return }
        lastTouchPt = (x, y)
        sendMotion(x, y)
        sendButton(3, true, at: (x, y))
        sendButton(3, false, at: (x, y))
    }

    @objc private func handleTwoFingerDoubleTap(_ g: UITapGestureRecognizer) {
        if zoomScale > 1.01 { resetZoom() }
        else { setZoom(pixelPerfectZoom(), around: g.location(in: self)) }
    }

    @objc private func zoomOut() {
        if zoomScale <= 1.01 { resetZoom() }
        else { setZoom(zoomScale / 1.25) }
    }

    @objc private func zoomIn() {
        setZoom(zoomScale * 1.25)
    }

    @objc private func cycleZoom() {
        if zoomScale <= 1.01 {
            let z = pixelPerfectZoom()
            setZoom(z > 1.01 ? z : 2)
        } else {
            resetZoom()
        }
    }

    private func updateZoomButton() {
        zoomButton?.setTitle("\(Int((zoomScale * 100).rounded()))%", for: .normal)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard (event?.allTouches?.count ?? touches.count) == 1,
              inputConnected, let t = touches.first,
              let (x, y) = framebufferPoint(from: t.location(in: self)) else { return }
        lastTouchPt = (x, y)
        sendMotion(x, y); sendButton(1, true, at: (x, y))
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard (event?.allTouches?.count ?? touches.count) == 1,
              inputConnected, let t = touches.first,
              let (x, y) = framebufferPoint(from: t.location(in: self)) else { return }
        lastTouchPt = (x, y)
        sendMotion(x, y)
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if inputConnected { sendButton(1, false, at: lastTouchPt) }
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        if inputConnected { sendButton(1, false, at: lastTouchPt) }
    }

    // MARK: display discovery + picker

    /// One open X display. `config` is non-nil only when xios.json describes it (so it
    /// can render a framebuffer); the rest are input-only.
    private struct XDisplayInfo {
        let number: Int
        let config: [String: Any]?
        var displayStr: String { ":\(number)" }
        var renderable: Bool { config != nil }
    }

    private func readConfig() -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: configPath),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    /// Every open display = an `X<n>` socket under either `.X11-unix` dir, unioned
    /// with the display xios.json advertises (the one we can actually render).
    private func discoverDisplays() -> [XDisplayInfo] {
        var numbers = Set<Int>()
        let fm = FileManager.default
        for dir in xunixDirs {
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for e in entries where e.hasPrefix("X") {
                if let n = Int(e.dropFirst()) { numbers.insert(n) }
            }
        }
        let cfg = readConfig()
        var cfgNumber: Int?
        if let d = cfg?["display"] as? String, d.hasPrefix(":"), let n = Int(d.dropFirst()) {
            cfgNumber = n
            numbers.insert(n)   // include the configured display even if its socket dir wasn't scanned
        }
        return numbers.sorted().map { XDisplayInfo(number: $0, config: $0 == cfgNumber ? cfg : nil) }
    }

    private func resetConfigDefaults(resetDisplay: Bool = false) {
        fbWidth = 1024; fbHeight = 768; fbHeaderOffset = 0
        ddxIsIOSurface = false
        ddxSockPath = "/var/jb/tmp/xios-ddx.sock"
        xAuthPath = nil
        ioscInputSock = nil
        ioscClipboardSock = nil
        if resetDisplay { xDisplay = ":3" }
    }

    /// Drop every connection tied to the current display so we can load another.
    private func teardownConnections() {
        closeInput()
        if let c = xconn { xsurface_close(c); xconn = nil }
        iosTexture = nil; usingIOSurface = false; iosConnectStarted = false; needsPresent = false
        if let m = mapped { munmap(m, mappedLen); mapped = nil; mappedLen = 0 }
        testBuf?.deallocate(); testBuf = nil
        usingTestPattern = false
        resetZoom()
    }

    /// Switch to a display the user picked: tear down the old one, apply the new
    /// config (or none, for input-only), and start its framebuffer + input path.
    private func load(_ disp: XDisplayInfo) {
        userPinned = true
        teardownConnections()
        loadGeneration += 1
        resetConfigDefaults()
        xDisplay = disp.displayStr

        if disp.renderable {
            _ = loadConfig()             // re-read the configured display's xios.json
            xDisplay = disp.displayStr   // keep the picked display (config should match)
            if ddxIsIOSurface {
                startTestPattern()
                startIOSurfaceConnect()
            } else if mapFramebuffer() {
                usingTestPattern = false
                makeTexture()
                displayLink?.preferredFramesPerSecond = 60
            } else {
                startTestPattern()
            }
        } else {
            startTestPattern()           // input-only: no framebuffer for this display
        }
        connectInput()
        writeStatus()
        updateChip()
    }

    // MARK: picker chrome

    private func installChrome() {
        let chip = chromeButton("⊞ \(xDisplay)")
        chip.addAction(UIAction { [weak self] _ in self?.openPicker() }, for: .touchUpInside)
        displayChip = chip

        let kb = chromeButton("⌨")   // pops up the iOS keyboard, typed into X via XTEST
        kb.addAction(UIAction { [weak self] _ in self?.toggleKeyboard() }, for: .touchUpInside)
        keyboardButton = kb

        let tools = chromeButton("⚙")
        tools.addAction(UIAction { [weak self] _ in self?.openTools() }, for: .touchUpInside)
        toolsButton = tools

        let zoomOut = chromeButton("−")
        zoomOut.addAction(UIAction { [weak self] _ in self?.zoomOut() }, for: .touchUpInside)
        let zoom = chromeButton("100%")
        zoom.addAction(UIAction { [weak self] _ in self?.cycleZoom() }, for: .touchUpInside)
        zoomButton = zoom
        let zoomIn = chromeButton("+")
        zoomIn.addAction(UIAction { [weak self] _ in self?.zoomIn() }, for: .touchUpInside)

        let bar = UIStackView(arrangedSubviews: [chip, zoomOut, zoom, zoomIn, kb, tools])
        bar.axis = .horizontal
        bar.spacing = 8
        bar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 12),
            bar.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 10),
        ])
        updateChip()

        // Only single-finger touches are forwarded to X, so a 3-finger tap is a free
        // gesture for opening the picker anywhere on screen.
        let g = UITapGestureRecognizer(target: self, action: #selector(openPicker))
        g.numberOfTouchesRequired = 3
        addGestureRecognizer(g)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self
        addGestureRecognizer(pinch)

        let twoFingerPan = UIPanGestureRecognizer(target: self, action: #selector(handleTwoFingerPan(_:)))
        twoFingerPan.minimumNumberOfTouches = 2
        twoFingerPan.maximumNumberOfTouches = 2
        twoFingerPan.delegate = self
        addGestureRecognizer(twoFingerPan)

        let twoFingerDoubleTap = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerDoubleTap(_:)))
        twoFingerDoubleTap.numberOfTouchesRequired = 2
        twoFingerDoubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(twoFingerDoubleTap)

        let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerTap(_:)))
        twoFingerTap.numberOfTouchesRequired = 2
        twoFingerTap.require(toFail: twoFingerDoubleTap)
        addGestureRecognizer(twoFingerTap)
    }

    private func chromeButton(_ title: String) -> UIButton {
        let b = UIButton(type: .system)
        b.translatesAutoresizingMaskIntoConstraints = false
        b.setTitle(title, for: .normal)
        b.titleLabel?.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        b.setTitleColor(.white, for: .normal)
        b.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        b.contentEdgeInsets = UIEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        b.layer.cornerRadius = 11
        b.layer.borderWidth = 1
        b.layer.borderColor = UIColor.white.withAlphaComponent(0.25).cgColor
        return b
    }

    private func updateChip() {
        displayChip?.setTitle("⊞ \(xDisplay)", for: .normal)
    }

    @objc private func openPicker() { presentPicker(discoverDisplays()) }

    /// Build the dimmed full-screen overlay with a tap-to-dismiss backdrop and an
    /// empty centered card. Shared by the display picker and tools sheets; sets
    /// `pickerOverlay` and returns both views to lay out.
    private func presentModalCard() -> (overlay: UIView, card: UIView) {
        dismissPicker()
        let overlay = UIView(frame: bounds)
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(overlay)
        pickerOverlay = overlay

        // Dimmed backdrop as a button: tapping outside the card dismisses; taps on the
        // card hit its own subviews (above this) so they don't dismiss.
        let backdrop = UIButton(type: .custom)
        backdrop.frame = overlay.bounds
        backdrop.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        backdrop.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        backdrop.addAction(UIAction { [weak self] _ in self?.dismissPicker() }, for: .touchUpInside)
        overlay.addSubview(backdrop)

        let card = UIView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.backgroundColor = UIColor(white: 0.12, alpha: 1)
        card.layer.cornerRadius = 16
        overlay.addSubview(card)
        return (overlay, card)
    }

    private func presentPicker(_ displays: [XDisplayInfo]) {
        let (overlay, card) = presentModalCard()

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        let title = UILabel()
        title.text = "X Displays"
        title.font = .boldSystemFont(ofSize: 18)
        title.textColor = .white
        stack.addArrangedSubview(title)

        if displays.isEmpty {
            let empty = UILabel()
            empty.text = "No open displays.\nStart a server (xios-server.sh / x11-server.sh)."
            empty.numberOfLines = 0
            empty.font = .systemFont(ofSize: 14)
            empty.textColor = UIColor(white: 0.7, alpha: 1)
            stack.addArrangedSubview(empty)
        } else {
            for d in displays { stack.addArrangedSubview(makeRow(d)) }
        }

        let controls = UIStackView()
        controls.axis = .horizontal; controls.spacing = 8; controls.distribution = .fillEqually
        controls.addArrangedSubview(pillButton("Rescan") { [weak self] in
            guard let self else { return }
            self.presentPicker(self.discoverDisplays())
        })
        controls.addArrangedSubview(pillButton("Close") { [weak self] in self?.dismissPicker() })
        stack.addArrangedSubview(controls)

        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
            card.widthAnchor.constraint(greaterThanOrEqualToConstant: 340),
            card.widthAnchor.constraint(lessThanOrEqualToConstant: 480),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 18),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -18),
        ])
    }

    private func makeRow(_ d: XDisplayInfo) -> UIButton {
        let active = d.number == activeDisplayNumber
        let b = UIButton(type: .system)
        b.contentHorizontalAlignment = .left
        b.titleLabel?.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
        b.setTitle(rowTitle(d, active: active), for: .normal)
        b.setTitleColor(.white, for: .normal)
        b.backgroundColor = active ? UIColor.systemBlue.withAlphaComponent(0.35)
                                   : UIColor(white: 0.2, alpha: 1)
        b.layer.cornerRadius = 10
        b.contentEdgeInsets = UIEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        b.addAction(UIAction { [weak self] _ in
            self?.dismissPicker()
            self?.load(d)
        }, for: .touchUpInside)
        return b
    }

    private func rowTitle(_ d: XDisplayInfo, active: Bool) -> String {
        let desc: String
        if let cfg = d.config {
            let w = (cfg["width"] as? Int) ?? 0
            let h = (cfg["height"] as? Int) ?? 0
            let backend = (cfg["ddx"] as? String) == "iosurface" ? "IOSurface" : "Xvfb"
            desc = "\(w)×\(h)  \(backend)"
        } else {
            desc = "input only (no framebuffer)"
        }
        return "\(active ? "● " : "   "):\(d.number)   \(desc)"
    }

    private func pillButton(_ title: String, _ action: @escaping () -> Void) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(title, for: .normal)
        b.setTitleColor(.white, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        b.backgroundColor = UIColor(white: 0.25, alpha: 1)
        b.layer.cornerRadius = 10
        b.contentEdgeInsets = UIEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        b.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return b
    }

    @objc private func dismissPicker() {
        pickerOverlay?.removeFromSuperview()
        pickerOverlay = nil
    }

    @objc private func openTools() {
        presentTools()
    }

    private func presentTools() {
        let (overlay, card) = presentModalCard()

        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(scroll)

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)

        let title = panelLabel("Tools", size: 18, weight: .bold)
        stack.addArrangedSubview(title)

        let message = panelLabel(lastToolMessage, size: 12, color: UIColor(white: 0.72, alpha: 1))
        stack.addArrangedSubview(message)

        addSection("Display Profiles", to: stack)
        for profile in displayProfiles {
            stack.addArrangedSubview(panelButton("\(profile.name)  \(profile.detail)") { [weak self, weak message] in
                self?.writeDisplayRequest(profile)
                message?.text = self?.lastToolMessage
            })
        }

        addSection("Debug", to: stack)
        let debugView = UITextView()
        debugView.translatesAutoresizingMaskIntoConstraints = false
        debugView.isEditable = false
        debugView.isScrollEnabled = true
        debugView.backgroundColor = UIColor(white: 0.08, alpha: 1)
        debugView.textColor = UIColor(white: 0.86, alpha: 1)
        debugView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        debugView.layer.cornerRadius = 8
        debugView.text = debugSnapshot()
        stack.addArrangedSubview(debugView)
        debugView.heightAnchor.constraint(equalToConstant: 180).isActive = true

        stack.addArrangedSubview(buttonRow([
            panelButton("Copy Debug") { [weak self, weak debugView, weak message] in
                self?.copyDebugSnapshot()
                debugView?.text = self?.debugSnapshot()
                message?.text = self?.lastToolMessage
            },
            panelButton("Write Debug") { [weak self, weak debugView, weak message] in
                self?.writeDebugSnapshot()
                self?.lastToolMessage = "Wrote xios-debug.txt"
                debugView?.text = self?.debugSnapshot()
                message?.text = self?.lastToolMessage
            },
        ]))
        stack.addArrangedSubview(buttonRow([
            panelButton("Reload Config") { [weak self, weak debugView] in
                self?.reloadRuntimeConfig()
                debugView?.text = self?.debugSnapshot()
            },
            panelButton("Reconnect Input") { [weak self, weak debugView] in
                self?.reconnectInput()
                debugView?.text = self?.debugSnapshot()
            },
        ]))

        addSection("Custom Input", to: stack)
        let textField = panelTextField("Text")
        stack.addArrangedSubview(textField)
        stack.addArrangedSubview(buttonRow([
            panelButton("Send Text") { [weak self, weak textField] in
                self?.sendText(textField?.text ?? "")
                textField?.text = ""
            },
            panelButton("Paste") { [weak self] in
                self?.sendText(UIPasteboard.general.string ?? "")
            },
        ]))

        var customCtrl = false
        var customAlt = false
        var customShift = false
        var ctrlButton: UIButton!
        var altButton: UIButton!
        var shiftButton: UIButton!
        ctrlButton = panelButton("Ctrl") { [weak self] in
            customCtrl.toggle()
            self?.stylePanelToggle(ctrlButton, on: customCtrl)
        }
        altButton = panelButton("Alt") { [weak self] in
            customAlt.toggle()
            self?.stylePanelToggle(altButton, on: customAlt)
        }
        shiftButton = panelButton("Shift") { [weak self] in
            customShift.toggle()
            self?.stylePanelToggle(shiftButton, on: customShift)
        }
        stack.addArrangedSubview(buttonRow([ctrlButton, altButton, shiftButton]))

        let keysymField = panelTextField("Keysym hex, e.g. ff1b")
        stack.addArrangedSubview(keysymField)
        stack.addArrangedSubview(panelButton("Send KeySym") { [weak self, weak keysymField] in
            let raw = (keysymField?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let cleaned = raw.lowercased().hasPrefix("0x") ? String(raw.dropFirst(2)) : raw
            if let value = UInt(cleaned, radix: 16) {
                self?.sendKeysym(value, ctrl: customCtrl, alt: customAlt, shift: customShift)
            }
        })

        stack.addArrangedSubview(buttonRow([
            keyButton("Esc", 0xff1b, ctrl: { customCtrl }, alt: { customAlt }, shift: { customShift }),
            keyButton("Tab", 0xff09, ctrl: { customCtrl }, alt: { customAlt }, shift: { customShift }),
            keyButton("Enter", 0xff0d, ctrl: { customCtrl }, alt: { customAlt }, shift: { customShift }),
            keyButton("Back", 0xff08, ctrl: { customCtrl }, alt: { customAlt }, shift: { customShift }),
        ]))
        stack.addArrangedSubview(buttonRow([
            keyButton("Left", 0xff51, ctrl: { customCtrl }, alt: { customAlt }, shift: { customShift }),
            keyButton("Up", 0xff52, ctrl: { customCtrl }, alt: { customAlt }, shift: { customShift }),
            keyButton("Down", 0xff54, ctrl: { customCtrl }, alt: { customAlt }, shift: { customShift }),
            keyButton("Right", 0xff53, ctrl: { customCtrl }, alt: { customAlt }, shift: { customShift }),
        ]))
        stack.addArrangedSubview(buttonRow([
            keyButton("Home", 0xff50, ctrl: { customCtrl }, alt: { customAlt }, shift: { customShift }),
            keyButton("End", 0xff57, ctrl: { customCtrl }, alt: { customAlt }, shift: { customShift }),
            keyButton("PgUp", 0xff55, ctrl: { customCtrl }, alt: { customAlt }, shift: { customShift }),
            keyButton("PgDn", 0xff56, ctrl: { customCtrl }, alt: { customAlt }, shift: { customShift }),
        ]))

        stack.addArrangedSubview(buttonRow([
            panelButton("Left Click") { [weak self] in self?.sendClick(1) },
            panelButton("Middle") { [weak self] in self?.sendClick(2) },
            panelButton("Right") { [weak self] in self?.sendClick(3) },
        ]))
        stack.addArrangedSubview(buttonRow([
            panelButton("Wheel Up") { [weak self] in self?.sendWheel(4) },
            panelButton("Wheel Down") { [weak self] in self?.sendWheel(5) },
            panelButton("Wheel Left") { [weak self] in self?.sendWheel(6) },
            panelButton("Wheel Right") { [weak self] in self?.sendWheel(7) },
        ]))

        stack.addArrangedSubview(panelButton("Close") { [weak self] in self?.dismissPicker() })

        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
            card.widthAnchor.constraint(greaterThanOrEqualToConstant: 420),
            card.widthAnchor.constraint(lessThanOrEqualToConstant: 560),
            card.heightAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.heightAnchor, multiplier: 0.86),
            card.heightAnchor.constraint(lessThanOrEqualTo: overlay.safeAreaLayoutGuide.heightAnchor, constant: -32),
            scroll.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
        ])
    }

    private func addSection(_ title: String, to stack: UIStackView) {
        let label = panelLabel(title, size: 14, weight: .semibold, color: UIColor(white: 0.9, alpha: 1))
        label.setContentHuggingPriority(.required, for: .vertical)
        stack.addArrangedSubview(label)
    }

    private func panelLabel(_ text: String, size: CGFloat, weight: UIFont.Weight = .regular,
                            color: UIColor = .white) -> UILabel {
        let label = UILabel()
        label.text = text
        label.textColor = color
        label.font = .systemFont(ofSize: size, weight: weight)
        label.numberOfLines = 0
        return label
    }

    private func panelTextField(_ placeholder: String) -> UITextField {
        let f = UITextField()
        f.borderStyle = .roundedRect
        f.placeholder = placeholder
        f.autocorrectionType = .no
        f.autocapitalizationType = .none
        f.spellCheckingType = .no
        f.clearButtonMode = .whileEditing
        f.font = .systemFont(ofSize: 15)
        return f
    }

    private func panelButton(_ title: String, _ action: @escaping () -> Void) -> UIButton {
        let b = pillButton(title, action)
        b.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        return b
    }

    private func buttonRow(_ buttons: [UIButton]) -> UIStackView {
        let row = UIStackView(arrangedSubviews: buttons)
        row.axis = .horizontal
        row.spacing = 8
        row.distribution = .fillEqually
        return row
    }

    private func stylePanelToggle(_ b: UIButton?, on: Bool) {
        b?.backgroundColor = on ? UIColor.systemBlue.withAlphaComponent(0.85) : UIColor(white: 0.25, alpha: 1)
    }

    private func keyButton(_ title: String, _ keysym: UInt,
                           ctrl: @escaping () -> Bool,
                           alt: @escaping () -> Bool,
                           shift: @escaping () -> Bool) -> UIButton {
        panelButton(title) { [weak self] in
            self?.sendKeysym(keysym, ctrl: ctrl(), alt: alt(), shift: shift())
        }
    }

    // MARK: keyboard (iOS keyboard -> XTEST)

    override var canBecomeFirstResponder: Bool { true }

    @objc private func toggleKeyboard() {
        if isFirstResponder { _ = resignFirstResponder() }
        else { _ = becomeFirstResponder() }
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { keyboardButton?.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.7) }
        return ok
    }
    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { keyboardButton?.backgroundColor = UIColor.black.withAlphaComponent(0.55) }
        return ok
    }

    /// Map one character to an X keysym. Latin-1 keysyms equal the codepoint for
    /// 0x20–0xff; Return/Tab are handled explicitly. nil for anything unmapped.
    fileprivate func keysym(for ch: Character) -> UInt? {
        if ch == "\n" || ch == "\r" { return 0xff0d }   // XK_Return
        if ch == "\t" { return 0xff09 }                 // XK_Tab
        let scalars = ch.unicodeScalars
        guard scalars.count == 1, let v = scalars.first?.value else { return nil }
        if (0x20...0x7e).contains(v) || (0xa0...0xff).contains(v) { return UInt(v) }
        return nil
    }

    /// Send a non-text key (Esc/Tab/arrows) with the armed sticky modifiers, then clear them.
    private func sendSpecial(_ ks: UInt) {
        guard inputConnected else { return }
        sendKeysym(ks, ctrl: modCtrl, alt: modAlt, shift: modShift)
        clearStickyMods()
    }

    private func clearStickyMods() {
        guard modCtrl || modAlt || modShift else { return }
        modCtrl = false; modAlt = false; modShift = false
        styleSticky(ctrlBtn, on: false)
        styleSticky(altBtn, on: false)
        styleSticky(shiftBtn, on: false)
    }

    private func styleSticky(_ b: UIButton?, on: Bool) {
        b?.backgroundColor = on ? .systemBlue : UIColor(white: 0.28, alpha: 1)
    }

    // The modifier row sits above the keyboard whenever the X view is first responder.
    override var inputAccessoryView: UIView? {
        if modRow == nil { modRow = buildModRow() }
        return modRow
    }

    private func buildModRow() -> UIView {
        let bar = UIInputView(frame: CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: 48),
                              inputViewStyle: .keyboard)
        bar.autoresizingMask = .flexibleWidth

        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bar.safeAreaLayoutGuide.leadingAnchor, constant: 8),
            stack.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])

        stack.addArrangedSubview(keycap("esc") { [weak self] in self?.sendSpecial(0xff1b) })
        stack.addArrangedSubview(keycap("tab") { [weak self] in self?.sendSpecial(0xff09) })

        let ctrl = keycap("ctrl") { [weak self] in
            guard let self else { return }
            self.modCtrl.toggle(); self.styleSticky(self.ctrlBtn, on: self.modCtrl)
        }
        let alt = keycap("alt") { [weak self] in
            guard let self else { return }
            self.modAlt.toggle(); self.styleSticky(self.altBtn, on: self.modAlt)
        }
        let shift = keycap("shift") { [weak self] in
            guard let self else { return }
            self.modShift.toggle(); self.styleSticky(self.shiftBtn, on: self.modShift)
        }
        ctrlBtn = ctrl; altBtn = alt; shiftBtn = shift
        [ctrl, alt, shift].forEach { stack.addArrangedSubview($0) }

        stack.addArrangedSubview(keycap("←") { [weak self] in self?.sendSpecial(0xff51) })
        stack.addArrangedSubview(keycap("↑") { [weak self] in self?.sendSpecial(0xff52) })
        stack.addArrangedSubview(keycap("↓") { [weak self] in self?.sendSpecial(0xff54) })
        stack.addArrangedSubview(keycap("→") { [weak self] in self?.sendSpecial(0xff53) })
        return bar
    }

    private func keycap(_ title: String, _ action: @escaping () -> Void) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(title, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
        b.setTitleColor(.white, for: .normal)
        b.backgroundColor = UIColor(white: 0.28, alpha: 1)
        b.layer.cornerRadius = 6
        b.contentEdgeInsets = UIEdgeInsets(top: 7, left: 12, bottom: 7, right: 12)
        b.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return b
    }

    // MARK: test pattern (pre-server)

    private func renderTestPattern(into buf: UnsafeMutablePointer<UInt8>) {
        let boxX = (tickCount * 6) % max(1, fbWidth - 120)
        let midLo = fbHeight / 2 - 50, midHi = fbHeight / 2 + 50
        for y in 0..<fbHeight {
            let g = UInt8(y * 255 / fbHeight)
            let inBandY = y >= midLo && y < midHi
            var i = y * fbWidth * 4
            for x in 0..<fbWidth {
                if inBandY && x >= boxX && x < boxX + 120 {
                    buf[i] = 255; buf[i+1] = 255; buf[i+2] = 255
                } else {
                    buf[i] = UInt8(x * 255 / fbWidth); buf[i+1] = g; buf[i+2] = UInt8(tickCount & 0xff)
                }
                buf[i+3] = 255
                i += 4
            }
        }
    }
}

// The X screen view itself is the keyboard responder: the iOS keyboard's text
// becomes XTEST key events on the current display. Backspace stays live via hasText.
extension XScreenView: UIKeyInput {
    var hasText: Bool { true }

    func insertText(_ text: String) {
        guard inputConnected else { return }
        if usingIosc && !modCtrl && !modAlt && !modShift {
            sendText(text)
            return
        }
        for ch in text {
            if let ks = keysym(for: ch) {
                // Sticky mods apply to the first typed key, then auto-clear
                // (clearStickyMods() is a no-op once none are armed).
                sendKeysym(ks, ctrl: modCtrl, alt: modAlt, shift: modShift)
                clearStickyMods()
            }
        }
        clearStickyMods()
    }

    func deleteBackward() {
        guard inputConnected else { return }
        sendKeysym(0xff08, ctrl: modCtrl, alt: modAlt, shift: modShift)   // XK_BackSpace
        clearStickyMods()
    }
}

extension XScreenView: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer is UIPinchGestureRecognizer || otherGestureRecognizer is UIPinchGestureRecognizer
    }
}

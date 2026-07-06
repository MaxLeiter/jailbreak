import UIKit
import PhotosUI
import Metal
import QuartzCore
import IOSurface
import Darwin

enum XiosRuntimePaths {
    static func trimTrailingSlash(_ path: String) -> String {
        var out = path
        while out.count > 1 && out.hasSuffix("/") {
            out.removeLast()
        }
        return out
    }

    static var runtimeTmp: String {
        if let tmp = ProcessInfo.processInfo.environment["XIOS_RUNTIME_TMP"], !tmp.isEmpty {
            return trimTrailingSlash(tmp)
        }
        if let root = ProcessInfo.processInfo.environment["XIOS_PREFIX"], !root.isEmpty {
            let trimmed = trimTrailingSlash(root)
            return (trimmed == "/" ? "" : trimmed) + "/tmp"
        }
        if FileManager.default.fileExists(atPath: "/var/jb/usr") {
            return "/var/jb/tmp"
        }
        return "/var/tmp"
    }

    static var jbroot: String {
        if let root = ProcessInfo.processInfo.environment["XIOS_PREFIX"], !root.isEmpty {
            let trimmed = trimTrailingSlash(root)
            return trimmed == "/" ? "" : trimmed
        }
        if FileManager.default.fileExists(atPath: "/var/jb/usr") {
            return "/var/jb"
        }
        return ""
    }

    static func join(_ dir: String, _ name: String) -> String {
        dir == "/" ? "/" + name : dir + "/" + name
    }

    static func tmp(_ name: String) -> String {
        join(runtimeTmp, name)
    }

    static func prefixed(_ suffix: String) -> String {
        jbroot.isEmpty ? suffix : jbroot + suffix
    }

    static func tmpCandidates(_ name: String) -> [String] {
        var paths: [String] = []
        if let tmp = ProcessInfo.processInfo.environment["XIOS_RUNTIME_TMP"], !tmp.isEmpty {
            paths.append(join(trimTrailingSlash(tmp), name))
        }
        paths.append("/var/jb/tmp/" + name)
        paths.append("/var/tmp/" + name)
        return Array(NSOrderedSet(array: paths)) as? [String] ?? paths
    }

    static func firstExisting(_ name: String) -> String {
        tmpCandidates(name).first { FileManager.default.fileExists(atPath: $0) } ?? tmp(name)
    }
}

/// Root VC: a full-screen view that displays the X server's framebuffer.
final class XServerViewController: UIViewController {
    private let screen = XScreenView()
    override func loadView() { view = screen }
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        screen.allowsAllOrientations ? .all : .landscape
    }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        screen.start()
    }
}

/// Displays an X11 framebuffer on a CAMetalLayer at native retina resolution and
/// injects touch as X pointer events via XTEST/iosc input. The public display path
/// is IOSurface: `xios.json` must advertise `"ddx":"iosurface"`, then the app maps
/// that IOSurface into a Metal texture and re-presents only on damage.
final class XScreenView: UIView {
    private var fbWidth = 1024
    private var fbHeight = 768
    private var selectedConfigPath: String?
    private var configPath: String { selectedConfigPath ?? XiosRuntimePaths.firstExisting("xios.json") }
    // Which X display to drive (XTEST input). The server advertises this in
    // xios.json so the app and the launch scripts can't disagree; `:3` is only the
    // holding default before config arrives. Not pinned: the
    // picker can switch it to any open display (see discoverDisplays()/load()).
    private var xDisplay = ":3"
    private var xAuthPath: String?              // MIT-MAGIC-COOKIE-1 file from xios.json
    private var xunixDirs: [String] {
        ["/tmp/.X11-unix", XiosRuntimePaths.tmp(".X11-unix"), "/var/jb/tmp/.X11-unix", "/var/tmp/.X11-unix"]
    }
    // Bumped on every load(); the async IOSurface connect captures it and bails if a
    // newer load() superseded it, so switching displays can't adopt a stale surface.
    private var loadGeneration = 0
    private var userPinned = false              // user picked a display → stop auto-reloading xios.json
    private weak var pickerOverlay: UIView?
    private var requestPath: String { XiosRuntimePaths.tmp("xios-request.json") }
    private var ioscdSocketPath: String { XiosRuntimePaths.firstExisting("ioscd.sock") }
    private var sessionStatusPath: String { XiosRuntimePaths.firstExisting("xios-session-status.json") }
    private var displayRegistryDir: String { XiosRuntimePaths.tmp("xios-displays.d") }
    private let wallpaperConfigPath = "/var/mobile/Library/Preferences/com.max.iosc-wallpaper"
    private let wallpaperImagePath = "/var/mobile/Library/Preferences/com.max.iosc-wallpaper.jpg"
    private weak var sessionStatusLabel: UILabel?
    // Session-switch resilience: when the compositor dies mid-session the ddx surface
    // is lost; the app releases GPU state and holds on the test pattern (awaitingCompositor)
    // rather than jetsamming, while a full-screen banner shows the launcher's live status
    // (xios-session-status.json) so the switch reads as progress, not a dark screen.
    private var awaitingCompositor = false
    private var sessionBanner: UILabel?
    private var sessionIndicatorTimer: Timer?
    private var sessionIndicatorDeadline = Date.distantPast
    private var sessionIndicatorSawTransition = false
    private weak var shellOverlay: XiosShellOverlay?
    private weak var shellOverlayRevealPan: UIPanGestureRecognizer?
    private var shellOverlayAutoHideTimer: Timer?
    private var shellOverlaySwipeTriggered = false
    private static let shellOverlayAutoHideDelay: TimeInterval = 5.0
    private var debugPath: String { XiosRuntimePaths.tmp("xios-debug.txt") }
    private var lastToolMessage = "Ready"
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
    // Auto on-screen-keyboard responder policy (design: x11/docs/osk-plan.md).
    private var oskAutoShown = false          // the auto path raised the keyboard
    private var oskUserDismissed = false      // user hid it while the field was still enabled
    private var oskProgrammaticResign = false // our resign vs the user's
    private var oskHideTimer: Timer?
    private weak var ctrlBtn: UIButton?
    private weak var altBtn: UIButton?
    private weak var shiftBtn: UIButton?
    private weak var keyboardRevealPan: UIPanGestureRecognizer?
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

    // MARK: scroll + long-press gesture state
    /// Sub-1/256-px scroll remainder for the iosc AXIS path (wl_fixed units).
    private var axisRemainder = CGPoint.zero
    /// True once this two-finger pan has emitted AXIS records (needs a stop).
    private var axisActive = false
    /// Two-finger arbitration: the first gesture to cross its threshold claims
    /// the finger pair (scroll vs pinch app-zoom) for the rest of the session.
    private enum TwoFingerMode { case undecided, scroll, zoom }
    private var twoFingerMode = TwoFingerMode.undecided
    private var twoFingerActive = 0     // live pan/pinch recognizers (0..2)
    /// Deferred left press: a stationary single finger only commits to a left
    /// press when it moves (drag) or lifts (tap); held past the threshold it
    /// becomes a right click instead (touch-and-hold = context menu).
    private var pendingPress: (x: Int32, y: Int32)?
    private var pendingPressTimer: Timer?
    private var pendingPressViewPoint = CGPoint.zero
    private var leftPressSent = false
    private var longPressFired = false
    private var keyboardSwipeTriggered = false
    private var appGestureTouchSuppression = false
    private var configuredTouchReplacesPointer: Bool?
    private var activeTouchReplacesPointer = false
    private static let longPressSeconds: TimeInterval = 0.55
    private static let longPressSlopPt: CGFloat = 12

    // IOSurface (zero-copy) path
    private var ddxIsIOSurface = false
    private var ddxSockPath = XiosRuntimePaths.tmp("xios-ddx.sock")
    private var xconn: OpaquePointer?            // XSurfaceConn*
    private var iosTexture: MTLTexture?
    private var usingIOSurface = false
    private var iosConnectStarted = false
    private var needsPresent = false

    // Present-side cursor overlay. When iosc runs with IOSC_APP_CURSOR it stops
    // compositing the pointer and streams position+shape over the typed socket
    // (see XSurface.c); we draw it as a CALayer above the Metal content so a pointer
    // move is a Core Animation reposition with no Metal re-present. Stays nil (and
    // the compositor keeps drawing its own cursor) until the first CURSOR record.
    private var cursorLayer: CALayer?
    private var lastCursorSeq: UInt32 = 0
    private var cursorIsText = false
    private var hardwarePointerActive = false
    private var iosurfaceCompositorID = ""

    private var displayLink: CADisplayLink?
    private var testBuf: UnsafeMutablePointer<UInt8>?
    private var usingTestPattern = false
    // The animated test card is a LAST-RESORT no-signal diagnostic only. During
    // normal startup the IOSurface connects in ~1s, so we show clean black and never
    // the card; it appears only after this many test-pattern ticks with no framebuffer.
    private var testPatternStartTick = 0
    private static let testPatternGraceTicks = 150   // ~7.5s at 20fps
    private var inputConnected = false
    private var tickCount = 0

    // iosc (Wayland compositor) input path. When the app displays iosc's output rather
    // than an X server, single-finger touch + the keyboard are forwarded over this Unix
    // socket as Wayland pointer/keyboard events (see IoscInput.h) instead of via XTEST.
    // nil = not iosc mode (use the XTEST path). Resolved in loadConfig() from xios.json.
    private var ioscInputSock: String?
    private var ioscClipboardSock: String?
    private var pasteboardChangeCount = UIPasteboard.general.changeCount
    private let kClipText: UInt32 = 1, kClipURI: UInt32 = 2,
                kClipPNG: UInt32 = 3, kClipHTML: UInt32 = 4
    private var clipRxGen: UInt32 = 0
    private var clipRxItems: [UInt32: Data] = [:]
    private var clipDeferredPushTicks = 0   // connect grace: desktop wins if it speaks
    private var clipSuppressText: String?   // echo guards: what we last wrote/read
    private var clipSuppressPNG: Data?
    private var usingIosc: Bool { ioscInputSock != nil }
    var allowsAllOrientations: Bool { usingIosc }
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

    private struct SessionStatus {
        let preset: String
        let state: String
        let message: String
        let width: Int?
        let height: Int?
        let display: String?
        let ddx: String?
    }

    private struct LauncherApp {
        let id: String
        let name: String
        let exec: String
        let icon: String
        let bundlePath: String
        let enabled: Bool
    }

    private struct DesktopPreset {
        let preset: String
        let title: String
        let detail: String
        let iconName: String
    }

    private struct QuickLaunchApp {
        let title: String
        let exec: String
        let iconName: String
    }

    private var pendingSessionDisplay: DisplayProfile?

    private struct FitTransform {
        let fbWidth: Int
        let fbHeight: Int
        let viewBounds: CGRect
        let drawableSize: CGSize
        let contentsScale: CGFloat
        let scale: CGFloat
        let contentRect: CGRect

        static func make(fbWidth: Int, fbHeight: Int, viewBounds: CGRect,
                         drawableSize: CGSize, contentsScale: CGFloat,
                         zoom: CGFloat, pan: CGPoint) -> FitTransform? {
            guard fbWidth > 0, fbHeight > 0,
                  viewBounds.width > 0, viewBounds.height > 0,
                  drawableSize.width > 0, drawableSize.height > 0,
                  contentsScale > 0 else { return nil }
            let baseScale = min(viewBounds.width / CGFloat(fbWidth),
                                viewBounds.height / CGFloat(fbHeight))
            let scale = baseScale * zoom
            let size = CGSize(width: CGFloat(fbWidth) * scale,
                              height: CGFloat(fbHeight) * scale)
            let origin = CGPoint(
                x: viewBounds.midX - size.width / 2 + pan.x,
                y: viewBounds.midY - size.height / 2 + pan.y)
            return FitTransform(
                fbWidth: fbWidth,
                fbHeight: fbHeight,
                viewBounds: viewBounds,
                drawableSize: drawableSize,
                contentsScale: contentsScale,
                scale: scale,
                contentRect: CGRect(origin: origin, size: size))
        }

        func framebufferPoint(from point: CGPoint) -> CGPoint? {
            guard contentRect.contains(point),
                  contentRect.width > 0, contentRect.height > 0 else { return nil }
            let fx = (point.x - contentRect.minX) / contentRect.width * CGFloat(fbWidth)
            let fy = (point.y - contentRect.minY) / contentRect.height * CGFloat(fbHeight)
            return CGPoint(
                x: max(0, min(CGFloat(fbWidth - 1), fx)),
                y: max(0, min(CGFloat(fbHeight - 1), fy)))
        }

        func clipVertices() -> [Float]? {
            let dw = drawableSize.width
            let dh = drawableSize.height
            guard dw > 0, dh > 0 else { return nil }

            let left = contentRect.minX * contentsScale
            let right = contentRect.maxX * contentsScale
            let top = contentRect.minY * contentsScale
            let bottom = contentRect.maxY * contentsScale
            let x0 = Float(2 * left / dw - 1)
            let x1 = Float(2 * right / dw - 1)
            let y0 = Float(1 - 2 * top / dh)
            let y1 = Float(1 - 2 * bottom / dh)

            return [
                x0, y0, 0, 0,
                x0, y1, 0, 1,
                x1, y0, 1, 0,
                x1, y1, 1, 1,
            ]
        }
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
        SystemIntegration.shared.install(on: self)
        XiosCameraBroker.shared.start()
        isMultipleTouchEnabled = true
        // MTLCreateSystemDefaultDevice() returns nil for a backgrounded app (a
        // SpringBoard relaunch, or uicache registration launching us off-screen), so a
        // background launch would otherwise leave us permanently black with no recovery.
        // Retry once we become active/foreground, where the GPU is reachable.
        if !setupMetal() { observeForegroundRetry(); return }
        metalReady = true

        startTestPattern()
        if ddxIsIOSurface {
            // Zero-copy path. Connect off the main thread (the handshake does a
            // blocking mach_msg); keep the holding frame until the surface arrives.
            startIOSurfaceConnect()
        } else {
            awaitingCompositor = true
        }
        connectInput()
        writeStatus()
        isAccessibilityElement = false
        XiosA11yClient.shared.startup(view: self)

        let dl = CADisplayLink(target: self, selector: #selector(tick))
        dl.preferredFramesPerSecond = usingTestPattern ? 20 : 60
        dl.add(to: .main, forMode: .common)
        displayLink = dl

        installChrome()
        installShellOverlay()
        // start() already loaded the display in xios.json (the default). If other
        // displays are also open, offer the picker so the user can choose.
        let displays = discoverDisplays()
        if displays.count > 1 { presentDisplayControl(initial: .displays) }
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

    /// Show a clean black screen until a real framebuffer is available; only after a
    /// grace period without one does the animated test card appear (last-resort
    /// no-signal diagnostic, never during normal startup).
    private func startTestPattern() {
        usingTestPattern = true
        testBuf?.deallocate()       // safe to call when switching displays
        testBuf = .allocate(capacity: fbWidth * fbHeight * 4)
        testBuf?.initialize(repeating: 0, count: fbWidth * fbHeight * 4)   // clean black
        testPatternStartTick = tickCount
        makeTexture()
        needsPresent = true         // upload + present the initial clean-black frame once
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
        xconn = conn
        iosurfaceCompositorID = String(cString: xsurface_compositor_id(conn))
        guard syncSurfaceGeometry(conn) else {
            dbg("iosurface-texture-fail"); xsurface_close(conn); xconn = nil
            iosurfaceCompositorID = ""
            iosConnectStarted = false   // let the %30 poll retry the connect
            return
        }
        usingIOSurface = true
        awaitingCompositor = false                // new compositor surface is live again
        usingTestPattern = false
        testBuf?.deallocate(); testBuf = nil
        texture = nil                             // drop the test-pattern texture (~14 MB)
        needsPresent = true                       // present the initial frame
        displayLink?.preferredFramesPerSecond = 60
        connectInput()
        if usingIosc {
            SystemIntegration.shared.syncOutputNow()
        }
        writeStatus()
    }

    /// Keep Swift's framebuffer geometry + Metal texture aligned with the adopted
    /// IOSurface connection. Typed streams can refresh width/height in-band after
    /// xsurface_drain(); without re-reading here, render/input keep using stale fb dims.
    @discardableResult
    private func syncSurfaceGeometry(_ conn: OpaquePointer) -> Bool {
        let newWidth = Int(xsurface_width(conn))
        let newHeight = Int(xsurface_height(conn))
        guard newWidth > 0, newHeight > 0 else { return false }

        let geometryChanged = newWidth != fbWidth || newHeight != fbHeight
        let textureChanged = iosTexture?.width != newWidth || iosTexture?.height != newHeight
        guard geometryChanged || textureChanged else { return true }

        // C owns the IOSurface ref (released in xsurface_close); borrow it here.
        let surface = xsurface_get(conn).takeUnretainedValue()
        let td = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: newWidth, height: newHeight, mipmapped: false)
        td.usage = .shaderRead
        td.storageMode = .shared
        // Metal reads the surface's own (possibly padded) bytesPerRow; zero-copy.
        guard let tex = device.makeTexture(descriptor: td, iosurface: surface, plane: 0) else {
            return false
        }

        fbWidth = newWidth
        fbHeight = newHeight
        iosTexture = tex
        // Always snap to fit on adopt/resize (zoom 1, pan 0) — one source of truth for
        // present scale. A stale zoom over-scales the current fb and makes the inverse
        // touch mapping land offset.
        resetZoom()
        dumpGeom()
        if usingIOSurface { writeStatus() }
        return true
    }

    // MARK: present-side cursor overlay

    /// Pull the latest CURSOR state and move/hide the overlay layer. Cheap: reads
    /// the last-parsed state (no I/O — xsurface_drain already parsed it) and only
    /// touches Core Animation when the sequence changed.
    private func updateCursorOverlay(_ conn: OpaquePointer) {
        var x: Int32 = 0, y: Int32 = 0, vis: Int32 = 0, shape: Int32 = 0
        let seq = xsurface_cursor(conn, &x, &y, &vis, &shape)
        guard seq != 0 else { return }        // overlay off server-side → compositor draws it
        if seq == lastCursorSeq { return }    // no new pointer state this tick
        lastCursorSeq = seq

        if !hardwarePointerActive && iosurfaceCompositorID != "mutter-ios" {
            cursorLayer?.isHidden = true
            return
        }
        if cursorLayer == nil { makeCursorLayer(shape: shape) }
        guard let layer = cursorLayer else { return }
        if vis == 0 { layer.isHidden = true; return }
        layer.isHidden = false
        applyCursorShape(shape)               // swap arrow/I-beam if the category changed

        // Cursor coords arrive in framebuffer (physical) px; map through the same
        // fit/zoom/pan rect the framebuffer uses so the pointer tracks the content.
        let rect = contentRect()
        let vx = rect.minX + CGFloat(x) / CGFloat(max(fbWidth, 1)) * rect.width
        let vy = rect.minY + CGFloat(y) / CGFloat(max(fbHeight, 1)) * rect.height
        CATransaction.begin()
        CATransaction.setDisableActions(true)  // track instantly, no implicit move animation
        layer.position = CGPoint(x: vx, y: vy)
        CATransaction.commit()
    }

    private func makeCursorLayer(shape: Int32) {
        let layer = CALayer()
        layer.contentsScale = metalLayer.contentsScale
        layer.isHidden = true
        metalLayer.addSublayer(layer)          // above the Metal drawable, below the chrome UIViews
        cursorLayer = layer
        applyCursorShape(shape)
    }

    /// Rebuild the overlay bitmap only when the shape category flips (text vs arrow).
    private func applyCursorShape(_ shape: Int32) {
        let isText = (shape == 9 || shape == 10)   // wp_cursor_shape: 9=text, 10=vertical-text
        guard let layer = cursorLayer, layer.contents == nil || isText != cursorIsText else { return }
        cursorIsText = isText
        let (image, hotspot) = cursorImage(isText: isText)
        layer.contents = image.cgImage
        layer.bounds = CGRect(origin: .zero, size: image.size)
        layer.anchorPoint = hotspot            // hotspot sits at layer.position
    }

    /// A small pointer bitmap + its hotspot (as a unit anchorPoint). Black fill with a
    /// white outline so it reads on any background. Shape fidelity beyond arrow/I-beam
    /// is a follow-up; the value here is the zero-recomposite pointer move.
    private func cursorImage(isText: Bool) -> (UIImage, CGPoint) {
        if isText {
            let size = CGSize(width: 9, height: 22)
            let img = UIGraphicsImageRenderer(size: size).image { ctx in
                let c = ctx.cgContext
                let beam = { (c: CGContext) in
                    c.move(to: CGPoint(x: 4.5, y: 2));  c.addLine(to: CGPoint(x: 4.5, y: 20))
                    c.move(to: CGPoint(x: 2, y: 2));    c.addLine(to: CGPoint(x: 7, y: 2))
                    c.move(to: CGPoint(x: 2, y: 20));   c.addLine(to: CGPoint(x: 7, y: 20))
                }
                c.setLineCap(.round)
                c.setStrokeColor(UIColor.white.cgColor); c.setLineWidth(3); beam(c); c.strokePath()
                c.setStrokeColor(UIColor.black.cgColor); c.setLineWidth(1); beam(c); c.strokePath()
            }
            return (img, CGPoint(x: 0.5, y: 0.5))   // hotspot: centre
        }
        let size = CGSize(width: 16, height: 24)
        let img = UIGraphicsImageRenderer(size: size).image { ctx in
            let c = ctx.cgContext
            let p = CGMutablePath()
            p.addLines(between: [
                CGPoint(x: 1, y: 1),   CGPoint(x: 1, y: 19),  CGPoint(x: 5.5, y: 14.5),
                CGPoint(x: 8.5, y: 21), CGPoint(x: 11, y: 20), CGPoint(x: 8, y: 13.5),
                CGPoint(x: 14, y: 13.5),
            ])
            p.closeSubpath()
            c.addPath(p); c.setStrokeColor(UIColor.white.cgColor)
            c.setLineWidth(2); c.setLineJoin(.round); c.strokePath()
            c.addPath(p); c.setFillColor(UIColor.black.cgColor); c.fillPath()
        }
        return (img, CGPoint(x: 1.0 / 16.0, y: 1.0 / 24.0))   // hotspot: arrow tip
    }

    private func removeCursorOverlay() {
        cursorLayer?.removeFromSuperlayer()
        cursorLayer = nil
        lastCursorSeq = 0
        hardwarePointerActive = false
    }

    // MARK: Metal setup

    private func dbg(_ s: String) {
        try? s.write(toFile: XiosRuntimePaths.tmp("xios-metal.txt"), atomically: true, encoding: .utf8)
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
        dumpGeom()
        if usingIosc {
            SystemIntegration.shared.syncOutputNow()
        }
        // contentRect() moved (rotation/resize/zoom); re-place an idle cursor overlay.
        if let conn = xconn, cursorLayer != nil { lastCursorSeq = 0; updateCursorOverlay(conn) }
        shellOverlay?.setNeedsLayout()
        refreshShellOverlay()
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
        try? txt.write(toFile: XiosRuntimePaths.tmp("xios-geom.txt"), atomically: true, encoding: .utf8)
    }

    // MARK: framebuffer

    /// The xios.json fields read by BOTH the loader and the ~1.5s watchdog, normalized
    /// identically (empty socket → nil, non-positive width/height → nil) so change
    /// detection and adoption can never disagree about what the file says. Fallbacks
    /// deliberately stay with the callers: loadConfig() falls back to hard defaults,
    /// ddxConfigChanged() to the adopted state (so it never loops in steady state).
    private struct DDXFields {
        let isIOSurface: Bool
        let socket: String?
        let width: Int?
        let height: Int?
        init(_ obj: [String: Any]) {
            // Presence of "ddx":"iosurface" selects the zero-copy IOSurface path.
            isIOSurface = (obj["ddx"] as? String) == "iosurface"
            socket = (obj["socket"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            width = (obj["width"] as? Int).flatMap { $0 > 0 ? $0 : nil }
            height = (obj["height"] as? Int).flatMap { $0 > 0 ? $0 : nil }
        }
    }

    @discardableResult
    private func loadConfig() -> Bool {
        guard let obj = readConfig() else { return false }
        let ddx = DDXFields(obj)

        let oldWidth = fbWidth
        let oldHeight = fbHeight
        let oldDisplay = xDisplay
        let oldAuth = xAuthPath
        let oldIsIOSurface = ddxIsIOSurface
        let oldSocket = ddxSockPath
        let oldIoscSock = ioscInputSock
        let oldIoscClipSock = ioscClipboardSock

        resetConfigDefaults(resetDisplay: true)
        configuredTouchReplacesPointer = Self.parseTouchPointerPolicy(obj)
        if let w = ddx.width { fbWidth = w }
        if let h = ddx.height { fbHeight = h }
        ddxIsIOSurface = ddx.isIOSurface
        if let s = ddx.socket { ddxSockPath = s }
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
                ioscInputSock = XiosRuntimePaths.tmp("iosc-input.sock")
            }
            if let s = obj["clipboard_socket"] as? String, !s.isEmpty {
                ioscClipboardSock = s
            } else if ddxSockPath.contains("iosc") {
                ioscClipboardSock = XiosRuntimePaths.tmp("iosc-clipboard.sock")
            }
        }

        let renderStateChanged = oldWidth != fbWidth || oldHeight != fbHeight ||
            oldIsIOSurface != ddxIsIOSurface || oldSocket != ddxSockPath
        let inputStateChanged = oldDisplay != xDisplay || oldAuth != xAuthPath ||
            oldIoscSock != ioscInputSock || oldIoscClipSock != ioscClipboardSock
        if renderStateChanged || inputStateChanged {
            loadGeneration += 1
            iosConnectStarted = false
        }
        if inputStateChanged {
            closeInput()
        }
        if oldIoscSock != ioscInputSock {
            owningViewController()?.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
        return true
    }

    /// True if xios.json now advertises a DIFFERENT iosurface than the one adopted
    /// (compositor restarted at a new -logical, or a different compositor took over).
    /// Compared against the adopted socket + surface size (fbWidth/fbHeight), which
    /// equal the xios.json we last adopted from — so it never loops in steady state.
    private func ddxConfigChanged() -> Bool {
        guard let obj = readConfig() else { return false }
        let ddx = DDXFields(obj)
        guard ddx.isIOSurface else { return false }
        return (ddx.socket ?? ddxSockPath) != ddxSockPath ||
            (ddx.width ?? fbWidth) != fbWidth ||
            (ddx.height ?? fbHeight) != fbHeight
    }

    /// Release the adopted IOSurface + its Metal texture. `lost` distinguishes the two
    /// callers: the watchdog (lost == false) fires when xios.json already names a NEW,
    /// live surface, so re-adopt immediately; the drain (lost == true) fires when the
    /// compositor DIED (socket EOF) — the new surface may not exist yet, so drop to the
    /// low-footprint test pattern and let the %30 poll re-adopt once xios.json names a
    /// live socket. Dropping GPU state promptly on loss is what keeps the app OUT of the
    /// flavor-switch memory spike (our iosTexture otherwise pins the old ~30MB IOSurface,
    /// so the compositor's death frees nothing until we let go) and lets it stay up
    /// through the switch instead of getting jetsammed.
    private func teardownIOSurface(lost: Bool = false) {
        if let c = xconn { xsurface_close(c); xconn = nil }
        iosurfaceCompositorID = ""
        iosTexture = nil
        usingIOSurface = false
        removeCursorOverlay()
        if !userPinned { _ = loadConfig() }
        writeStatus()
        iosConnectStarted = false
        if lost {
            // Compositor gone: show a clean holding frame + the live switch status, and
            // wait for a new surface (poll path re-reads xios.json + re-adopts). Do NOT
            // eagerly reconnect here — the old socket is dead and may be replaced by a
            // DIFFERENT compositor at a different path.
            awaitingCompositor = true
            startTestPattern()
            startSessionIndicator()
        } else if ddxIsIOSurface {
            startIOSurfaceConnect()   // last frame stays frozen until the server returns
        } else {
            awaitingCompositor = true
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
            // Watchdog: while presenting, tick() never re-reads xios.json, so a
            // compositor that RESTARTS at a new -logical (the output IOSurface changes
            // size), or a DIFFERENT compositor taking over, would be missed — the app
            // stays pinned to the STALE surface (also the case for a FrontBoard-resumed
            // instance that kept old state after a kill+relaunch). Every ~1.5s re-check
            // xios.json; if it now names a different socket or surface size, teardown +
            // re-adopt the CURRENT one (adoptIOSurface then re-fits via resetZoom).
            if tickCount % 30 == 0, !userPinned, ddxConfigChanged() {
                teardownIOSurface()
                return
            }
            guard let conn = xconn else { return }
            let r = xsurface_drain(conn)
            if r < 0 { teardownIOSurface(lost: true); return }
            if !syncSurfaceGeometry(conn) { teardownIOSurface(); return }
            if r > 0 { needsPresent = true }
            // Reposition the cursor overlay independently of surface damage: a pure
            // pointer move updates the CALayer without re-presenting the framebuffer.
            updateCursorOverlay(conn)
            guard let tex = iosTexture else { return }
            if needsPresent {
                let seq = xsurface_dirty_sequence(conn)
                if render(tex, presentedSeq: seq, conn: conn) { needsPresent = false }
            }
            return
        }

        // Poll for the IOSurface backend. Reached only while the holding frame is live.
        if tickCount % 30 == 0 {
            if !userPinned { _ = loadConfig() }   // auto mode picks up xios.json; a manual
                                              // pick keeps its own display/backend choice
            if usingTestPattern, texture?.width != fbWidth || texture?.height != fbHeight {
                startTestPattern()
            }
            if ddxIsIOSurface {
                startIOSurfaceConnect()
            } else {
                awaitingCompositor = true
            }
        }
        // Keep the test-pattern buffer + texture sized to the CURRENT fb before writing.
        // fbWidth/fbHeight can grow (compositor resize / re-adopt / session switch) after
        // testBuf+texture were allocated, and both renderTestPattern (CPU write) and
        // texture.replace (GPU) below write fbWidth*fbHeight*4 — a stale, smaller buffer
        // overflows and SIGSEGVs (seen on session-switch teardown). The %30 poll's realloc
        // isn't enough on its own: the write runs every tick, so re-check it here.
        if usingTestPattern, texture?.width != fbWidth || texture?.height != fbHeight {
            startTestPattern()
        }
        guard let texture = texture else { return }

        let base: UnsafeRawPointer
        if let b = testBuf {
            // Clean black by default (the buffer stays zeroed); the animated card is a
            // last-resort no-signal diagnostic shown only after the grace period.
            if tickCount - testPatternStartTick >= Self.testPatternGraceTicks, !awaitingCompositor {
                renderTestPattern(into: b)   // stay clean black mid-switch; banner shows status
                needsPresent = true          // animated frame changed: re-upload + re-present
            }
            // Static hold (clean black, esp. awaitingCompositor — the low-footprint
            // window that dodges the flavor-switch jetsam): the buffer is unchanged, so
            // skip the fbW*fbH*4 texture upload + render pass; the layer keeps the last
            // presented frame. needsPresent re-arms on startTestPattern (first frame /
            // resize) and on transform changes (layout/zoom/pan), same as the IOSurface
            // path's dirty-present discipline.
            guard needsPresent else { return }
            base = UnsafeRawPointer(b)
        } else { return }

        texture.replace(region: MTLRegionMake2D(0, 0, fbWidth, fbHeight),
                        mipmapLevel: 0, withBytes: base, bytesPerRow: fbWidth * 4)
        if render(texture) { needsPresent = false }
    }

    /// Draw the texture using the current fit/zoom/pan transform.
    @discardableResult
    private func render(_ tex: MTLTexture,
                        presentedSeq: UInt64 = 0,
                        conn: OpaquePointer? = nil) -> Bool {
        guard let drawable = metalLayer.nextDrawable(),
              let cmd = queue.makeCommandBuffer(),
              let fit = fitTransform(),
              var verts = fit.clipVertices() else { return false }
        // triangle strip: TL, BL, TR, BR  (pos.xy, uv.xy); uv origin top-left
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
        if let conn, presentedSeq != 0 {
            cmd.addCompletedHandler { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self, self.xconn == conn else { return }
                    _ = xsurface_presented(conn, presentedSeq)
                }
            }
        }
        cmd.present(drawable)
        cmd.commit()
        return true
    }

    private func writeStatus() {
        let fb: String
        if usingIOSurface {
            fb = "iosurface-zerocopy \(fbWidth)x\(fbHeight) [metal]"
        } else {
            fb = "holding-frame awaiting iosurface \(fbWidth)x\(fbHeight) [metal]"
        }
        let inp: String
        if !inputConnected {
            inp = "input-not-connected"
        } else if usingIosc {
            switch iosurfaceCompositorID {
            case "mutter-ios":
                inp = "input-connected mutter(wayland)"
            case "iosc":
                inp = "input-connected iosc(wayland)"
            case "":
                inp = "input-connected wayland"
            default:
                inp = "input-connected \(iosurfaceCompositorID)(wayland)"
            }
        } else {
            inp = "input-connected \(xDisplay)"
        }
        try? "\(fb)\n\(inp)\n".write(toFile: XiosRuntimePaths.tmp("xios-status.txt"), atomically: true, encoding: .utf8)
        refreshShellOverlay()
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

    private var sessionDisplayProfiles: [DisplayProfile] {
        [
            DisplayProfile(name: "Landscape", width: 1440, height: 1080, dpi: 176,
                           detail: "1440x1080 logical"),
            DisplayProfile(name: "Portrait", width: 1080, height: 1440, dpi: 176,
                           detail: "1080x1440 logical"),
            DisplayProfile(name: "Compact", width: 810, height: 1080, dpi: 132,
                           detail: "810x1080 logical"),
        ]
    }

    private var desktopPresets: [DesktopPreset] {
        [
            DesktopPreset(preset: "iosc", title: "iosc Desktop",
                          detail: "Shell, dock, wallpaper", iconName: "rectangle.on.rectangle"),
            DesktopPreset(preset: "mutter", title: "Mutter",
                          detail: "Raw compositor", iconName: "display"),
            DesktopPreset(preset: "gnome", title: "GNOME Shell",
                          detail: "Full desktop session", iconName: "circle.grid.cross"),
            DesktopPreset(preset: "kde", title: "KDE Plasma",
                          detail: "KWin and desktop shell", iconName: "sparkles.rectangle.stack"),
            DesktopPreset(preset: "kde-nano", title: "Plasma Nano",
                          detail: "KWin and nano shell", iconName: "rectangle.grid.1x2"),
            DesktopPreset(preset: "kde-mobile", title: "Plasma Mobile",
                          detail: "KWin and mobile shell", iconName: "ipad"),
        ]
    }

    private var quickLaunchApps: [QuickLaunchApp] {
        [
            QuickLaunchApp(title: "Console", exec: "kgx", iconName: "terminal"),
            QuickLaunchApp(title: "Text Editor", exec: "gnome-text-editor", iconName: "doc.text"),
            QuickLaunchApp(title: "Calculator", exec: "gnome-calculator", iconName: "plus.forwardslash.minus"),
        ]
    }

    private func sessionDisplaySummary() -> String {
        if let p = pendingSessionDisplay {
            return "\(p.name): \(p.detail)" + (p.dpi > 0 ? " @ \(p.dpi) DPI" : "")
        }
        return "Keep current/default size"
    }

    private func writeDisplayRequest(_ profile: DisplayProfile) {
        var obj: [String: Any] = [
            "action": "display-profile",
            "profile": profile.name,
            "width": profile.width,
            "height": profile.height,
            "display": xDisplay,
            "backend": "iosurface",
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

    private func sendIOSCDRequest(_ line: String, maxBytes: Int = 1 << 20) -> String? {
        let fd = xiosConnectUnixSocket(ioscdSocketPath)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard line.data(using: .utf8)?.withUnsafeBytes({ xiosWriteAll(fd, bytes: $0) }) == true
        else { return nil }
        Darwin.shutdown(fd, SHUT_WR)

        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while data.count < maxBytes {
            let n = buf.withUnsafeMutableBytes { raw in
                read(fd, raw.baseAddress, raw.count)
            }
            if n > 0 {
                data.append(buf, count: Int(n))
            } else if n < 0 && errno == EINTR {
                continue
            } else {
                break
            }
        }
        return String(data: data, encoding: .utf8)
    }

    private func ioscdResponseLines(_ line: String) -> [String]? {
        sendIOSCDRequest(line)?.split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .newlines) }
            .filter { !$0.isEmpty }
    }

    private func sendSessionRequestToIOSCD(_ preset: String, app: String?,
                                           display: DisplayProfile?,
                                           slot: String? = nil) -> String? {
        var width = ""
        var height = ""
        var dpi = ""
        if preset != "app", preset != "stop", let display {
            width = String(display.width)
            height = String(display.height)
            if display.dpi > 0 { dpi = String(display.dpi) }
        }
        let line = ["SESSION", preset, app ?? "", width, height, dpi, slot ?? ""]
            .joined(separator: "\t") + "\n"
        return sendIOSCDRequest(line, maxBytes: 4096)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Pick a desktop flavor from the device through ioscd's request/reply socket.
    private func writeSessionRequest(_ preset: String, app: String? = nil,
                                     display: DisplayProfile? = nil,
                                     slot: String? = nil) {
        let response = sendSessionRequestToIOSCD(preset, app: app, display: display, slot: slot)
        if response?.hasPrefix("SESSION_STARTED") == true {
            lastToolMessage = "Session: \(preset)" + (app.map { " \($0)" } ?? "")
                + (slot.map { " slot=\($0)" } ?? "")
                + (display.map { " \($0.detail)" } ?? "")
            // Track the switch from here on (card line + full-screen banner once dismissed),
            // so it survives the app staying up through a compositor swap.
            startSessionIndicator()
        } else {
            let detail = response?.isEmpty == false ? response! : "ioscd socket unavailable"
            lastToolMessage = "Session request failed: \(detail)"
        }
        writeDebugSnapshot()
    }

    private func newSessionSlot(for preset: String) -> String {
        let base = preset.lowercased()
            .map { $0.isLetter || $0.isNumber || $0 == "-" ? String($0) : "-" }
            .joined()
        let stamp = Int(Date().timeIntervalSince1970) % 100000
        return "\(base)-\(stamp)"
    }

    private func reloadRuntimeConfig() {
        _ = loadConfig()
        if ddxIsIOSurface, !usingIOSurface { startIOSurfaceConnect() }
        if !ddxIsIOSurface { awaitingCompositor = true; startTestPattern() }
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

    private static func parseTouchPointerPolicy(_ obj: [String: Any]) -> Bool? {
        if let value = obj["touch_replaces_pointer"] as? Bool { return value }
        guard let raw = obj["touch_pointer_policy"] as? String else { return nil }
        switch raw.lowercased() {
        case "touch", "touch-only", "replace-pointer", "touch-replaces-pointer":
            return true
        case "additive", "pointer-fallback", "pointer":
            return false
        default:
            return nil
        }
    }

    private func sessionWantsTouchToReplacePointer() -> Bool {
        guard let preset = sessionStatus()?.preset.lowercased() else { return false }
        return preset == "kde" || preset.hasPrefix("kde-")
    }

    private func shouldTouchReplacePointer(for touches: Set<UITouch>) -> Bool {
        guard usingIosc,
              touches.contains(where: { $0.type == .direct }) else {
            return false
        }
        return configuredTouchReplacesPointer ?? sessionWantsTouchToReplacePointer()
    }

    private func owningViewController() -> UIViewController? {
        var responder: UIResponder? = self
        while let current = responder {
            if let vc = current as? UIViewController { return vc }
            responder = current.next
        }
        return nil
    }

    private func restartIoscForWallpaper() {
        if activeDesktopPreset() == "iosc" {
            writeSessionRequest("iosc")
        } else {
            lastToolMessage = "Wallpaper saved; start iosc to use it"
            writeDebugSnapshot()
        }
        refreshShellOverlay()
    }

    private func setDesktopWallpaper(_ image: UIImage) {
        let fm = FileManager.default
        let dir = (wallpaperImagePath as NSString).deletingLastPathComponent
        do {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            guard let data = image.jpegData(compressionQuality: 0.92) else {
                lastToolMessage = "Could not encode wallpaper"
                return
            }
            try data.write(to: URL(fileURLWithPath: wallpaperImagePath), options: .atomic)
            try (wallpaperImagePath + "\n").write(toFile: wallpaperConfigPath,
                                                  atomically: true,
                                                  encoding: .utf8)
            lastToolMessage = "Wallpaper set"
            restartIoscForWallpaper()
        } catch {
            lastToolMessage = "Wallpaper failed: \(error.localizedDescription)"
            writeDebugSnapshot()
        }
    }

    private func resetDesktopWallpaper() {
        do {
            try FileManager.default.removeItem(atPath: wallpaperConfigPath)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain &&
            error.code == NSFileNoSuchFileError {
            // Already default.
        } catch {
            lastToolMessage = "Reset wallpaper failed: \(error.localizedDescription)"
            writeDebugSnapshot()
            return
        }
        lastToolMessage = "Wallpaper reset"
        restartIoscForWallpaper()
    }

    private func presentDesktopWallpaperPicker() {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.filter = .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        owningViewController()?.present(picker, animated: true)
    }

    private func desktopContextMenu() -> UIMenu {
        let pasteString = UIPasteboard.general.string
        let canPaste = pasteString?.isEmpty == false
        let pasteAttrs: UIMenuElement.Attributes = canPaste ? [] : [.disabled]

        var children: [UIMenuElement] = [
            UIAction(title: "Displays & Sessions", image: UIImage(systemName: "rectangle.3.group")) {
                [weak self] _ in self?.presentDisplayControl(initial: .sessions)
            },
            UIAction(title: "Launch App...", image: UIImage(systemName: "square.grid.2x2")) {
                [weak self] _ in self?.presentAppLauncher()
            },
            UIAction(title: "Home Screen Apps", image: UIImage(systemName: "app.badge")) {
                [weak self] _ in self?.presentHomeScreenApps()
            },
            UIAction(title: "Show Keyboard", image: UIImage(systemName: "keyboard")) { [weak self] _ in
                _ = self?.becomeFirstResponder()
            },
            UIAction(title: "Paste", image: UIImage(systemName: "doc.on.clipboard"),
                     attributes: pasteAttrs) { [weak self] _ in
                self?.sendText(pasteString ?? "")
            },
        ]

        if activeDesktopPreset() == "iosc" {
            children.append(UIMenu(title: "Background", image: UIImage(systemName: "photo"), children: [
                UIAction(title: "Set Background...", image: UIImage(systemName: "photo.on.rectangle")) {
                    [weak self] _ in self?.presentDesktopWallpaperPicker()
                },
                UIAction(title: "Reset Background", image: UIImage(systemName: "arrow.counterclockwise")) {
                    [weak self] _ in self?.resetDesktopWallpaper()
                },
            ]))
        }

        children.append(UIMenu(title: "Display", image: UIImage(systemName: "display"), children: [
            UIAction(title: "Fit Display", image: UIImage(systemName: "arrow.up.left.and.arrow.down.right")) {
                [weak self] _ in
                self?.resetZoom()
                self?.lastToolMessage = "Fit current display"
                self?.refreshShellOverlay()
            },
            UIAction(title: "Reload Display", image: UIImage(systemName: "arrow.clockwise")) {
                [weak self] _ in
                self?.reloadRuntimeConfig()
                self?.lastToolMessage = "Reloaded xios.json"
                self?.refreshShellOverlay()
            },
            UIAction(title: "Reconnect Input",
                     image: UIImage(systemName: "point.topleft.down.curvedto.point.bottomright.up")) {
                [weak self] _ in
                guard let self else { return }
                self.reconnectInput()
                self.lastToolMessage = "Reconnected \(self.inputBackendName())"
                self.refreshShellOverlay()
            },
        ]))

        children.append(UIMenu(title: "Maintenance", image: UIImage(systemName: "wrench.and.screwdriver"), children: [
            UIAction(title: "Copy Debug", image: UIImage(systemName: "doc.on.doc")) {
                [weak self] _ in self?.copyDebugSnapshot()
            },
            UIAction(title: "Tools", image: UIImage(systemName: "slider.horizontal.3")) {
                [weak self] _ in self?.presentTools()
            },
            UIAction(title: "Stop Session", image: UIImage(systemName: "stop.circle"),
                     attributes: [.destructive]) { [weak self] _ in
                self?.writeSessionRequest("stop")
            },
        ]))

        return UIMenu(title: "", children: children)
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
            "backend=\(usingIOSurface ? "iosurface" : "holding-frame")",
            "ddx_iosurface=\(ddxIsIOSurface)",
            "fb=\(fbWidth)x\(fbHeight)",
            "view=\(Int(bounds.width))x\(Int(bounds.height)) drawable=\(Int(ds.width))x\(Int(ds.height)) scale=\(metalLayer.contentsScale)",
            "native=\(Int(nb.width))x\(Int(nb.height)) zoom=\(Int((zoomScale * 100).rounded())) pan=\(Int(panOffset.x)),\(Int(panOffset.y))",
            "input=\(inputConnected ? "connected" : "not-connected") backend=\(inputBackendName())",
            "xauth=\(xAuthPath ?? "(none)")",
            "ddx_socket=\(ddxSockPath)",
            "iosc_input=\(ioscInputSock ?? "(none)")",
            "iosc_clipboard=\(ioscClipboardSock ?? "(none)")",
            "test_pattern=\(usingTestPattern)",
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
        // poll_traits now returns one record per call; drain them all so every
        // enable/disable transition reaches the responder policy.
        while true {
            var hint: UInt32 = 0, purpose: UInt32 = 0, enabled: UInt32 = 0
            let r = iosc_input_poll_traits(&hint, &purpose, &enabled)
            if r < 0 { inputConnected = false; writeStatus(); return }
            if r == 0 { return }
            applyIoscInputTraits(hint: hint, purpose: purpose, enabled: enabled)
        }
    }

    /// The responder half of the auto keyboard (design: x11/docs/osk-plan.md).
    /// TRAITS enable raises the keyboard, disable lowers it — but a keyboard the
    /// user opened/dismissed stays user-owned, and a focus hop (disable+enable
    /// back to back) is debounced so the keyboard doesn't bounce.
    private func updateAutoKeyboard(enabled: Bool) {
        if enabled {
            oskHideTimer?.invalidate()
            oskHideTimer = nil
            if !isFirstResponder && !oskUserDismissed {
                if becomeFirstResponder() { oskAutoShown = true }
            }
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

    private func applyIoscInputTraits(hint: UInt32, purpose: UInt32, enabled: UInt32) {
        updateAutoKeyboard(enabled: enabled != 0)   // before the guard: see osk-plan.md
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
            guard tickCount % 30 == 0, iosc_clipboard_open(sock) else { return }
            pasteboardChangeCount = UIPasteboard.general.changeCount
            // On (re)connect the compositor replays the session clipboard if it
            // has one. Push ours only if it stays silent for ~0.5 s — so a fresh
            // desktop inherits the iOS pasteboard, but an app relaunch mid-session
            // doesn't clobber the desktop clipboard with a stale one.
            clipDeferredPushTicks = 30
        }
        var gotAny = false
        while true {
            var kind: UInt32 = 0, gen: UInt32 = 0, len: UInt32 = 0
            var buf: UnsafeMutablePointer<UInt8>? = nil
            let r = iosc_clipboard_poll_item(&kind, &gen, &buf, &len)
            if r < 0 { clipDeferredPushTicks = 0; return }
            if r == 0 { break }
            clipDeferredPushTicks = 0
            if gen != clipRxGen { clipRxGen = gen; clipRxItems.removeAll() }
            if kind == 0 { free(buf); clipRxItems.removeAll() }
            else if let b = buf {
                clipRxItems[kind] = Data(bytesNoCopy: b, count: Int(len),
                                         deallocator: .free)
            }
            gotAny = true
        }
        if gotAny { commitReceivedClipboard() }
        if clipDeferredPushTicks > 0 {
            clipDeferredPushTicks -= 1
            if clipDeferredPushTicks == 0 { pushPasteboard(onConnect: true) }
        }
        if UIPasteboard.general.changeCount != pasteboardChangeCount {
            pushPasteboard(onConnect: false)
        }
    }

    private func commitReceivedClipboard() {
        let pb = UIPasteboard.general
        var item: [String: Any] = [:]
        if let t = clipRxItems[kClipText], let s = String(data: t, encoding: .utf8) {
            item["public.utf8-plain-text"] = s
            clipSuppressText = s
        } else { clipSuppressText = nil }
        if let png = clipRxItems[kClipPNG] {
            item["public.png"] = png
            clipSuppressPNG = png
        } else { clipSuppressPNG = nil }
        if let u = clipRxItems[kClipURI], let s = String(data: u, encoding: .utf8) {
            let uris = s.split(whereSeparator: { $0 == "\r" || $0 == "\n" })
                        .filter { !$0.hasPrefix("#") }
            // A copied web link should paste as a link; file:// paths from Linux
            // mean nothing to iOS apps, so those only ride along as text.
            if uris.count == 1, let url = URL(string: String(uris[0])),
               url.scheme == "http" || url.scheme == "https" {
                item["public.url"] = url.absoluteString
            }
            if item["public.utf8-plain-text"] == nil {
                item["public.utf8-plain-text"] = s
            }
        }
        if let h = clipRxItems[kClipHTML], let s = String(data: h, encoding: .utf8) {
            item["public.html"] = s
        }
        pb.items = item.isEmpty ? [] : [item]
        pasteboardChangeCount = pb.changeCount   // our own write, not an iOS copy
    }

    private func pushPasteboard(onConnect: Bool) {
        let pb = UIPasteboard.general
        pasteboardChangeCount = pb.changeCount
        let text = pb.hasStrings ? pb.string : nil
        let png: Data? = pb.hasImages
            ? (pb.data(forPasteboardType: "public.png") ?? pb.image?.pngData())
            : nil
        let urls = pb.hasURLs ? (pb.urls ?? []) : []
        if text == nil && png == nil && urls.isEmpty {
            // Empty pasteboard: on connect that's "nothing to contribute", not
            // "clear the desktop clipboard".
            if !onConnect { _ = iosc_clipboard_send_clear() }
            clipSuppressText = nil; clipSuppressPNG = nil
            return
        }
        if !onConnect && text == clipSuppressText && png == clipSuppressPNG {
            return   // echo of our own commitReceivedClipboard write
        }
        iosc_clipboard_send_begin()
        if let t = text {
            _ = t.withCString { iosc_clipboard_send_item(kClipText, $0, strlen($0)) }
        }
        if let p = png {
            _ = p.withUnsafeBytes {
                iosc_clipboard_send_item(kClipPNG, $0.baseAddress, p.count)
            }
        }
        if !urls.isEmpty {
            let list = urls.map(\.absoluteString).joined(separator: "\r\n") + "\r\n"
            _ = list.withCString { iosc_clipboard_send_item(kClipURI, $0, strlen($0)) }
            if text == nil {
                _ = list.withCString { iosc_clipboard_send_item(kClipText, $0, strlen($0)) }
            }
        }
        clipSuppressText = text; clipSuppressPNG = png
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
            text.withCString { iosc_input_text($0) }
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

    // MARK: accessibility (XiosA11y.swift publishes onto this view)

    /// Inverse of framebufferPoint's fit/zoom/pan mapping: framebuffer-px rect
    /// -> view points, then UIAccessibility converts the result to screen coords.
    func viewRect(fromFramebuffer r: CGRect) -> CGRect {
        guard let fit = fitTransform(), fit.scale > 0 else { return .zero }
        return CGRect(
            x: fit.contentRect.minX + r.minX * fit.scale,
            y: fit.contentRect.minY + r.minY * fit.scale,
            width: r.width * fit.scale,
            height: r.height * fit.scale)
    }

    /// VoiceOver escape gesture: Esc through the active desktop input backend.
    func a11yEscape() {
        guard inputConnected else { return }
        sendKeysym(0xff1b, ctrl: false, alt: false, shift: false)
    }

    /// Helper-requested fallback tap at framebuffer px (element had no AT-SPI Action).
    func a11ySynthTap(x: Int32, y: Int32) {
        guard inputConnected else { return }
        let p = (x, y)
        lastTouchPt = p
        sendMotion(p.0, p.1)
        sendButton(1, true, at: p)
        sendButton(1, false, at: p)
    }

    private func sendWheel(_ button: Int32) {
        guard inputConnected, !usingIosc else { return }
        xinput_button(button, true)
        xinput_button(button, false)
    }

    private func fitTransform(zoom: CGFloat? = nil, pan: CGPoint? = nil) -> FitTransform? {
        FitTransform.make(
            fbWidth: fbWidth,
            fbHeight: fbHeight,
            viewBounds: bounds,
            drawableSize: metalLayer.drawableSize,
            contentsScale: metalLayer.contentsScale,
            zoom: zoom ?? zoomScale,
            pan: pan ?? panOffset)
    }

    private func contentRect(zoom: CGFloat? = nil, pan: CGPoint? = nil) -> CGRect {
        fitTransform(zoom: zoom, pan: pan)?.contentRect ?? .zero
    }

    private func clampedPanOffset(_ p: CGPoint, zoom: CGFloat) -> CGPoint {
        guard let fit = fitTransform(zoom: zoom, pan: .zero) else { return .zero }
        let rect = fit.contentRect
        let maxX = max(0, (rect.width - bounds.width) / 2)
        let maxY = max(0, (rect.height - bounds.height) / 2)
        return CGPoint(
            x: min(max(p.x, -maxX), maxX),
            y: min(max(p.y, -maxY), maxY))
    }

    private func framebufferFloatPoint(from p: CGPoint) -> CGPoint? {
        guard let fit = fitTransform() else { return nil }
        return fit.framebufferPoint(from: p)
    }

    /// Touch-coordinate diagnostic (overwrites, so it holds the latest committed
    /// press): the deploy-verify workflow in docs/handoff/xios-app.md reads
    /// /var/jb/tmp/xios-touch.log after a tap. Written only where a press commits;
    /// the motion / coalesced-Pencil path must stay free of file I/O.
    private func logTouchDiagnostic(viewPoint p: CGPoint, fb: (x: Int32, y: Int32)) {
        guard let fit = fitTransform() else { return }
        let rect = fit.contentRect
        let ds = metalLayer.drawableSize
        let dbg = "p=(\(Int(p.x)),\(Int(p.y))) bounds=\(Int(bounds.width))x\(Int(bounds.height)) "
            + "fb=\(fbWidth)x\(fbHeight) drawable=\(Int(ds.width))x\(Int(ds.height)) "
            + "cs=\(metalLayer.contentsScale) zoom=\(zoomScale) pan=(\(Int(panOffset.x)),\(Int(panOffset.y))) "
            + "rect=(\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))) "
            + "fitScale=\(fit.scale) -> fb=(\(fb.x),\(fb.y))\n"
        try? dbg.write(toFile: XiosRuntimePaths.tmp("xios-touch.log"), atomically: true, encoding: .utf8)
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
        let nextSize = fitTransform(zoom: nextZoom, pan: .zero)?.contentRect.size ?? oldRect.size
        let nextPan = CGPoint(
            x: anchor.x - bounds.midX + nextSize.width * (0.5 - ux),
            y: anchor.y - bounds.midY + nextSize.height * (0.5 - uy))
        zoomScale = nextZoom
        panOffset = clampedPanOffset(nextPan, zoom: nextZoom)
        needsPresent = true
    }

    private func resetZoom() {
        zoomScale = minZoomScale
        panOffset = .zero
        scrollRemainder = .zero
        needsPresent = true
    }

    /// dx/dy are view-point finger deltas. iosc gets AXIS records in 1/256
    /// framebuffer-pixel fixed point with wl_pointer's sign (natural scroll:
    /// fingers up = content scrolls down the page = positive); XTEST keeps
    /// wheel-click emulation for plain X11 input.
    private func sendScroll(dx: CGFloat, dy: CGFloat) {
        guard inputConnected else { return }
        if usingIosc {
            guard let fit = fitTransform(), fit.scale > 0 else { return }
            let ptToFb = 256 / fit.scale
            axisRemainder.x -= dx * ptToFb
            axisRemainder.y -= dy * ptToFb
            let sx = axisRemainder.x.rounded(.towardZero)
            let sy = axisRemainder.y.rounded(.towardZero)
            if sx != 0 || sy != 0 {
                axisRemainder.x -= sx
                axisRemainder.y -= sy
                iosc_input_axis(Int32(sx), Int32(sy), 0, 0, false)
                axisActive = true
            }
            return
        }
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

    /// Fingers left the glass: end the axis gesture so clients kinetic-fling.
    private func sendScrollStop() {
        axisRemainder = .zero
        guard axisActive else { return }
        axisActive = false
        if inputConnected && usingIosc { iosc_input_axis(0, 0, 0, 0, true) }
    }

    private func suppressCursorOverlayForTouch() {
        hardwarePointerActive = false
        cursorLayer?.isHidden = true
    }

    private func suppressCursorOverlayForTouchFirstInput(_ touches: Set<UITouch>) {
        if touches.contains(where: { $0.type == .direct || $0.type == .pencil }) {
            suppressCursorOverlayForTouch()
        }
    }

    private func activateCursorOverlayForHardwarePointer() {
        if !hardwarePointerActive {
            hardwarePointerActive = true
            lastCursorSeq = 0
        }
    }

    @available(iOS 13.4, *)
    @objc private func handlePointerHover(_ g: UIHoverGestureRecognizer) {
        activateCursorOverlayForHardwarePointer()
        guard inputConnected, let (x, y) = framebufferPoint(from: g.location(in: self)) else { return }
        lastTouchPt = (x, y)
        sendMotion(x, y)
    }

    @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
        switch g.state {
        case .began:
            twoFingerBegan()
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
            twoFingerEnded()
        default:
            break
        }
    }

    @objc private func handleTwoFingerPan(_ g: UIPanGestureRecognizer) {
        let isWheel = g.numberOfTouches == 0   // trackpad/wheel scroll events
        switch g.state {
        case .began:
            twoFingerBegan()
            panStartOffset = panOffset
            panLastTranslation = .zero
            scrollRemainder = .zero
            axisRemainder = .zero
        case .changed:
            let t = g.translation(in: self)
            if zoomScale > 1.01 {
                panOffset = clampedPanOffset(
                    CGPoint(x: panStartOffset.x + t.x, y: panStartOffset.y + t.y),
                    zoom: zoomScale)
                needsPresent = true
            } else {
                if twoFingerMode == .undecided, isWheel || abs(t.x) + abs(t.y) > 12 {
                    twoFingerMode = .scroll
                    if let (x, y) = framebufferPoint(from: g.location(in: self)) {
                        lastTouchPt = (x, y)
                        sendMotion(x, y)   // focus the surface under the fingers
                    }
                }
                if twoFingerMode == .scroll {
                    sendScroll(dx: t.x - panLastTranslation.x,
                               dy: t.y - panLastTranslation.y)
                }
            }
            panLastTranslation = t
        default:
            sendScrollStop()
            panLastTranslation = .zero
            scrollRemainder = .zero
            twoFingerEnded()
        }
    }

    private func twoFingerBegan() {
        twoFingerActive += 1
        if twoFingerActive == 1 { twoFingerMode = .undecided }
        cancelPendingPress()   // two fingers on glass: never a click or hold
    }

    private func twoFingerEnded() {
        twoFingerActive = max(0, twoFingerActive - 1)
        if twoFingerActive == 0 { twoFingerMode = .undecided }
    }

    @objc private func handleTwoFingerTap(_ g: UITapGestureRecognizer) {
        guard inputConnected, let (x, y) = framebufferPoint(from: g.location(in: self)) else { return }
        lastTouchPt = (x, y)
        sendMotion(x, y)
        sendButton(3, true, at: (x, y))
        sendButton(3, false, at: (x, y))
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
            cancelPendingPress()
            releaseLeftPress()
            _ = becomeFirstResponder()
        case .ended, .cancelled, .failed:
            keyboardSwipeTriggered = false
        default:
            break
        }
    }

    @objc private func handleShellOverlayRevealPan(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began:
            shellOverlaySwipeTriggered = false
            cancelPointerInteraction()
        case .changed:
            guard !shellOverlaySwipeTriggered else { return }
            let t = g.translation(in: self)
            guard t.y > 28, abs(t.y) > abs(t.x) * 1.25 else { return }
            shellOverlaySwipeTriggered = true
            showShellOverlayTemporarily(animated: true)
        case .ended, .cancelled, .failed:
            shellOverlaySwipeTriggered = false
        default:
            break
        }
    }

    // MARK: iosc real multitouch + Apple Pencil (wire types XIOS_IN_TOUCH/XIOS_IN_TABLET)

    /// The touch/tablet records default to ADDITIVE pointer fallback, but KDE/Qt
    /// Quick activates on both wl_touch and the emulated wl_pointer click. For
    /// direct finger touches in those sessions, consume the pointer emulation so
    /// one physical tap produces one desktop action.
    /// Stable per-touch slot ids (0..9), assigned on began, freed on ended/cancelled.
    private var touchSlots: [UITouch: Int32] = [:]

    private func touchSlot(for t: UITouch) -> Int32 {
        if let s = touchSlots[t] { return s }
        var s: Int32 = 0
        while touchSlots.values.contains(s) { s += 1 }
        touchSlots[t] = s
        return s
    }

    private func ioscPoint(_ t: UITouch) -> (Int32, Int32)? {
        framebufferPoint(from: t.location(in: self)) ?? lastTouchPt
    }

    /// Forward one UITouch to iosc as touch (finger) or tablet (Pencil) events.
    /// Returns whether anything was forwarded (only false off-iosc).
    /// phase: 0 up, 1 down, 2 motion, 3 cancel (the wire's phase encoding).
    private func forwardIosc(_ t: UITouch, phase: Int32, event: UIEvent?) -> Bool {
        guard usingIosc, inputConnected else { return false }
        if t.type == .pencil {
            if phase == 0 || phase == 3 {          // iosc ignores coords on up/cancel
                let p = ioscPoint(t) ?? (0, 0)
                iosc_input_tablet(phase, p.0, p.1, 0, 0, 0)
                return true
            }
            // Coalesced touches carry the full 240Hz Pencil sample train.
            let samples = (phase == 2 ? event?.coalescedTouches(for: t) : nil) ?? [t]
            for s in samples {
                guard let (x, y) = ioscPoint(s) else { continue }
                lastTouchPt = (x, y)
                let force = s.maximumPossibleForce > 0
                    ? Double(s.force / s.maximumPossibleForce) : 1.0
                let mag = 90.0 - Double(s.altitudeAngle) * 180.0 / .pi  // 0 = pen vertical
                let az = Double(s.azimuthAngle(in: self))
                iosc_input_tablet(phase, x, y,
                                  UInt32((force * 65535.0).rounded()),
                                  Int32((mag * cos(az)).rounded()),
                                  Int32((mag * sin(az)).rounded()))
            }
            return true
        }
        let slot = touchSlot(for: t)
        if phase == 0 || phase == 3 { touchSlots[t] = nil }
        guard let (x, y) = ioscPoint(t) else {
            // Outside the framebuffer: still deliver up/cancel so iosc frees the id.
            if phase == 0 || phase == 3 { iosc_input_touch(slot, phase, 0, 0) }
            return true
        }
        lastTouchPt = (x, y)
        iosc_input_touch(slot, phase, x, y)
        return true
    }

    private func forwardIoscAll(_ touches: Set<UITouch>, phase: Int32, event: UIEvent?) -> Bool {
        var handled = false
        for t in touches where forwardIosc(t, phase: phase, event: event) { handled = true }
        return handled
    }

    private func allTouchesEndedOrCancelled(_ event: UIEvent?) -> Bool {
        guard let all = event?.allTouches, !all.isEmpty else { return true }
        return all.allSatisfy { $0.phase == .ended || $0.phase == .cancelled }
    }

    /// Release the emulated left button if it is down (guarded, idempotent).
    private func releaseLeftPress() {
        if inputConnected && leftPressSent {
            sendButton(1, false, at: lastTouchPt)
            leftPressSent = false
        }
    }

    private func cancelPointerInteraction() {
        cancelPendingPress()
        longPressFired = false
        releaseLeftPress()
    }

    private func beginAppGestureSuppression(event: UIEvent?) {
        appGestureTouchSuppression = true
        cancelPointerInteraction()
        if usingIosc, inputConnected, let all = event?.allTouches {
            for t in all { _ = forwardIosc(t, phase: 3, event: event) }
            touchSlots.removeAll()
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        suppressCursorOverlayForTouchFirstInput(touches)
        if appGestureTouchSuppression { return }
        if (event?.allTouches?.count ?? touches.count) >= 3 {
            beginAppGestureSuppression(event: event)
            return
        }
        let touchConsumesPointer = shouldTouchReplacePointer(for: touches)
        if forwardIoscAll(touches, phase: 1, event: event) {
            activeTouchReplacesPointer = touchConsumesPointer
            if touchConsumesPointer { return }
        }
        guard (event?.allTouches?.count ?? touches.count) == 1 else {
            cancelPendingPress()   // a second finger means gesture, not click
            return
        }
        guard inputConnected, let t = touches.first,
              let (x, y) = framebufferPoint(from: t.location(in: self)) else { return }
        lastTouchPt = (x, y)
        longPressFired = false
        if t.type == .direct {
            // Finger: defer the press so a still hold can become a right click.
            pendingPress = (x, y)
            pendingPressViewPoint = t.location(in: self)
            pendingPressTimer?.invalidate()
            pendingPressTimer = Timer.scheduledTimer(withTimeInterval: Self.longPressSeconds,
                                                     repeats: false) { [weak self] _ in
                self?.fireLongPress()
            }
        } else {
            // Pencil / trackpad: press immediately, no long-press synthesis.
            logTouchDiagnostic(viewPoint: t.location(in: self), fb: (x, y))
            sendMotion(x, y); sendButton(1, true, at: (x, y))
            leftPressSent = true
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        suppressCursorOverlayForTouchFirstInput(touches)
        if appGestureTouchSuppression { return }
        if forwardIoscAll(touches, phase: 2, event: event) && activeTouchReplacesPointer { return }
        guard (event?.allTouches?.count ?? touches.count) == 1,
              inputConnected, let t = touches.first,
              let (x, y) = framebufferPoint(from: t.location(in: self)) else { return }
        if longPressFired { return }          // the hold became a right click
        if pendingPress != nil {
            let l = t.location(in: self)
            if hypot(l.x - pendingPressViewPoint.x,
                     l.y - pendingPressViewPoint.y) < Self.longPressSlopPt { return }
            flushPendingPress()               // it moved: press at the origin
        }
        lastTouchPt = (x, y)
        sendMotion(x, y)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        suppressCursorOverlayForTouchFirstInput(touches)
        if appGestureTouchSuppression {
            if allTouchesEndedOrCancelled(event) { appGestureTouchSuppression = false }
            return
        }
        if forwardIoscAll(touches, phase: 0, event: event) && activeTouchReplacesPointer {
            if allTouchesEndedOrCancelled(event) { activeTouchReplacesPointer = false }
            return
        }
        guard inputConnected else { cancelPendingPress(); longPressFired = false; return }
        if longPressFired { longPressFired = false; return }
        if pendingPress != nil { flushPendingPress() }   // stationary tap = click
        releaseLeftPress()
        if allTouchesEndedOrCancelled(event) { activeTouchReplacesPointer = false }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        suppressCursorOverlayForTouchFirstInput(touches)
        if appGestureTouchSuppression {
            if allTouchesEndedOrCancelled(event) {
                appGestureTouchSuppression = false
                touchSlots.removeAll()
                activeTouchReplacesPointer = false
            }
            return
        }
        if forwardIoscAll(touches, phase: 3, event: event) && activeTouchReplacesPointer {
            if allTouchesEndedOrCancelled(event) { activeTouchReplacesPointer = false }
            return
        }
        cancelPointerInteraction()
        if allTouchesEndedOrCancelled(event) { activeTouchReplacesPointer = false }
    }

    // MARK: deferred press helpers

    private func cancelPendingPress() {
        pendingPressTimer?.invalidate()
        pendingPressTimer = nil
        pendingPress = nil
    }

    /// Commit the deferred left press at its original point (drag start / tap).
    private func flushPendingPress() {
        guard let p = pendingPress else { return }
        cancelPendingPress()
        logTouchDiagnostic(viewPoint: pendingPressViewPoint, fb: p)
        sendMotion(p.x, p.y)
        sendButton(1, true, at: (p.x, p.y))
        leftPressSent = true
    }

    private func fireLongPress() {
        guard let p = pendingPress, inputConnected else { cancelPendingPress(); return }
        cancelPendingPress()
        longPressFired = true
        logTouchDiagnostic(viewPoint: pendingPressViewPoint, fb: p)
        // Physical confirmation the hold promoted (no-op without a Taptic
        // Engine, e.g. iPad 7).
        SystemIntegration.shared.rightClickHaptic()
        // Touch-and-hold = secondary click; GNOME/GTK open their context menus.
        sendMotion(p.x, p.y)
        sendButton(3, true, at: (p.x, p.y))
        sendButton(3, false, at: (p.x, p.y))
    }

    // MARK: display discovery + picker

    /// One visible desktop target. Legacy X displays come from X<n> sockets; slot
    /// displays come from xios-displays.d and carry their own xios-<slot>.json.
    private struct XDisplayInfo {
        let number: Int
        let config: [String: Any]?
        let configPath: String?
        let slot: String?
        let preset: String?
        let state: String?
        let wayland: String?
        var displayStr: String { ":\(number)" }
        var renderable: Bool { config != nil }
    }

    private func readConfig(path: String? = nil) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path ?? configPath),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    private func discoverDisplaySlots() -> [XDisplayInfo] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: displayRegistryDir) else { return [] }
        return entries.sorted().compactMap { entry in
            guard entry.hasSuffix(".json") else { return nil }
            let registryPath = "\(displayRegistryDir)/\(entry)"
            guard let data = fm.contents(atPath: registryPath),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            let jsonPath = obj["json"] as? String
            let cfg = jsonPath.flatMap { readConfig(path: $0) }
            let display = (cfg?["display"] as? String) ?? ""
            let number = display.hasPrefix(":") ? (Int(display.dropFirst()) ?? -1) : -1
            return XDisplayInfo(
                number: number,
                config: cfg,
                configPath: jsonPath,
                slot: obj["slot"] as? String,
                preset: obj["preset"] as? String,
                state: obj["state"] as? String,
                wayland: obj["wayland"] as? String)
        }
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
        var rows = numbers.sorted().map {
            XDisplayInfo(number: $0, config: $0 == cfgNumber ? cfg : nil,
                         configPath: $0 == cfgNumber ? configPath : nil,
                         slot: nil, preset: nil, state: nil, wayland: nil)
        }
        let seenPaths = Set(rows.compactMap { $0.configPath })
        rows.append(contentsOf: discoverDisplaySlots().filter { row in
            guard let path = row.configPath else { return true }
            return !seenPaths.contains(path)
        })
        return rows
    }

    // MARK: installed-app enumeration (freedesktop .desktop entries)

    private struct DesktopApp {
        let name: String    // display name (Name= or filename)
        let exec: String    // cleaned Exec= (field codes stripped), what we launch
        let icon: String    // Icon= name/path, used by desktop pins
        let id: String      // .desktop basename, for stable identity / dedupe
    }

    private let applicationsDirs = [
        XiosRuntimePaths.prefixed("/usr/share/applications"),
        XiosRuntimePaths.prefixed("/usr/local/share/applications"),
    ]

    /// Parse the `[Desktop Entry]` group of a .desktop file into the fields we need.
    /// Only the first group is read (later `[Desktop Action …]` groups are ignored),
    /// and only unlocalized keys (`Name=`, not `Name[de]=`) are taken.
    private func parseDesktopEntry(_ path: String) -> DesktopApp? {
        let raw: String
        if let utf8 = try? String(contentsOfFile: path, encoding: .utf8) {
            raw = utf8
        } else if let latin1 = try? String(contentsOfFile: path, encoding: .isoLatin1) {
            raw = latin1
        } else {
            return nil
        }
        var name = "", exec = "", icon = "", type = ""
        var noDisplay = false, hidden = false
        var inEntry = false
        for lineSub in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = lineSub.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") {
                inEntry = (line == "[Desktop Entry]")
                if !inEntry && !name.isEmpty { break }   // past the main group; done
                continue
            }
            guard inEntry, let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq])
            let val = String(line[line.index(after: eq)...])
            switch key {
            case "Name":      if name.isEmpty { name = val }
            case "Exec":      if exec.isEmpty { exec = val }
            case "Icon":      if icon.isEmpty { icon = val }
            case "Type":      type = val
            case "NoDisplay": noDisplay = (val.lowercased() == "true")
            case "Hidden":    hidden = (val.lowercased() == "true")
            default: break    // ignore Name[xx], Icon, Categories, etc.
            }
        }
        guard type == "Application", !noDisplay, !hidden else { return nil }
        let cleaned = cleanExec(exec)
        guard !cleaned.isEmpty else { return nil }
        let id = (path as NSString).lastPathComponent
        return DesktopApp(name: name.isEmpty ? id : name, exec: cleaned, icon: icon, id: id)
    }

    /// Strip freedesktop Exec field codes (%f %F %u %U %i %c %k %d %D %n %N %v %m) so
    /// the remainder is a runnable command. `%%` collapses to a literal `%`.
    private func cleanExec(_ exec: String) -> String {
        let drop: Set<Character> = ["f", "F", "u", "U", "i", "c", "k",
                                    "d", "D", "n", "N", "v", "m"]
        var out = "", it = exec.makeIterator()
        var pending: Character? = nil
        while let ch = pending ?? it.next() {
            pending = nil
            if ch == "%", let nxt = it.next() {
                if nxt == "%" { out.append("%") }
                else if drop.contains(nxt) { /* skip field code */ }
                else { out.append(ch); pending = nxt }
                continue
            }
            out.append(ch)
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// Enumerate installed GUI apps from the applications dirs, deduped by name and
    /// sorted case-insensitively. Settings sub-panels, URI handlers and background
    /// services drop out because they carry `NoDisplay=true`.
    private func discoverDesktopApps() -> [DesktopApp] {
        let fm = FileManager.default
        var byName: [String: DesktopApp] = [:]
        for dir in applicationsDirs {
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for e in entries where e.hasSuffix(".desktop") {
                guard let app = parseDesktopEntry("\(dir)/\(e)") else { continue }
                let key = app.name.lowercased()
                if byName[key] == nil { byName[key] = app }   // first dir wins
            }
        }
        return byName.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private let desktopPinsPath = "/var/mobile/Library/Preferences/com.max.iosc-desktop-pins.conf"

    private func desktopPinField(_ value: String) -> String {
        value.replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    private func pinAppToDesktop(_ app: DesktopApp) {
        let fm = FileManager.default
        let dir = (desktopPinsPath as NSString).deletingLastPathComponent
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let existing = (try? String(contentsOfFile: desktopPinsPath, encoding: .utf8)) ?? ""
        if existing.split(separator: "\n").contains(where: { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            return fields.count >= 4 && String(fields[3]) == app.exec
        }) {
            lastToolMessage = "\(app.name) is already pinned"
            return
        }
        let slot = existing.split(separator: "\n").count
        let x = 300 + (slot % 6) * 104
        let y = 96 + (slot / 6) * 122
        let line = [
            "app",
            desktopPinField(app.name),
            desktopPinField(app.icon),
            desktopPinField(app.exec),
            String(x),
            String(y),
        ].joined(separator: "\t") + "\n"
        if !fm.fileExists(atPath: desktopPinsPath) {
            fm.createFile(atPath: desktopPinsPath, contents: nil)
        }
        guard let handle = FileHandle(forWritingAtPath: desktopPinsPath),
              let data = line.data(using: .utf8) else {
            lastToolMessage = "Could not pin \(app.name)"
            return
        }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
        } catch {
            lastToolMessage = "Could not pin \(app.name)"
            return
        }
        handle.write(data)
        lastToolMessage = "Pinned \(app.name) to desktop"
    }

    private func resetConfigDefaults(resetDisplay: Bool = false) {
        fbWidth = 1024; fbHeight = 768
        ddxIsIOSurface = false
        ddxSockPath = XiosRuntimePaths.tmp("xios-ddx.sock")
        xAuthPath = nil
        ioscInputSock = nil
        ioscClipboardSock = nil
        if resetDisplay { xDisplay = ":3" }
    }

    /// Drop every connection tied to the current display so we can load another.
    private func teardownConnections() {
        closeInput()
        if let c = xconn { xsurface_close(c); xconn = nil }
        removeCursorOverlay()
        iosTexture = nil; usingIOSurface = false; iosConnectStarted = false; needsPresent = false
        testBuf?.deallocate(); testBuf = nil
        usingTestPattern = false
        resetZoom()
    }

    /// Switch to a display the user picked: tear down the old one, apply the new
    /// config (or none, for input-only), and start its framebuffer + input path.
    private func load(_ disp: XDisplayInfo) {
        userPinned = true
        selectedConfigPath = disp.configPath
        teardownConnections()
        loadGeneration += 1
        resetConfigDefaults()
        if disp.number >= 0 { xDisplay = disp.displayStr }

        if disp.renderable {
            _ = loadConfig()             // re-read the configured display's json
            if disp.number >= 0 { xDisplay = disp.displayStr }   // keep picked X display if any
            if ddxIsIOSurface {
                startTestPattern()
                startIOSurfaceConnect()
            } else {
                awaitingCompositor = true
                startTestPattern()
            }
        } else {
            startTestPattern()           // input-only: no framebuffer for this display
        }
        connectInput()
        writeStatus()
    }

    // MARK: picker chrome

    private func installChrome() {
        let displayTap = UITapGestureRecognizer(target: self, action: #selector(openPicker))
        displayTap.numberOfTouchesRequired = 3
        displayTap.delegate = self
        addGestureRecognizer(displayTap)

        let sessionTap = UITapGestureRecognizer(target: self, action: #selector(openSessionPicker))
        sessionTap.numberOfTouchesRequired = 4
        sessionTap.delegate = self
        addGestureRecognizer(sessionTap)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self
        addGestureRecognizer(pinch)

        let keyboardPan = UIPanGestureRecognizer(target: self, action: #selector(handleKeyboardRevealPan(_:)))
        keyboardPan.minimumNumberOfTouches = 1
        keyboardPan.maximumNumberOfTouches = 1
        keyboardPan.cancelsTouchesInView = true
        keyboardPan.delegate = self
        addGestureRecognizer(keyboardPan)
        keyboardRevealPan = keyboardPan

        let overlayPan = UIPanGestureRecognizer(target: self, action: #selector(handleShellOverlayRevealPan(_:)))
        overlayPan.minimumNumberOfTouches = 1
        overlayPan.maximumNumberOfTouches = 1
        overlayPan.cancelsTouchesInView = true
        overlayPan.delegate = self
        addGestureRecognizer(overlayPan)
        shellOverlayRevealPan = overlayPan

        let twoFingerPan = UIPanGestureRecognizer(target: self, action: #selector(handleTwoFingerPan(_:)))
        twoFingerPan.minimumNumberOfTouches = 2
        twoFingerPan.maximumNumberOfTouches = 2
        twoFingerPan.delegate = self
        addGestureRecognizer(twoFingerPan)

        // Trackpad / Magic-Keyboard two-finger scrolling arrives as scroll events
        // (no touches), which the two-touch pan above never sees; a dedicated
        // recognizer feeds the same handler.
        let wheelPan = UIPanGestureRecognizer(target: self, action: #selector(handleTwoFingerPan(_:)))
        wheelPan.allowedScrollTypesMask = .continuous
        wheelPan.allowedTouchTypes = []
        wheelPan.maximumNumberOfTouches = 0
        wheelPan.delegate = self
        addGestureRecognizer(wheelPan)

        let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerTap(_:)))
        twoFingerTap.numberOfTouchesRequired = 2
        twoFingerTap.delegate = self
        addGestureRecognizer(twoFingerTap)

        if #available(iOS 13.4, *) {
            let hover = UIHoverGestureRecognizer(target: self, action: #selector(handlePointerHover(_:)))
            hover.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
            hover.delegate = self
            addGestureRecognizer(hover)
        }

        addInteraction(UIContextMenuInteraction(delegate: self))
    }

    private func installShellOverlay() {
        if shellOverlay != nil { return }
        let overlay = XiosShellOverlay()
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.openSessions = { [weak self] in self?.presentDisplayControl(initial: .sessions) }
        overlay.fitDisplay = { [weak self] in
            guard let self else { return }
            self.resetZoom()
            self.lastToolMessage = "Fit current display"
            self.refreshShellOverlay()
        }
        overlay.reloadDisplay = { [weak self] in
            guard let self else { return }
            self.reloadRuntimeConfig()
            self.lastToolMessage = "Reloaded xios.json"
            self.refreshShellOverlay()
        }
        overlay.reconnectInput = { [weak self] in
            guard let self else { return }
            self.reconnectInput()
            self.lastToolMessage = "Reconnected \(self.inputBackendName())"
            self.refreshShellOverlay()
        }
        overlay.openTools = { [weak self] in self?.presentTools() }
        overlay.dismissOverlay = { [weak self] in self?.hideShellOverlay(animated: true) }
        addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: topAnchor),
            overlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            overlay.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        shellOverlay = overlay
        refreshShellOverlay()
        scheduleShellOverlayAutoHide()
    }

    private func refreshShellOverlay() {
        guard let overlay = shellOverlay else { return }
        let preset = sessionStatus()?.preset ?? iosurfaceCompositorID
        let state = sessionStatus()?.state ?? (usingIOSurface ? "up" : "waiting")
        let label = preset.isEmpty ? "Xios" : desktopLabel(preset)
        let backend = usingIOSurface ? "Metal" : "Waiting"
        let input = inputConnected ? inputBackendName() : "input offline"
        overlay.update(
            session: "\(label)  \(state)",
            detail: "\(fbWidth)x\(fbHeight)  \(backend)  \(input)",
            healthy: usingIOSurface && inputConnected)
    }

    private func scheduleShellOverlayAutoHide() {
        shellOverlayAutoHideTimer?.invalidate()
        shellOverlayAutoHideTimer = Timer.scheduledTimer(withTimeInterval: Self.shellOverlayAutoHideDelay,
                                                         repeats: false) { [weak self] _ in
            guard let self else { return }
            self.shellOverlayAutoHideTimer = nil
            self.hideShellOverlay(animated: true)
        }
    }

    private func hideShellOverlay(animated: Bool) {
        shellOverlayAutoHideTimer?.invalidate()
        shellOverlayAutoHideTimer = nil
        shellOverlay?.setChromeVisible(false, animated: animated)
    }

    private func showShellOverlayTemporarily(animated: Bool) {
        guard let overlay = shellOverlay else { return }
        refreshShellOverlay()
        overlay.setChromeVisible(true, animated: animated)
        scheduleShellOverlayAutoHide()
    }

    private enum DisplayControlFocus { case displays, sessions }

    @objc private func openPicker() { presentDisplayControl(initial: .displays) }

    @objc private func openSessionPicker() { presentDisplayControl(initial: .sessions) }

    private func fetchLauncherApps() -> (apps: [LauncherApp], error: String?) {
        guard let lines = ioscdResponseLines("APPS_LIST\n") else {
            return ([], "ioscd socket unavailable")
        }
        var apps: [LauncherApp] = []
        for line in lines {
            if line.hasPrefix("ERR ") { return (apps, line) }
            if line.hasPrefix("APPS_END") { break }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 6 else { continue }
            apps.append(LauncherApp(
                id: String(fields[0]),
                name: String(fields[1]),
                exec: String(fields[2]),
                icon: String(fields[3]),
                bundlePath: String(fields[4]),
                enabled: String(fields[5]).lowercased() != "disabled"))
        }
        apps.sort {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        return (apps, nil)
    }

    private func sendLauncherToggle(_ app: LauncherApp, enabled: Bool) -> Bool {
        let verb = enabled ? "APP_ENABLE" : "APP_DISABLE"
        guard let lines = ioscdResponseLines("\(verb)\t\(app.id)\n"),
              let last = lines.last else {
            lastToolMessage = "Launcher update failed: ioscd socket unavailable"
            return false
        }
        if last == "APPS_END\t0" {
            lastToolMessage = "\(enabled ? "Enabled" : "Disabled") \(app.name)"
            return true
        }
        lastToolMessage = "Launcher update failed: \(lines.first ?? last)"
        return false
    }

    private func sendLauncherSync(native: Bool, dryRun: Bool) -> [String]? {
        let mode = native ? "native" : "classic"
        let dry = dryRun ? "dry" : "apply"
        guard let lines = ioscdResponseLines("APPS_SYNC\t\(mode)\t\(dry)\n") else {
            lastToolMessage = "Launcher sync failed: ioscd socket unavailable"
            return nil
        }
        let ok = lines.last == "APPS_END\t0"
        lastToolMessage = "\(dryRun ? "Dry run" : "Synced") \(mode) launchers\(ok ? "" : " with errors")"
        return lines
    }

    /// Parse the session launcher's status file (preset / state / human message). nil when the
    /// file is absent or unparseable. State walks stopping → starting → waiting →
    /// relaunching → up (or error / compositor-only).
    private func sessionStatus() -> SessionStatus? {
        guard let data = FileManager.default.contents(atPath: sessionStatusPath),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return SessionStatus(
            preset: obj["preset"] as? String ?? "?",
            state: obj["state"] as? String ?? "?",
            message: obj["message"] as? String ?? "",
            width: obj["width"] as? Int,
            height: obj["height"] as? Int,
            display: obj["display"] as? String,
            ddx: obj["ddx"] as? String)
    }

    /// One-line "preset: state — message" for the picker card.
    private func sessionStatusText() -> String {
        guard let s = sessionStatus() else { return "No session started yet" }
        let geom = (s.width != nil && s.height != nil) ? "  \(s.width!)x\(s.height!)" : ""
        let display = s.display.map { "  \($0)" } ?? ""
        return "\(s.preset): \(s.state)\(geom)\(display)" + (s.message.isEmpty ? "" : " — \(s.message)")
    }

    /// The human message for the full-screen banner: the daemon's message verbatim when
    /// present, else a phrase derived from the state (so a blank message still reads as
    /// progress rather than a dark screen).
    private func sessionBannerText() -> String {
        guard let s = sessionStatus() else { return "Switching desktop…" }
        if !s.message.isEmpty { return s.message }
        switch s.state {
        case "stopping":       return "Stopping \(s.preset)…"
        case "starting":       return "Starting \(s.preset)…"
        case "waiting":        return "Waiting for compositor surface…"
        case "relaunching":    return "Relaunching display…"
        case "up":             return "\(s.preset) ready"
        case "compositor-only": return "\(s.preset) up — reconnecting display…"
        case "error":          return "Session error"
        default:               return "\(s.preset): \(s.state)"
        }
    }

    private func ensureSessionBanner() -> UILabel {
        if let b = sessionBanner { return b }
        let b = UILabel()
        b.font = .systemFont(ofSize: 15, weight: .semibold)
        b.textColor = .white
        b.textAlignment = .center
        b.backgroundColor = UIColor.black.withAlphaComponent(0.72)
        b.layer.cornerRadius = 12
        b.layer.masksToBounds = true
        b.numberOfLines = 1
        b.adjustsFontSizeToFitWidth = true
        b.minimumScaleFactor = 0.7
        b.translatesAutoresizingMaskIntoConstraints = false
        addSubview(b)
        NSLayoutConstraint.activate([
            b.centerXAnchor.constraint(equalTo: centerXAnchor),
            b.centerYAnchor.constraint(equalTo: centerYAnchor),
            b.heightAnchor.constraint(equalToConstant: 44),
            b.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.8),
        ])
        sessionBanner = b
        return b
    }

    /// Poll the launcher's status file at 0.5s while a flavor switch is in flight (a pick,
    /// or a mid-session surface loss). Feeds BOTH the picker card line and — once the
    /// picker is dismissed and there's no live desktop to look at — a full-screen banner,
    /// so the switch reads as "starting mutter / waiting for compositor / relaunching"
    /// instead of a dark screen. Stops when a live surface is presenting again at "up",
    /// or after a 60s backstop.
    private func startSessionIndicator() {
        sessionIndicatorDeadline = Date().addingTimeInterval(60)
        sessionIndicatorSawTransition = false
        updateSessionIndicator()
        if sessionIndicatorTimer != nil { return }
        sessionIndicatorTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            self.updateSessionIndicator()
            if self.sessionIndicatorTimer == nil { t.invalidate() }
        }
    }

    private func updateSessionIndicator() {
        let state = sessionStatus()?.state ?? ""
        sessionStatusLabel?.text = sessionStatusText()          // picker card, if open
        // Don't treat a stale "up" (from before the pick landed) as settled — only stop
        // after we've actually seen the switch move (a transient state or a surface loss).
        if awaitingCompositor || (!state.isEmpty && state != "up") {
            sessionIndicatorSawTransition = true
        }
        let presenting = usingIOSurface && !awaitingCompositor
        let settled = sessionIndicatorSawTransition && presenting && state == "up"
        if settled || Date() > sessionIndicatorDeadline {
            stopSessionIndicator(); return
        }
        // Full-screen banner only when there's no live desktop AND the picker card isn't
        // already showing the status.
        if !presenting && pickerOverlay == nil {
            let b = ensureSessionBanner()
            b.text = "   " + sessionBannerText() + "   "
            b.isHidden = false
            bringSubviewToFront(b)
        } else {
            sessionBanner?.isHidden = true
        }
    }

    private func stopSessionIndicator() {
        sessionIndicatorTimer?.invalidate()
        sessionIndicatorTimer = nil
        sessionBanner?.isHidden = true
    }

    private func presentScrollableModalCard(maxWidth: CGFloat = 620) -> (overlay: UIView,
                                                                         card: UIView,
                                                                         scroll: UIScrollView,
                                                                         stack: UIStackView) {
        let (overlay, card) = presentModalCard()

        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = true
        card.addSubview(scroll)

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)

        let desiredWidth = card.widthAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.widthAnchor,
                                                       multiplier: 0.72)
        desiredWidth.priority = .defaultHigh
        let minWidth = card.widthAnchor.constraint(greaterThanOrEqualToConstant: 380)
        minWidth.priority = .defaultHigh
        let height = card.heightAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.heightAnchor,
                                                  multiplier: 0.86)
        height.priority = .defaultHigh

        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
            desiredWidth,
            minWidth,
            card.widthAnchor.constraint(lessThanOrEqualToConstant: maxWidth),
            card.widthAnchor.constraint(lessThanOrEqualTo: overlay.safeAreaLayoutGuide.widthAnchor,
                                        constant: -32),
            height,
            card.heightAnchor.constraint(lessThanOrEqualTo: overlay.safeAreaLayoutGuide.heightAnchor,
                                         constant: -32),
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

        return (overlay, card, scroll, stack)
    }

    private func currentDisplaySummary() -> String {
        let backend: String
        if usingIOSurface {
            backend = "IOSurface"
        } else if ddxIsIOSurface {
            backend = "waiting for IOSurface"
        } else {
            backend = "holding frame"
        }
        let input = inputConnected ? "\(inputBackendName()) input" : "input offline"
        return "\(xDisplay) / \(fbWidth)x\(fbHeight)\n\(backend) / \(input)"
    }

    private func currentDisplayTitle() -> String {
        selectedConfigPath == nil ? "Following Current" : "Pinned Display"
    }

    private func activeDesktopPreset() -> String? {
        guard let preset = sessionStatus()?.preset else { return nil }
        return ["iosc", "mutter", "gnome", "kde", "kde-nano", "kde-mobile"].contains(preset) ? preset : nil
    }

    private func desktopLabel(_ preset: String) -> String {
        desktopPresets.first { $0.preset == preset }?.title ?? preset
    }

    private func displayControlTabs(selected: DisplayControlFocus) -> UISegmentedControl {
        let tabs = UISegmentedControl(items: ["Displays", "Sessions"])
        tabs.selectedSegmentIndex = selected == .displays ? 0 : 1
        tabs.selectedSegmentTintColor = UIColor.systemBlue.withAlphaComponent(0.86)
        tabs.backgroundColor = UIColor(white: 0.18, alpha: 0.82)
        tabs.setTitleTextAttributes([.foregroundColor: UIColor(white: 0.78, alpha: 1),
                                     .font: UIFont.systemFont(ofSize: 13, weight: .semibold)],
                                    for: .normal)
        tabs.setTitleTextAttributes([.foregroundColor: UIColor.white,
                                     .font: UIFont.systemFont(ofSize: 13, weight: .bold)],
                                    for: .selected)
        tabs.heightAnchor.constraint(equalToConstant: 34).isActive = true
        tabs.addAction(UIAction { [weak self, weak tabs] _ in
            guard let self, let tabs else { return }
            self.presentDisplayControl(initial: tabs.selectedSegmentIndex == 0 ? .displays : .sessions)
        }, for: .valueChanged)
        return tabs
    }

    private func infoPanel(title: String, detail: String, iconName: String,
                           accent: UIColor) -> (view: UIView, detailLabel: UILabel) {
        let panel = UIStackView()
        panel.axis = .vertical
        panel.spacing = 5
        panel.isLayoutMarginsRelativeArrangement = true
        panel.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 11, leading: 12,
                                                                bottom: 11, trailing: 12)
        stylePanelSurface(panel, fill: UIColor(white: 0.16, alpha: 0.84), radius: 12)

        let titleRow = UIStackView()
        titleRow.axis = .horizontal
        titleRow.alignment = .center
        titleRow.spacing = 7

        let icon = UIImageView(image: UIImage(systemName: iconName))
        icon.tintColor = accent
        icon.contentMode = .scaleAspectFit
        icon.widthAnchor.constraint(equalToConstant: 17).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 17).isActive = true
        titleRow.addArrangedSubview(icon)

        let titleLabel = panelLabel(title, size: 12, weight: .semibold,
                                    color: UIColor(white: 0.90, alpha: 1))
        titleLabel.numberOfLines = 1
        titleRow.addArrangedSubview(titleLabel)
        panel.addArrangedSubview(titleRow)

        let detailLabel = panelLabel(detail, size: 12, color: UIColor(white: 0.72, alpha: 1))
        detailLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        panel.addArrangedSubview(detailLabel)
        return (panel, detailLabel)
    }

    private func addDisplayControlHeader(to stack: UIStackView,
                                         selected: DisplayControlFocus) -> UILabel {
        let titleRow = UIStackView()
        titleRow.axis = .horizontal
        titleRow.alignment = .center
        titleRow.spacing = 10

        let title = panelLabel("Displays & Sessions", size: 20, weight: .bold)
        title.numberOfLines = 1
        titleRow.addArrangedSubview(title)
        titleRow.addArrangedSubview(UIView())
        titleRow.addArrangedSubview(iconPanelButton("xmark", label: "Close") { [weak self] in
            self?.dismissPicker()
        })
        stack.addArrangedSubview(titleRow)
        stack.addArrangedSubview(displayControlTabs(selected: selected))

        let statusRow = UIStackView()
        statusRow.axis = .horizontal
        statusRow.spacing = 8
        statusRow.distribution = .fillEqually

        let displayAccent = usingIOSurface && inputConnected ? UIColor.systemGreen : UIColor.systemOrange
        statusRow.addArrangedSubview(infoPanel(title: currentDisplayTitle(),
                                               detail: currentDisplaySummary(),
                                               iconName: "display",
                                               accent: displayAccent).view)

        let session = infoPanel(title: "Session Status",
                                detail: sessionStatusText(),
                                iconName: "rectangle.3.group",
                                accent: UIColor.systemBlue)
        sessionStatusLabel = session.detailLabel
        statusRow.addArrangedSubview(session.view)
        stack.addArrangedSubview(statusRow)
        startSessionIndicator()

        let message = panelLabel(lastToolMessage, size: 12,
                                 color: UIColor(white: 0.70, alpha: 1))
        stack.addArrangedSubview(message)
        return message
    }

    private func addDisplayPanelContent(to stack: UIStackView, message: UILabel) {
        addSection("Open Displays", to: stack)
        let displays = discoverDisplays()
        if displays.isEmpty {
            stack.addArrangedSubview(emptyPanel("No displays or slots were found."))
        } else {
            for d in displays {
                stack.addArrangedSubview(makeRow(d))
            }
        }
        stack.addArrangedSubview(buttonRow([
            panelButton("Rescan") { [weak self] in self?.presentDisplayControl(initial: .displays) },
            panelButton(userPinned ? "Follow Current" : "Following Current") { [weak self] in
                guard let self else { return }
                self.userPinned = false
                self.selectedConfigPath = nil
                self.reloadRuntimeConfig()
                self.lastToolMessage = "Following xios.json"
                self.presentDisplayControl(initial: .displays)
            },
        ]))

        addSection("Display Controls", to: stack)
        stack.addArrangedSubview(buttonRow([
            panelButton("Fit") { [weak self] in
                self?.resetZoom()
                self?.lastToolMessage = "Fit current display"
                message.text = self?.lastToolMessage
            },
            panelButton("Reload") { [weak self] in
                guard let self else { return }
                self.reloadRuntimeConfig()
                self.lastToolMessage = "Reloaded xios.json"
                self.presentDisplayControl(initial: .displays)
            },
            panelButton("Reconnect Input") { [weak self] in
                guard let self else { return }
                self.reconnectInput()
                self.lastToolMessage = "Reconnected \(self.inputBackendName())"
                self.presentDisplayControl(initial: .displays)
            },
        ]))

        addMaintenanceActions(to: stack, message: message, includeStop: false)
    }

    private func addSessionPanelContent(to stack: UIStackView, message: UILabel) {
        let pick: (String, String?) -> Void = { [weak self, weak message] preset, app in
            guard let self else { return }
            self.writeSessionRequest(preset, app: app, display: self.pendingSessionDisplay)
            message?.text = self.lastToolMessage
        }

        addSessionSizeControls(to: stack)

        addSection("Desktop Sessions", to: stack)
        let currentPreset = activeDesktopPreset()
        let applyPreset = currentPreset ?? "iosc"
        stack.addArrangedSubview(detailPanelButton(
            title: "Apply Size to \(desktopLabel(applyPreset))",
            detail: sessionDisplaySummary(),
            iconName: "aspectratio") { pick("resize", nil) })
        for preset in desktopPresets {
            stack.addArrangedSubview(sessionPresetButton(preset, currentPreset: currentPreset, pick: pick))
        }

        addSection("New Display Slot", to: stack)
        let spawn: (String) -> Void = { [weak self, weak message] preset in
            guard let self else { return }
            let slot = self.newSessionSlot(for: preset)
            self.writeSessionRequest(preset, app: nil, display: self.pendingSessionDisplay, slot: slot)
            message?.text = self.lastToolMessage
        }
        stack.addArrangedSubview(buttonRow([
            panelButton("New iosc") { spawn("iosc") },
            panelButton("New KDE") { spawn("kde") },
            panelButton("New GNOME") { spawn("gnome") },
        ]))

        addSection("Launch App", to: stack)
        stack.addArrangedSubview(buttonRow(quickLaunchApps.map { app in
            detailPanelButton(title: app.title, detail: app.exec, iconName: app.iconName) {
                pick("app", app.exec)
            }
        }))
        stack.addArrangedSubview(detailPanelButton(
            title: "All Apps",
            detail: "Browse installed launchers",
            iconName: "square.grid.2x2") { [weak self] in
                self?.presentAppLauncher()
            })

        addSection("Home Screen Apps", to: stack)
        stack.addArrangedSubview(buttonRow([
            panelButton("Manage Apps") { [weak self] in self?.presentHomeScreenApps() },
            panelButton("Dry Run Native") { [weak self] in
                guard let self, let lines = self.sendLauncherSync(native: true, dryRun: true) else { return }
                self.presentLauncherSyncReport(title: "Native Dry Run", lines: lines)
            },
        ]))

        addMaintenanceActions(to: stack, message: message, includeStop: true)
    }

    private func addSessionSizeControls(to stack: UIStackView) {
        addSection("Size For Next Session", to: stack)
        stack.addArrangedSubview(infoPanel(title: "Selected Size",
                                           detail: sessionDisplaySummary(),
                                           iconName: "aspectratio",
                                           accent: UIColor.systemTeal).view)

        let defaults = sizeButton("Default", selected: pendingSessionDisplay == nil) { [weak self] in
            guard let self else { return }
            self.pendingSessionDisplay = nil
            self.presentDisplayControl(initial: .sessions)
        }
        let landscape = sizeButton("Landscape", selected: pendingSessionDisplay?.name == "Landscape") { [weak self] in
            guard let self else { return }
            self.pendingSessionDisplay = self.sessionDisplayProfiles[0]
            self.presentDisplayControl(initial: .sessions)
        }
        let portrait = sizeButton("Portrait", selected: pendingSessionDisplay?.name == "Portrait") { [weak self] in
            guard let self else { return }
            self.pendingSessionDisplay = self.sessionDisplayProfiles[1]
            self.presentDisplayControl(initial: .sessions)
        }
        let compact = sizeButton("Compact", selected: pendingSessionDisplay?.name == "Compact") { [weak self] in
            guard let self else { return }
            self.pendingSessionDisplay = self.sessionDisplayProfiles[2]
            self.presentDisplayControl(initial: .sessions)
        }
        stack.addArrangedSubview(buttonRow([defaults, landscape, portrait, compact]))
        stack.addArrangedSubview(panelButton("Custom Size") { [weak self] in
            self?.presentDisplayAdvancedPicker()
        })
    }

    private func sizeButton(_ title: String, selected: Bool,
                            action: @escaping () -> Void) -> UIButton {
        let button = panelButton(title, action)
        stylePanelToggle(button, on: selected)
        return button
    }

    private func sessionPresetButton(_ preset: DesktopPreset, currentPreset: String?,
                                     pick: @escaping (String, String?) -> Void) -> UIButton {
        let active = preset.preset == currentPreset
        let verb = active ? "Restart" : "Start"
        return detailPanelButton(title: "\(verb) \(preset.title)",
                                 detail: preset.detail,
                                 iconName: preset.iconName,
                                 fill: active ? UIColor.systemBlue.withAlphaComponent(0.34)
                                              : UIColor(white: 0.20, alpha: 0.84)) {
            pick(preset.preset, nil)
        }
    }

    private func addMaintenanceActions(to stack: UIStackView, message: UILabel,
                                       includeStop: Bool) {
        addSection("Maintenance", to: stack)
        stack.addArrangedSubview(buttonRow([
            panelButton("Copy Debug") { [weak self, weak message] in
                self?.copyDebugSnapshot()
                message?.text = self?.lastToolMessage
            },
            panelButton("Tools") { [weak self] in self?.presentTools() },
        ]))
        if includeStop {
            let stop = panelButton("Stop Session") { [weak self] in
                self?.writeSessionRequest("stop")
                message.text = self?.lastToolMessage
            }
            stop.backgroundColor = UIColor.systemRed.withAlphaComponent(0.44)
            stack.addArrangedSubview(buttonRow([
                stop,
                panelButton("Close") { [weak self] in self?.dismissPicker() },
            ]))
        } else {
            stack.addArrangedSubview(panelButton("Close") { [weak self] in self?.dismissPicker() })
        }
    }

    /// One scrollable control surface for the app chrome. It covers the things a
    /// launcher screen needs to do in practice: inspect/switch the current display,
    /// choose the logical size for the next compositor, start/switch desktop flavors,
    /// and launch clients onto a running desktop.
    private func presentDisplayControl(initial: DisplayControlFocus) {
        let (_, _, _, stack) = presentScrollableModalCard(maxWidth: 720)
        let message = addDisplayControlHeader(to: stack, selected: initial)
        switch initial {
        case .displays:
            addDisplayPanelContent(to: stack, message: message)
        case .sessions:
            addSessionPanelContent(to: stack, message: message)
        }
    }

    private func presentDisplayAdvancedPicker() {
        let (overlay, card) = presentModalCard()

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        stack.addArrangedSubview(panelLabel("Display Size", size: 18, weight: .bold))
        stack.addArrangedSubview(panelLabel("Logical desktop size for the next session", size: 12,
                                            color: UIColor(white: 0.72, alpha: 1)))

        let source = pendingSessionDisplay
        let widthField = panelTextField("Width")
        widthField.keyboardType = .numberPad
        widthField.text = source.map { String($0.width) } ?? ""
        let heightField = panelTextField("Height")
        heightField.keyboardType = .numberPad
        heightField.text = source.map { String($0.height) } ?? ""
        let dpiField = panelTextField("DPI")
        dpiField.keyboardType = .numberPad
        dpiField.text = source.flatMap { $0.dpi > 0 ? String($0.dpi) : nil } ?? ""
        stack.addArrangedSubview(viewRow([widthField, heightField, dpiField]))

        let message = panelLabel("", size: 12, color: UIColor.systemRed.withAlphaComponent(0.9))
        stack.addArrangedSubview(message)

        stack.addArrangedSubview(buttonRow([
            panelButton("Apply") { [weak self, weak widthField, weak heightField, weak dpiField, weak message] in
                guard let self else { return }
                let w = Int(widthField?.text ?? "") ?? 0
                let h = Int(heightField?.text ?? "") ?? 0
                guard w >= 640, h >= 480, w <= 4096, h <= 4096 else {
                    message?.text = "Use width/height from 640 to 4096."
                    return
                }
                let dpi = Int(dpiField?.text ?? "") ?? 0
                if dpi != 0 && (dpi < 72 || dpi > 360) {
                    message?.text = "Use DPI from 72 to 360."
                    return
                }
                self.pendingSessionDisplay = DisplayProfile(
                    name: "Custom", width: w, height: h, dpi: dpi,
                    detail: "\(w)x\(h) logical")
                self.presentDisplayControl(initial: .sessions)
            },
            panelButton("Clear") { [weak self] in
                self?.pendingSessionDisplay = nil
                self?.presentDisplayControl(initial: .sessions)
            },
            panelButton("Back") { [weak self] in self?.presentDisplayControl(initial: .sessions) },
        ]))

        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
            card.widthAnchor.constraint(greaterThanOrEqualToConstant: 380),
            card.widthAnchor.constraint(lessThanOrEqualToConstant: 520),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 18),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -18),
        ])
    }

    /// A scrollable sheet listing every installed GUI app (from the .desktop files
    /// under the applications dirs). Tapping a row launches it as a Wayland client of
    /// the running compositor — the same `app` preset path the quick buttons use, so
    /// it rides all the existing ioscd-socket / status plumbing — then dismisses so the
    /// desktop is visible while the window maps.
    private func presentAppLauncher() {
        let (_, _, _, stack) = presentScrollableModalCard()

        stack.addArrangedSubview(panelLabel("Launch App", size: 18, weight: .bold))
        let hasCompositor = FileManager.default.fileExists(atPath: XiosRuntimePaths.tmp("wayland-0"))
        stack.addArrangedSubview(panelLabel(
            hasCompositor
                ? "Opens into the running desktop."
                : "No desktop is running — start iosc or GNOME first.",
            size: 12, color: UIColor(white: 0.72, alpha: 1)))

        let apps = discoverDesktopApps()
        let search = panelSearchField("Search apps")
        stack.addArrangedSubview(search)

        let resultsStack = UIStackView()
        resultsStack.axis = .vertical
        resultsStack.spacing = 10
        resultsStack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(resultsStack)

        let renderResults: (String) -> Void = { [weak self, weak resultsStack] query in
            guard let self, let resultsStack else { return }
            for view in resultsStack.arrangedSubviews {
                resultsStack.removeArrangedSubview(view)
                view.removeFromSuperview()
            }
            let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
            let filtered = needle.isEmpty ? apps : apps.filter { app in
                app.name.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil ||
                app.exec.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil ||
                app.id.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
            if apps.isEmpty {
                resultsStack.addArrangedSubview(self.panelLabel(
                    "No installed apps were found under \(self.applicationsDirs[0]).",
                    size: 13, color: UIColor(white: 0.72, alpha: 1)))
            } else if filtered.isEmpty {
                resultsStack.addArrangedSubview(self.panelLabel(
                    "No apps match \"\(needle)\".",
                    size: 13, color: UIColor(white: 0.72, alpha: 1)))
            } else {
                for app in filtered {
                    resultsStack.addArrangedSubview(self.appLaunchRow(app))
                }
            }
        }
        search.addAction(UIAction { [weak search] _ in
            renderResults(search?.text ?? "")
        }, for: .editingChanged)

        if apps.isEmpty {
            search.isHidden = true
        } else {
            search.becomeFirstResponder()
        }
        renderResults("")

        stack.addArrangedSubview(buttonRow([
            panelButton("Rescan") { [weak self] in self?.presentAppLauncher() },
            panelButton("Back") { [weak self] in self?.presentDisplayControl(initial: .sessions) },
        ]))
        stack.addArrangedSubview(panelButton("Close") { [weak self] in self?.dismissPicker() })
    }

    /// One left-aligned row: app name on top, the command it runs beneath. Tapping
    /// launches it and closes the panel.
    private func appLaunchRow(_ app: DesktopApp) -> UIButton {
        let b = UIButton(type: .system)
        b.contentHorizontalAlignment = .left
        b.setTitleColor(.white, for: .normal)
        b.titleLabel?.numberOfLines = 2
        let title = NSMutableAttributedString(
            string: app.name,
            attributes: [.font: UIFont.systemFont(ofSize: 15, weight: .semibold),
                         .foregroundColor: UIColor.white])
        title.append(NSAttributedString(
            string: "\n\(app.exec)",
            attributes: [.font: UIFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                         .foregroundColor: UIColor(white: 0.62, alpha: 1)]))
        b.setAttributedTitle(title, for: .normal)
        stylePanelSurface(b, fill: UIColor(white: 0.20, alpha: 0.84))
        b.contentEdgeInsets = UIEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        b.menu = UIMenu(children: [
            UIAction(title: "Open") { [weak self] _ in
                guard let self else { return }
                self.writeSessionRequest("app", app: app.exec, display: nil)
                self.dismissPicker()
            },
            UIAction(title: "Pin to Desktop") { [weak self] _ in
                guard let self else { return }
                self.pinAppToDesktop(app)
                self.presentAppLauncher()
            },
        ])
        b.showsMenuAsPrimaryAction = false
        b.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.writeSessionRequest("app", app: app.exec, display: nil)
            self.dismissPicker()
        }, for: .touchUpInside)
        return b
    }

    private func presentHomeScreenApps(query initialQuery: String = "") {
        let (_, _, _, stack) = presentScrollableModalCard(maxWidth: 720)

        stack.addArrangedSubview(panelLabel("Home Screen Apps", size: 18, weight: .bold))
        let message = panelLabel(lastToolMessage, size: 12, color: UIColor(white: 0.72, alpha: 1))
        stack.addArrangedSubview(message)

        let state = fetchLauncherApps()
        if let error = state.error {
            stack.addArrangedSubview(panelLabel(error, size: 13, color: UIColor.systemRed.withAlphaComponent(0.9)))
        }

        let search = panelSearchField("Search launchers")
        search.text = initialQuery
        stack.addArrangedSubview(search)

        let resultsStack = UIStackView()
        resultsStack.axis = .vertical
        resultsStack.spacing = 10
        resultsStack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(resultsStack)

        let renderResults: (String) -> Void = { [weak self, weak resultsStack] query in
            guard let self, let resultsStack else { return }
            for view in resultsStack.arrangedSubviews {
                resultsStack.removeArrangedSubview(view)
                view.removeFromSuperview()
            }
            let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
            let filtered = needle.isEmpty ? state.apps : state.apps.filter { app in
                app.name.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil ||
                app.exec.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil ||
                app.id.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
            if state.apps.isEmpty && state.error == nil {
                resultsStack.addArrangedSubview(self.panelLabel(
                    "No launcher candidates were reported by ioscd.",
                    size: 13, color: UIColor(white: 0.72, alpha: 1)))
            } else if filtered.isEmpty && !state.apps.isEmpty {
                resultsStack.addArrangedSubview(self.panelLabel(
                    "No launchers match \"\(needle)\".",
                    size: 13, color: UIColor(white: 0.72, alpha: 1)))
            } else {
                for app in filtered {
                    resultsStack.addArrangedSubview(self.launcherAppRow(app, query: needle, message: message))
                }
            }
        }
        search.addAction(UIAction { [weak search] _ in
            renderResults(search?.text ?? "")
        }, for: .editingChanged)
        renderResults(initialQuery)

        addSection("Sync", to: stack)
        stack.addArrangedSubview(buttonRow([
            panelButton("Dry Native") { [weak self] in
                guard let self, let lines = self.sendLauncherSync(native: true, dryRun: true) else { return }
                self.presentLauncherSyncReport(title: "Native Dry Run", lines: lines)
            },
            panelButton("Dry Classic") { [weak self] in
                guard let self, let lines = self.sendLauncherSync(native: false, dryRun: true) else { return }
                self.presentLauncherSyncReport(title: "Classic Dry Run", lines: lines)
            },
        ]))
        stack.addArrangedSubview(buttonRow([
            panelButton("Apply Native") { [weak self] in
                guard let self, let lines = self.sendLauncherSync(native: true, dryRun: false) else { return }
                self.presentLauncherSyncReport(title: "Native Sync", lines: lines)
            },
            panelButton("Apply Classic") { [weak self] in
                guard let self, let lines = self.sendLauncherSync(native: false, dryRun: false) else { return }
                self.presentLauncherSyncReport(title: "Classic Sync", lines: lines)
            },
        ]))

        stack.addArrangedSubview(buttonRow([
            panelButton("Refresh") { [weak self, weak search] in
                self?.presentHomeScreenApps(query: search?.text ?? "")
            },
            panelButton("Back") { [weak self] in self?.presentDisplayControl(initial: .sessions) },
            panelButton("Close") { [weak self] in self?.dismissPicker() },
        ]))
    }

    private func launcherAppRow(_ app: LauncherApp, query: String, message: UILabel) -> UIView {
        let row = UIView()
        row.translatesAutoresizingMaskIntoConstraints = false
        stylePanelSurface(row, fill: app.enabled ? UIColor(white: 0.20, alpha: 0.84)
                                                 : UIColor(white: 0.13, alpha: 0.84))

        let textStack = UIStackView()
        textStack.axis = .vertical
        textStack.spacing = 3
        textStack.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(textStack)

        let title = panelLabel(app.name, size: 15, weight: .semibold)
        let detail = panelLabel("\(app.exec)\n\(app.id)", size: 11,
                                color: UIColor(white: 0.64, alpha: 1))
        detail.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textStack.addArrangedSubview(title)
        textStack.addArrangedSubview(detail)

        let toggle = UISwitch()
        toggle.translatesAutoresizingMaskIntoConstraints = false
        toggle.isOn = app.enabled
        toggle.onTintColor = .systemBlue
        row.addSubview(toggle)
        toggle.addAction(UIAction { [weak self, weak toggle, weak message] _ in
            guard let self, let toggle else { return }
            if self.sendLauncherToggle(app, enabled: toggle.isOn) {
                self.presentHomeScreenApps(query: query)
            } else {
                toggle.isOn = app.enabled
                message?.text = self.lastToolMessage
            }
        }, for: .valueChanged)

        NSLayoutConstraint.activate([
            textStack.topAnchor.constraint(equalTo: row.topAnchor, constant: 10),
            textStack.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 12),
            textStack.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -10),
            toggle.leadingAnchor.constraint(equalTo: textStack.trailingAnchor, constant: 12),
            toggle.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -12),
            toggle.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 68),
        ])
        return row
    }

    private func presentLauncherSyncReport(title: String, lines: [String]) {
        let (_, _, _, stack) = presentScrollableModalCard(maxWidth: 720)
        stack.addArrangedSubview(panelLabel(title, size: 18, weight: .bold))
        stack.addArrangedSubview(panelLabel(lastToolMessage, size: 12,
                                            color: UIColor(white: 0.72, alpha: 1)))

        let report = UITextView()
        report.translatesAutoresizingMaskIntoConstraints = false
        report.isEditable = false
        report.isScrollEnabled = true
        report.backgroundColor = UIColor(white: 0.08, alpha: 1)
        report.textColor = UIColor(white: 0.86, alpha: 1)
        report.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        report.layer.cornerRadius = 8
        report.text = lines.joined(separator: "\n")
        stack.addArrangedSubview(report)
        report.heightAnchor.constraint(equalToConstant: 260).isActive = true

        stack.addArrangedSubview(buttonRow([
            panelButton("Back") { [weak self] in self?.presentHomeScreenApps() },
            panelButton("Close") { [weak self] in self?.dismissPicker() },
        ]))
    }

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
        backdrop.backgroundColor = UIColor.black.withAlphaComponent(0.48)
        backdrop.addAction(UIAction { [weak self] _ in self?.dismissPicker() }, for: .touchUpInside)
        overlay.addSubview(backdrop)

        let card = UIView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.backgroundColor = UIColor(white: 0.10, alpha: 0.76)
        card.layer.cornerRadius = 22
        card.layer.cornerCurve = .continuous
        card.layer.borderColor = UIColor.white.withAlphaComponent(0.14).cgColor
        card.layer.borderWidth = 1
        card.layer.shadowColor = UIColor.black.cgColor
        card.layer.shadowOpacity = 0.36
        card.layer.shadowRadius = 26
        card.layer.shadowOffset = CGSize(width: 0, height: 18)
        overlay.addSubview(card)

        let material = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
        material.translatesAutoresizingMaskIntoConstraints = false
        material.isUserInteractionEnabled = false
        material.clipsToBounds = true
        material.layer.cornerRadius = 22
        material.layer.cornerCurve = .continuous
        card.insertSubview(material, at: 0)
        NSLayoutConstraint.activate([
            material.topAnchor.constraint(equalTo: card.topAnchor),
            material.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            material.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            material.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
        return (overlay, card)
    }

    private func makeRow(_ d: XDisplayInfo) -> UIButton {
        let active = (d.configPath != nil && d.configPath == configPath) ||
            (d.slot == nil && d.number == activeDisplayNumber)
        let b = UIButton(type: .system)
        b.contentHorizontalAlignment = .left
        b.titleLabel?.numberOfLines = 3
        b.setAttributedTitle(displayRowTitle(d, active: active), for: .normal)
        b.setTitleColor(.white, for: .normal)
        stylePanelSurface(b, fill: active ? UIColor.systemBlue.withAlphaComponent(0.38)
                                          : UIColor(white: 0.20, alpha: 0.84))
        b.contentEdgeInsets = UIEdgeInsets(top: 11, left: 12, bottom: 11, right: 12)
        b.addAction(UIAction { [weak self] _ in
            self?.dismissPicker()
            self?.load(d)
        }, for: .touchUpInside)
        return b
    }

    private func displayRowTitle(_ d: XDisplayInfo, active: Bool) -> NSAttributedString {
        let title = NSMutableAttributedString(
            string: displayName(d, active: active),
            attributes: [.font: UIFont.systemFont(ofSize: 15, weight: .semibold),
                         .foregroundColor: UIColor.white])
        title.append(NSAttributedString(
            string: "\n\(displayDetail(d))",
            attributes: [.font: UIFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                         .foregroundColor: UIColor(white: 0.68, alpha: 1)]))
        if active {
            title.append(NSAttributedString(
                string: "\nActive display",
                attributes: [.font: UIFont.systemFont(ofSize: 11, weight: .semibold),
                             .foregroundColor: UIColor(white: 0.86, alpha: 1)]))
        }
        return title
    }

    private func displayName(_ d: XDisplayInfo, active: Bool) -> String {
        let prefix = active ? "Active - " : ""
        if let slot = d.slot {
            let preset = d.preset.map { desktopLabel($0) } ?? "Display Slot"
            let state = d.state.map { " - \($0)" } ?? ""
            return "\(prefix)\(slot) - \(preset)\(state)"
        }
        let name = d.number >= 0 ? ":\(d.number)" : (d.wayland ?? "display")
        return "\(prefix)\(name)"
    }

    private func displayDetail(_ d: XDisplayInfo) -> String {
        if let cfg = d.config {
            let w = (cfg["width"] as? Int) ?? 0
            let h = (cfg["height"] as? Int) ?? 0
            let backend = (cfg["ddx"] as? String) == "iosurface" ? "IOSurface" : "unsupported"
            let input = (cfg["input_socket"] as? String).map { pathBasename($0) } ?? "input unknown"
            let source = d.configPath.map { " / \(pathBasename($0))" } ?? ""
            return "\(w)x\(h) / \(backend) / \(input)\(source)"
        }
        return d.wayland.map { "\($0) starting / no framebuffer yet" } ?? "Input only / no framebuffer"
    }

    private func pathBasename(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    private func pillButton(_ title: String, _ action: @escaping () -> Void) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(title, for: .normal)
        b.setTitleColor(.white, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        b.titleLabel?.numberOfLines = 2
        b.titleLabel?.textAlignment = .center
        b.titleLabel?.adjustsFontSizeToFitWidth = true
        b.titleLabel?.minimumScaleFactor = 0.75
        stylePanelSurface(b, fill: UIColor(white: 0.24, alpha: 0.86))
        b.contentEdgeInsets = UIEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        b.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        b.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return b
    }

    private func detailPanelButton(title: String, detail: String, iconName: String?,
                                   fill: UIColor = UIColor(white: 0.20, alpha: 0.84),
                                   action: @escaping () -> Void) -> UIButton {
        let b = UIButton(type: .system)
        b.contentHorizontalAlignment = .left
        b.setTitleColor(.white, for: .normal)
        b.tintColor = .white
        b.titleLabel?.numberOfLines = 2

        let text = NSMutableAttributedString(
            string: title,
            attributes: [.font: UIFont.systemFont(ofSize: 15, weight: .semibold),
                         .foregroundColor: UIColor.white])
        text.append(NSAttributedString(
            string: "\n\(detail)",
            attributes: [.font: UIFont.systemFont(ofSize: 11, weight: .regular),
                         .foregroundColor: UIColor(white: 0.66, alpha: 1)]))
        b.setAttributedTitle(text, for: .normal)
        if let iconName {
            b.setImage(UIImage(systemName: iconName), for: .normal)
            b.imageView?.contentMode = .scaleAspectFit
            b.imageEdgeInsets = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 8)
            b.titleEdgeInsets = UIEdgeInsets(top: 0, left: 8, bottom: 0, right: -8)
        }
        stylePanelSurface(b, fill: fill)
        b.contentEdgeInsets = UIEdgeInsets(top: 11, left: 12, bottom: 11, right: 12)
        b.heightAnchor.constraint(greaterThanOrEqualToConstant: 58).isActive = true
        b.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return b
    }

    private func iconPanelButton(_ systemName: String, label: String,
                                 action: @escaping () -> Void) -> UIButton {
        let b = UIButton(type: .system)
        b.setImage(UIImage(systemName: systemName), for: .normal)
        b.tintColor = .white
        b.accessibilityLabel = label
        stylePanelSurface(b, fill: UIColor(white: 0.22, alpha: 0.84), radius: 9)
        b.widthAnchor.constraint(equalToConstant: 36).isActive = true
        b.heightAnchor.constraint(equalToConstant: 34).isActive = true
        b.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return b
    }

    private func emptyPanel(_ text: String) -> UIView {
        let label = panelLabel(text, size: 13, color: UIColor(white: 0.70, alpha: 1))
        label.textAlignment = .center

        let panel = UIStackView(arrangedSubviews: [label])
        panel.axis = .vertical
        panel.isLayoutMarginsRelativeArrangement = true
        panel.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 18, leading: 12,
                                                                bottom: 18, trailing: 12)
        stylePanelSurface(panel, fill: UIColor(white: 0.14, alpha: 0.72), radius: 12)
        return panel
    }

    private func stylePanelSurface(_ view: UIView, fill: UIColor, radius: CGFloat = 10) {
        view.backgroundColor = fill
        view.layer.cornerRadius = radius
        view.layer.cornerCurve = .continuous
        view.layer.borderColor = UIColor.white.withAlphaComponent(0.10).cgColor
        view.layer.borderWidth = 1
    }

    @objc private func dismissPicker() {
        pickerOverlay?.removeFromSuperview()
        pickerOverlay = nil
    }

    @objc private func openTools() {
        presentTools()
    }

    private func presentTools() {
        let (_, _, _, stack) = presentScrollableModalCard(maxWidth: 560)
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

    private func panelSearchField(_ placeholder: String) -> UISearchTextField {
        let f = UISearchTextField()
        f.placeholder = placeholder
        f.autocorrectionType = .no
        f.autocapitalizationType = .none
        f.spellCheckingType = .no
        f.clearButtonMode = .whileEditing
        f.font = .systemFont(ofSize: 15)
        f.textColor = .white
        f.tintColor = .white
        f.backgroundColor = UIColor(white: 0.22, alpha: 0.78)
        f.layer.cornerRadius = 10
        f.layer.cornerCurve = .continuous
        f.attributedPlaceholder = NSAttributedString(
            string: placeholder,
            attributes: [.foregroundColor: UIColor(white: 0.72, alpha: 1)])
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

    private func viewRow(_ views: [UIView]) -> UIStackView {
        let row = UIStackView(arrangedSubviews: views)
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

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok {
            oskUserDismissed = false
        }
        return ok
    }
    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok {
            if !oskProgrammaticResign {
                // The user hid the keyboard (toggle or dismiss key) while the field
                // may still be focused: don't fight them on the next broadcast.
                if lastIoscTraitEnabled != 0 { oskUserDismissed = true }
                oskAutoShown = false
            }
        }
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

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if let keyboardRevealPan, gestureRecognizer === keyboardRevealPan {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let p = pan.location(in: self)
            let v = pan.velocity(in: self)
            return p.y >= bounds.height * 0.72 && v.y < -40 && abs(v.y) > abs(v.x)
        }
        if let shellOverlayRevealPan, gestureRecognizer === shellOverlayRevealPan {
            guard pickerOverlay == nil,
                  let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let p = pan.location(in: self)
            let v = pan.velocity(in: self)
            let topBand = max(safeAreaInsets.top + 72, bounds.height * 0.12)
            return p.y <= topBand && v.y > 40 && abs(v.y) > abs(v.x)
        }
        return true
    }
}

extension XScreenView: UIContextMenuInteractionDelegate {
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configurationForMenuAtLocation location: CGPoint)
    -> UIContextMenuConfiguration? {
        guard pickerOverlay == nil, activeDesktopPreset() == "iosc" else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) {
            [weak self] _ in self?.desktopContextMenu() ?? UIMenu()
        }
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                willDisplayMenuFor configuration: UIContextMenuConfiguration,
                                animator: UIContextMenuInteractionAnimating?) {
        cancelPendingPress()
        releaseLeftPress()
    }
}

extension XScreenView: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let provider = results.first?.itemProvider else { return }
        guard provider.canLoadObject(ofClass: UIImage.self) else {
            lastToolMessage = "Selected item is not an image"
            writeDebugSnapshot()
            return
        }
        provider.loadObject(ofClass: UIImage.self) { [weak self] object, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.lastToolMessage = "Wallpaper failed: \(error.localizedDescription)"
                    self.writeDebugSnapshot()
                    return
                }
                guard let image = object as? UIImage else {
                    self.lastToolMessage = "Selected item is not an image"
                    self.writeDebugSnapshot()
                    return
                }
                self.setDesktopWallpaper(image)
            }
        }
    }
}

extension XScreenView: UIGestureRecognizerDelegate {
    private func isChromeTouch(_ touch: UITouch) -> Bool {
        guard var view = touch.view else { return false }
        while true {
            if view is UIControl || view is UITextField || view is UITextView || view is UIScrollView {
                return true
            }
            if let pickerOverlay, view === pickerOverlay { return true }
            if let shellOverlay, view === shellOverlay { return true }
            guard let parent = view.superview else { return false }
            view = parent
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldReceive touch: UITouch) -> Bool {
        if let shellOverlayRevealPan, gestureRecognizer === shellOverlayRevealPan {
            return true
        }
        return !isChromeTouch(touch)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer is UIPinchGestureRecognizer || otherGestureRecognizer is UIPinchGestureRecognizer
    }
}

import UIKit
import PhotosUI
import Metal
import QuartzCore
import IOSurface
import Darwin
import OSLog

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

/// Displays a compositor IOSurface on a CAMetalLayer at native retina resolution
/// and forwards UIKit input over the compositor's input socket. `xios.json` must
/// advertise `"ddx":"iosurface"` and the exact runtime endpoints.
final class XScreenView: UIView {
    private var fbWidth = 1024
    private var fbHeight = 768
    private var selectedConfigPath: String?
    private var configPath: String { selectedConfigPath ?? XiosRuntimePaths.firstExisting("xios.json") }
    // Session display label advertised in xios.json. Xwayland may use the same
    // number, but UIKit input always enters through the compositor.
    private var xDisplay = ":3"
    // Bumped on every load(); the async IOSurface connect captures it and bails if a
    // newer load() superseded it, so switching displays can't adopt a stale surface.
    private var loadGeneration = 0
    private var userPinned = false              // user picked a display → stop auto-reloading xios.json
    // Consecutive config polls that found the pinned display dead. A slot can be
    // restarting, so the pin is only dropped once it has been gone for a few polls.
    private var pinnedDeadPolls = 0
    private static let pinnedDeadPollsToRelease = 3
    private weak var pickerOverlay: UIView?
    private var ioscdSocketPath: String { XiosRuntimePaths.firstExisting("ioscd.sock") }
    private var sessionStatusPath: String { XiosRuntimePaths.firstExisting("xios-session-status.json") }
    private var displayRegistryDir: String { XiosRuntimePaths.tmp("xios-displays.d") }
    private let wallpaperConfigPath = "/var/mobile/Library/Preferences/com.max.iosc-wallpaper"
    private let wallpaperImagePath = "/var/mobile/Library/Preferences/com.max.iosc-wallpaper.jpg"
    // ioscd is deliberately single-threaded. KDE startup or launcher-sync work can
    // briefly keep it busy, so requests run on this serial worker instead of UIKit.
    private let ioscdRequestQueue = DispatchQueue(
        label: "com.max.xios.ioscd-control", qos: .userInitiated)
    private var sessionRequestInFlight = false
    private weak var sessionStatusLabel: UILabel?
    private weak var toolMessageLabel: UILabel?
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

    // MARK: scroll + long-press gesture state
    /// Sub-1/256-px scroll remainder for the iosc AXIS path (wl_fixed units).
    private var axisRemainder = CGPoint.zero
    /// True once this two-finger pan has emitted AXIS records (needs a stop).
    private var axisActive = false
    private var axisSource: UInt32 = 0
    private weak var continuousScrollPan: UIPanGestureRecognizer?
    private weak var discreteScrollPan: UIPanGestureRecognizer?
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
    /// A single direct finger on a desktop shell uses mouse semantics. Keep
    /// that sequence off wl_touch as well, otherwise Plasma sees both a touch
    /// activation and the emulated pointer click.
    private var activeDirectTouchUsesPointer = false
    private static let longPressSeconds: TimeInterval = 0.55
    private static let longPressSlopPt: CGFloat = 12

    // IOSurface (zero-copy) path
    private var ddxIsIOSurface = false
    private var ddxSockPath = XiosRuntimePaths.tmp("xios-ddx.sock")
    private var xconn: OpaquePointer?            // XSurfaceConn*
    private var iosTexture: MTLTexture?
    private var iosSurfaceID: UInt32 = 0
    private var iosSurfaceFlags: UInt32 = 0
    private var usingIOSurface = false
    private var iosConnectStarted = false
    private var needsPresent = false
    private var presentFenceToken: Data?
    private var presentFenceEvent: MTLSharedEvent?
    private var presentFenceDecodeFailed = false
    private var releaseFenceToken: Data?
    private var releaseFenceEvent: MTLSharedEvent?
    private var pendingStreamFrame = false
    private var heldStreamFrame: (surfaceID: UInt32, seq: UInt64)?

    // Present-side cursor overlay. When iosc runs with IOSC_APP_CURSOR it stops
    // compositing the pointer and streams position+shape over the typed socket
    // (see XSurface.c); we draw it as a CALayer above the Metal content so a pointer
    // move is a Core Animation reposition with no Metal re-present. Stays nil (and
    // the compositor keeps drawing its own cursor) until the first CURSOR record.
    private var cursorLayer: CALayer?
    // The client's own cursor bitmap, when the compositor has handed it over.
    // Holding it here is what lets iosc stop painting the cursor into the shared
    // output — a cursor in that buffer is what forfeits direct scanout.
    private var clientCursorImage: CGImage?
    private var clientCursorSize = CGSize.zero
    private var clientCursorHotspot = CGPoint.zero
    private var hasClientCursorImage = false
    private var cursorImageSeq: UInt32 = 0
    private var lastCursorSeq: UInt32 = 0
    private var cursorIsText = false
    private var hardwarePointerActive = false
    private var hardwareButtonMask = 0
    // An `.indirectPointer` touch is live, i.e. at least one button is held. The touch
    // phase, not `buttonMask`, is what tells us the click ended (see hardwarePointerMask).
    private var hardwarePointerTouchDown = false
    // Lets iPadOS's own pointer wear the desktop's cursor shape. Non-nil only where the
    // system draws a pointer at all, which on iPad means a mouse/trackpad is connected;
    // with nothing connected there is no system cursor and we draw our own overlay.
    private var systemPointerInteraction: UIPointerInteraction?
    // Latest wp_cursor_shape id the compositor streamed. 0 = the desktop hid the pointer
    // OR handed rendering back to the compositor (iosc sends visible=0/shape=0 when a
    // client supplies its own cursor surface, e.g. nested KWin) — either way iPadOS must
    // not add a second cursor on top.
    private var desktopCursorShape: Int32 = 0
    private let hardwareKeyboard = XiosHardwareKeyboard()
    private var iosurfaceCompositorID = ""

    private var displayLink: CADisplayLink?
    // MARK: display pacing (P0.4's remaining half)
    // The link's targetTimestamp is the deadline for the frame being built. Sent to
    // the compositor each tick (xsurface_pacing), it turns iosc's already-coalesced
    // repaint from event-loop paced into vblank paced. The frame rate is a RANGE, not
    // a fixed number: preferredFramesPerSecond is deprecated in favour of
    // preferredFrameRateRange, and a range is something CoreAnimation can settle
    // inside on its own rather than a hard flip between two values. The thermal track
    // clamps `pacingRange` — that is the seam it needs.
    private var pacingRange = XScreenView.liveFrameRate
    /// The idle/no-signal holding frame: nothing is animating, so ask for very little.
    private static let holdingFrameRate = CAFrameRateRange(minimum: 10, maximum: 20, preferred: 20)
    /// A live desktop. The floor is deliberately well below the ceiling so
    /// CoreAnimation can throttle a thermally constrained A10 without stuttering.
    private static let liveFrameRate = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
    /// Refresh interval the link last reported, for the status line.
    private var lastLinkIntervalUs: UInt32 = 0

    // Instruments needs named intervals to show where a frame went; without them the
    // present path is an anonymous slice of the main thread. Two intervals: `present`
    // covers building and committing the frame, `upscale` the MetalFX stage inside it,
    // so "did upscaling actually get cheaper" is a readable comparison rather than an
    // inference from fps. A disabled signposter compiles down to nothing.
    private let signposter = OSSignposter(
        subsystem: "com.max.xios", category: "present")

    // MARK: present-side MetalFX upscaling (see XiosUpscale.swift)
    // OFF by default: this lands as an opt-in you can measure, not a silent change to
    // what the desktop looks like. Switched at runtime from XIOS_UPSCALE in our own
    // environment, or from xios.json's "upscale" field — which is the production knob,
    // because FrontBoard launches us with no environment of our own (iosc forwards its
    // IOSC_UPSCALE into the config it already writes).
    private var upscaleMode = XiosUpscaleMode.off
    private var upscaler: XiosUpscaler?
    private var lastUpscaleStatus = ""
    private var testBuf: UnsafeMutablePointer<UInt8>?
    private var usingTestPattern = false
    // The animated test card is a LAST-RESORT no-signal diagnostic only. During
    // normal startup the IOSurface connects in ~1s, so we show clean black and never
    // the card; it appears only after this many test-pattern ticks with no framebuffer.
    private var testPatternStartTick = 0
    private static let testPatternGraceTicks = 150   // ~7.5s at 20fps
    private var inputConnected = false
    private var tickCount = 0

    // The compositor advertises its per-slot input and clipboard endpoints in
    // xios.json. Missing endpoints are configuration errors.
    private var ioscInputSock: String?
    private var ioscClipboardSock: String?
    private var inputConfigurationError: String?
    private var clipboardConfigurationError: String?
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
    private var didInstallLifecycleObservers = false
    private var appIsBackgrounded = false
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    override class var layerClass: AnyClass { CAMetalLayer.self }

    func start() {
        // Name this process in the shared status table explicitly rather than relying
        // on getprogname(), and let iosc_status drop any table a previous (killed)
        // instance left behind — see iosc_status.c's init_paths.
        iosc_status_set_producer("Xios")
        loadConfig()
        installLifecycleObservers()
        SystemIntegration.shared.install(on: self)
        XiosCameraBroker.shared.startIfDiagnosticEnabled()
        isMultipleTouchEnabled = true
        // MTLCreateSystemDefaultDevice() returns nil for a backgrounded app (a
        // SpringBoard relaunch, or uicache registration launching us off-screen), so a
        // background launch would otherwise leave us permanently black with no recovery.
        // Retry once we become active/foreground, where the GPU is reachable.
        if !setupMetal() { return }
        metalReady = true
        // loadConfig() above already decided the upscale mode, but there was no device
        // to build the pass with. Now there is.
        syncUpscaler()

        awaitingCompositor = true
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

        let dl = CADisplayLink(target: self, selector: #selector(tick(_:)))
        pacingRange = usingTestPattern ? Self.holdingFrameRate : Self.liveFrameRate
        dl.preferredFrameRateRange = pacingRange
        dl.add(to: .main, forMode: .common)
        displayLink = dl

        installChrome()
        installShellOverlay()
        hardwareKeyboard.start { [weak self] keysym, down, modifiers in
            self?.sendHardwareKey(keysym, down: down, modifiers: modifiers)
        }
        // start() already loaded the display in xios.json (the default). If other
        // displays are also open, say so rather than opening a modal over the
        // desktop at launch — Advanced lists them and switches.
        if discoverDisplays().count > 1 {
            lastToolMessage = "More than one display is open — pick one in Advanced"
        }
    }

    /// Keep UIKit lifecycle work deliberately small: a backgrounded Xios process
    /// should retain its UI and Metal pipeline, but not pin a compositor IOSurface or
    /// keep polling sockets. Reconnect from config when the app becomes active again.
    private func installLifecycleObservers() {
        if didInstallLifecycleObservers { return }
        didInstallLifecycleObservers = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    @objc private func appDidEnterBackground() {
        appIsBackgrounded = true
        displayLink?.isPaused = true
        loadGeneration += 1                  // cancel any blocking connect retry
        if metalReady {
            teardownConnections(resetTransform: false)
            texture = nil                    // release even a diagnostic holding frame
            // The intermediate + staging targets are a few MB of private GPU storage;
            // a backgrounded app has no business pinning them where jetsam can see it.
            // The mode is kept, so becoming active rebuilds them on the first frame.
            upscaler?.releaseResources()
            awaitingCompositor = true
            writeStatus()
        }
    }

    @objc private func appDidBecomeActive() {
        if !metalReady {
            appIsBackgrounded = false
            start()                          // background launch: Metal is available now
            return
        }
        guard appIsBackgrounded else { return }
        appIsBackgrounded = false
        _ = loadConfig()
        awaitingCompositor = true
        startTestPattern()
        if ddxIsIOSurface { startIOSurfaceConnect() }
        connectInput()
        displayLink?.isPaused = false
        syncUpscaler()      // rebuild the pass backgrounding released
        writeStatus()
    }

    /// Show a clean black screen until a real framebuffer is available; only after a
    /// grace period without one does the animated test card appear (last-resort
    /// no-signal diagnostic, never during normal startup).
    private func startTestPattern() {
        usingTestPattern = true
        let width = awaitingCompositor ? 1 : fbWidth
        let height = awaitingCompositor ? 1 : fbHeight
        testBuf?.deallocate()       // safe to call when switching displays
        testBuf = .allocate(capacity: width * height * 4)
        testBuf?.initialize(repeating: 0, count: width * height * 4)   // clean black
        testPatternStartTick = tickCount
        makeTexture(width: width, height: height)
        needsPresent = true         // upload + present the initial clean-black frame once
        setPacingRange(Self.holdingFrameRate)
    }

    /// Single place the display link's frame-rate range is applied, so the thermal
    /// track has one lever to clamp and the status line one place to publish from.
    private func setPacingRange(_ range: CAFrameRateRange) {
        pacingRange = range
        displayLink?.preferredFrameRateRange = range
        publishPacingStatus()
    }

    private func publishPacingStatus() {
        // "vblank" is the app's claim that it IS driving the compositor's clock; the
        // compositor publishes its own `pacing` key saying whether it accepted one
        // (an old iosc ignores the record). Both appear in `xios-status`, attributed.
        let interval = lastLinkIntervalUs > 0
            ? String(format: " interval=%.2fms", Double(lastLinkIntervalUs) / 1000.0)
            : ""
        // `preferred` is optional in the SDK: nil means "no preference, settle
        // anywhere in the range", which is worth showing as such rather than as 0.
        let preferred = pacingRange.preferred.map { String(format: "/%g", $0) } ?? ""
        let fps = String(format: "%g-%g", pacingRange.minimum, pacingRange.maximum)
        iosc_status_set_value("pacing", "vblank fps=\(fps)\(preferred)\(interval)")
    }

    // MARK: IOSurface (zero-copy) path

    /// Begin connecting to the IOSurface backend (once). Safe to call from both
    /// start() and the poll path, in either app/server launch order.
    private func startIOSurfaceConnect() {
        if iosConnectStarted || appIsBackgrounded { return }
        iosConnectStarted = true
        let path = ddxSockPath
        let gen = loadGeneration
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Retry until the X server's socket is up (it may launch after the app),
            // but bail the moment a newer load() superseded this connect.
            for _ in 0..<120 {
                guard let self, self.loadGeneration == gen,
                      !self.appIsBackgrounded else { return }
                if let conn = xsurface_connect(path) {
                    DispatchQueue.main.async {
                        if self.loadGeneration == gen, !self.appIsBackgrounded {
                            self.adoptIOSurface(conn)
                        }
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
        guard !appIsBackgrounded else {
            xsurface_close(conn)
            iosConnectStarted = false
            return
        }
        xconn = conn
        iosurfaceCompositorID = String(cString: xsurface_compositor_id(conn))
        guard syncSurfaceGeometry(conn), importReleaseFence(conn) else {
            dbg("iosurface-texture-fail"); xsurface_close(conn); xconn = nil
            iosurfaceCompositorID = ""
            iosTexture = nil
            iosSurfaceID = 0
            iosSurfaceFlags = 0
            releaseFenceToken = nil
            releaseFenceEvent = nil
            iosConnectStarted = false   // let the %30 poll retry the connect
            return
        }
        usingIOSurface = true
        awaitingCompositor = false                // new compositor surface is live again
        usingTestPattern = false
        testBuf?.deallocate(); testBuf = nil
        texture = nil                             // drop the test-pattern texture (~14 MB)
        needsPresent = true                       // present the initial frame
        setPacingRange(Self.liveFrameRate)
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
        let sourceWidth = Int(xsurface_surface_width(conn))
        let sourceHeight = Int(xsurface_surface_height(conn))
        let surfaceID = xsurface_surface_id(conn)
        let surfaceFlags = xsurface_surface_flags(conn)
        guard newWidth > 0, newHeight > 0,
              sourceWidth > 0, sourceHeight > 0,
              surfaceID != 0 else { return false }

        let geometryChanged = newWidth != fbWidth || newHeight != fbHeight
        let textureChanged = iosSurfaceID != surfaceID ||
            iosTexture?.width != sourceWidth || iosTexture?.height != sourceHeight
        guard geometryChanged || textureChanged else { return true }

        // C owns the IOSurface ref (released in xsurface_close); borrow it here.
        let surface = xsurface_get(conn).takeUnretainedValue()
        let td = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: sourceWidth, height: sourceHeight, mipmapped: false)
        td.usage = .shaderRead
        td.storageMode = .shared
        // Metal reads the surface's own (possibly padded) bytesPerRow; zero-copy.
        guard let tex = device.makeTexture(descriptor: td, iosurface: surface, plane: 0) else {
            return false
        }

        fbWidth = newWidth
        fbHeight = newHeight
        iosTexture = tex
        iosSurfaceID = surfaceID
        iosSurfaceFlags = surfaceFlags
        // Always snap to fit on adopt/resize (zoom 1, pan 0) — one source of truth for
        // present scale. A stale zoom over-scales the current fb and makes the inverse
        // touch mapping land offset.
        if geometryChanged {
            resetZoom()
            dumpGeom()
        }
        if usingIOSurface { writeStatus() }
        return true
    }

    private func importReleaseFence(_ conn: OpaquePointer) -> Bool {
        var bytes: UnsafeRawPointer?
        var length = 0
        guard xsurface_release_fence_token(conn, &bytes, &length) != 0 else {
            /* Fixed one-surface producers (currently Mutter/Xorg) retain their
             * legacy contract. They never rotate an allocation, so no consumer
             * release timeline is required. */
            releaseFenceToken = nil
            releaseFenceEvent = nil
            return true
        }
        guard let bytes, length > 0 else { return false }
        let token = Data(bytes: bytes, count: length)
        if token == releaseFenceToken, releaseFenceEvent != nil {
            return true
        }
        guard let event = xios_metal_event_broker_copy_event(
            device, bytes, length
        ) else {
            dbg("release-fence-broker-import-failed")
            return false
        }
        releaseFenceToken = token
        releaseFenceEvent = event
        return true
    }

    private func submitHeldStreamRelease(_ conn: OpaquePointer) -> Bool {
        guard let held = heldStreamFrame else { return true }
        guard let event = releaseFenceEvent else {
            heldStreamFrame = nil       // legacy fixed-output connection
            return true
        }
        guard let commandBuffer = queue.makeCommandBuffer() else {
            return false
        }
        commandBuffer.label = "Xios IOSurface consumer release"
        commandBuffer.encodeSignalEvent(event, value: held.seq)
        commandBuffer.commit()
        guard xsurface_released(conn, held.surfaceID, held.seq) == 0 else {
            dbg("release-fence-submit-send-failed")
            return false
        }
        heldStreamFrame = nil
        return true
    }

    // MARK: present-side cursor overlay

    /// Pull the latest CURSOR state and move/hide the overlay layer. Cheap: reads
    /// the last-parsed state (no I/O — xsurface_drain already parsed it) and only
    /// touches Core Animation when the sequence changed.
    private func updateCursorOverlay(_ conn: OpaquePointer) {
        var x: Int32 = 0, y: Int32 = 0, vis: Int32 = 0, shape: Int32 = 0
        let seq = xsurface_cursor(conn, &x, &y, &vis, &shape)
        // Content arrives on its own schedule (only when the cursor image
        // changes), so it is picked up before the position early-outs below.
        adoptClientCursorImage(conn)
        guard seq != 0 else { return }        // overlay off server-side → compositor draws it
        if seq == lastCursorSeq { return }    // no new pointer state this tick
        lastCursorSeq = seq
        noteDesktopCursorShape(vis == 0 ? 0 : shape)

        // With a mouse or trackpad attached, iPadOS is already drawing a pointer and it
        // wears the desktop's shape (see systemPointerStyle). A second cursor of our own
        // would just trail it, so let the system own the pointer for as long as one is
        // connected — the moment input goes back to a finger or the Pencil,
        // suppressCursorOverlayForTouch clears the flag and we draw it again.
        if hardwarePointerActive, systemPointerInteraction != nil {
            cursorLayer?.isHidden = true
            return
        }
        // Without a real cursor image the synthesized arrow is only worth drawing
        // where the compositor has no pointer of its own (mutter). But once the
        // client's own bitmap is in hand, this layer IS the cursor — the
        // compositor has stopped painting one, so hiding it would leave none.
        if !hardwarePointerActive && iosurfaceCompositorID != "mutter-ios"
            && !hasClientCursorImage {
            cursorLayer?.isHidden = true
            return
        }
        if cursorLayer == nil { makeCursorLayer(shape: shape) }
        guard let layer = cursorLayer else { return }
        if vis == 0 { layer.isHidden = true; return }
        layer.isHidden = false
        if hasClientCursorImage {
            applyClientCursorToLayer()        // the client's real bitmap + hotspot
        } else {
            applyCursorShape(shape)           // swap arrow/I-beam if the category changed
        }

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

    /// Adopt the client's cursor pixels as the overlay's contents, making this
    /// layer a real cursor plane. CoreAnimation composites it for free, so the
    /// compositor never has to dirty the shared framebuffer to move a pointer.
    private func adoptClientCursorImage(_ conn: OpaquePointer) {
        var w: Int32 = 0, h: Int32 = 0, hx: Int32 = 0, hy: Int32 = 0, seq: UInt32 = 0
        let pixels = xsurface_cursor_image(conn, &w, &h, &hx, &hy, &seq)
        guard seq != cursorImageSeq else { return }   // no image change this tick
        cursorImageSeq = seq
        guard let pixels, w > 0, h > 0 else {
            // Withdrawn: the compositor is painting the cursor again, so stop
            // drawing ours or there would be two.
            hasClientCursorImage = false
            clientCursorImage = nil
            return
        }
        let data = Data(bytes: pixels, count: Int(w) * Int(h) * 4)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(
                width: Int(w), height: Int(h),
                bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: Int(w) * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                // Premultiplied BGRA on the wire == premultipliedFirst + little endian.
                bitmapInfo: CGBitmapInfo(rawValue:
                    CGImageAlphaInfo.premultipliedFirst.rawValue |
                    CGBitmapInfo.byteOrder32Little.rawValue),
                provider: provider, decode: nil,
                shouldInterpolate: false, intent: .defaultIntent)
        else {
            hasClientCursorImage = false
            clientCursorImage = nil
            return
        }
        clientCursorImage = image
        clientCursorSize = CGSize(width: Int(w), height: Int(h))
        clientCursorHotspot = CGPoint(x: CGFloat(hx) / CGFloat(w),
                                      y: CGFloat(hy) / CGFloat(h))
        hasClientCursorImage = true
    }

    /// Size the plane to match the framebuffer's on-screen scale, and put the
    /// hotspot exactly where the compositor thinks the pointer is.
    private func applyClientCursorToLayer() {
        guard hasClientCursorImage, let layer = cursorLayer,
              let image = clientCursorImage else { return }
        let rect = contentRect()
        let sx = fbWidth > 0 ? rect.width / CGFloat(fbWidth) : 1
        let sy = fbHeight > 0 ? rect.height / CGFloat(fbHeight) : 1
        layer.contents = image
        layer.bounds = CGRect(origin: .zero,
                              size: CGSize(width: clientCursorSize.width * sx,
                                           height: clientCursorSize.height * sy))
        layer.anchorPoint = clientCursorHotspot
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
        noteDesktopCursorShape(0)
    }

    // MARK: system pointer shape

    /// Remember the desktop's cursor shape and re-ask UIKit for a pointer style when the
    /// shape we would hand it changes. Invalidating on every CURSOR record would fight
    /// the pointer's own morph animation, so only a category flip counts.
    private func noteDesktopCursorShape(_ shape: Int32) {
        guard let interaction = systemPointerInteraction else {
            desktopCursorShape = shape
            return
        }
        let before = Self.pointerShapeCategory(desktopCursorShape)
        desktopCursorShape = shape
        if Self.pointerShapeCategory(shape) != before { interaction.invalidate() }
    }

    /// The distinct pointer looks we can ask iPadOS for. Many wp_cursor_shape ids
    /// collapse into one of these, and only a change between them is worth a morph.
    private enum PointerShapeCategory { case hidden, arrow, text, resizeH, resizeV, system }

    /// Map a wp_cursor_shape id onto what iPadOS can draw.
    ///
    /// `hidden` covers two cases that look the same from here: the desktop hid the
    /// pointer, and the compositor took cursor rendering back (iosc sends
    /// visible=0/shape=0 when a client supplies its own cursor surface, which is what
    /// nested KWin does — its themed cursor is already in the framebuffer pixels, so
    /// iPadOS must not add a second one on top).
    ///
    /// `system` keeps iPadOS's own pointer for shapes we have nothing better for
    /// (wait/progress and friends): a wrong glyph reads worse than the default.
    private static func pointerShapeCategory(_ shape: Int32) -> PointerShapeCategory {
        switch shape {
        case 0:                     return .hidden
        case 9:                     return .text        // text
        case 10:                    return .resizeH     // vertical-text: beam lies flat
        case 18, 25, 26, 30:        return .resizeH     // e/w/ew/col-resize
        case 19, 22, 27, 31:        return .resizeV     // n/s/ns/row-resize
        case 5, 6:                  return .system      // progress, wait
        default:                    return .arrow
        }
    }

    /// The style iPadOS should draw for the current desktop cursor. Beams are UIKit's
    /// own shapes, so text fields and window edges get the native morph; everything else
    /// is the same arrow bitmap the overlay layer draws, as a filled path.
    private func systemPointerStyle() -> UIPointerStyle? {
        switch Self.pointerShapeCategory(desktopCursorShape) {
        case .hidden:
            return .hidden()
        case .system:
            return nil                  // nil = iPadOS's standard pointer
        case .text:
            return UIPointerStyle(shape: .verticalBeam(length: 22))
        case .resizeH:
            return UIPointerStyle(shape: .horizontalBeam(length: 22))
        case .resizeV:
            return UIPointerStyle(shape: .verticalBeam(length: 22))
        case .arrow:
            return UIPointerStyle(shape: .path(Self.arrowPointerPath()), constrainedAxes: [])
        }
    }

    /// The classic left_ptr silhouette, authored tip-first at the origin so it lands on
    /// the hotspot. Same outline as cursorImage(isText: false); a path shape is a single
    /// flat fill, so the white keyline that bitmap carries is not reproducible here.
    private static func arrowPointerPath() -> UIBezierPath {
        let p = UIBezierPath()
        p.move(to: CGPoint(x: 0, y: 0))
        p.addLine(to: CGPoint(x: 0, y: 18))
        p.addLine(to: CGPoint(x: 4.5, y: 13.5))
        p.addLine(to: CGPoint(x: 7.5, y: 20))
        p.addLine(to: CGPoint(x: 10, y: 19))
        p.addLine(to: CGPoint(x: 7, y: 12.5))
        p.addLine(to: CGPoint(x: 13, y: 12.5))
        p.close()
        return p
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

    private func makeTexture(width: Int, height: Int) {
        let td = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
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
        /// Present-side upscaling, forwarded by the compositor from IOSC_UPSCALE.
        /// Deliberately NOT part of renderStateChanged below: it changes only how the
        /// app scales its own drawable, so picking up a new value must not tear down
        /// and re-adopt the IOSurface.
        let upscale: String?
        init(_ obj: [String: Any]) {
            // Presence of "ddx":"iosurface" selects the zero-copy IOSurface path.
            isIOSurface = (obj["ddx"] as? String) == "iosurface"
            socket = (obj["socket"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            width = (obj["width"] as? Int).flatMap { $0 > 0 ? $0 : nil }
            height = (obj["height"] as? Int).flatMap { $0 > 0 ? $0 : nil }
            upscale = (obj["upscale"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
    }

    /// Last `upscale` hint the compositor advertised, kept so the mode can be
    /// re-resolved when the in-app choice changes without re-reading xios.json.
    private var compositorUpscaleHint: String?

    private static let upscaleDefaultsKey = "XiosUpscale"

    /// Resolve the upscale mode, most specific authority first:
    ///   1. the in-app choice — the user is the most specific authority there is, and
    ///      a settings toggle a compositor hint could override would be a lie;
    ///   2. XIOS_UPSCALE in our own environment, for a shell-launched debug run;
    ///   3. the compositor's xios.json hint (its IOSC_UPSCALE, forwarded);
    ///   4. off.
    private func resolveUpscaleMode() -> XiosUpscaleMode {
        if let raw = UserDefaults.standard.string(forKey: Self.upscaleDefaultsKey),
           !raw.isEmpty {
            return XiosUpscaleMode.parse(raw)
        }
        if let env = ProcessInfo.processInfo.environment["XIOS_UPSCALE"], !env.isEmpty {
            return XiosUpscaleMode.parse(env)
        }
        return XiosUpscaleMode.parse(compositorUpscaleHint)
    }

    /// Whether the user has made an explicit in-app choice (vs inheriting a hint).
    private var hasUpscalePreference: Bool {
        (UserDefaults.standard.string(forKey: Self.upscaleDefaultsKey) ?? "").isEmpty == false
    }

    /// Apply and persist an in-app choice. Takes effect on the NEXT FRAME — no session
    /// restart — because upscaling is present-side only: nothing about the compositor's
    /// output or any client's view of it changes. Passing nil clears the choice and
    /// falls back to the environment/compositor hint.
    private func setUpscalePreference(_ mode: XiosUpscaleMode?) {
        if let mode {
            UserDefaults.standard.set(mode.spec, forKey: Self.upscaleDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.upscaleDefaultsKey)
        }
        applyUpscaleMode(resolveUpscaleMode())
        lastToolMessage = upscaleMode.isOff
            ? "Rendering at full panel resolution"
            : "Rendering at \(upscaleMode.title) below panel, MetalFX scaling up"
    }

    private func applyUpscaleMode(_ mode: XiosUpscaleMode) {
        guard mode != upscaleMode else { return }
        upscaleMode = mode
        needsPresent = true
        syncUpscaler()
    }

    /// Make the MetalFX pass match `upscaleMode`. Idempotent, and deliberately safe to
    /// call before Metal exists: start() runs loadConfig() — and therefore
    /// applyUpscaleMode — BEFORE setupMetal(), so the first call for a config that asks
    /// for upscaling always arrives with no device yet. Attaching only from
    /// applyUpscaleMode left the upscaler permanently nil in exactly that case, because
    /// its `mode != upscaleMode` guard makes every later config poll a no-op; the mode
    /// was right and nothing was ever built from it. Hence a separate idempotent step,
    /// called again once Metal is up and on every foreground.
    private func syncUpscaler() {
        guard metalReady, let device else { return }
        if upscaleMode.isOff {
            guard upscaler != nil else { return }
            upscaler?.releaseResources()
            upscaler = nil
            metalLayer.framebufferOnly = true   // back to the cheaper direct-path drawable
            publishUpscaleStatus(nil)
            return
        }
        guard upscaler == nil else { return }
        // MetalFX writes the output texture, which framebufferOnly forbids. Only
        // relaxed while upscaling is on, so the default path keeps the tighter
        // drawable it has always had.
        metalLayer.framebufferOnly = false
        upscaler = XiosUpscaler(device: device)
        needsPresent = true
        if !XiosUpscaler.supported(device) {
            // Probed YES on the A10 target, but never assume: a device whose spatial
            // scaler says no degrades to the direct present, and says so.
            publishUpscaleStatus(nil)
        }
    }

    /// `upscale=` in the runtime status table. Upscaling changes what the user sees,
    /// so it is never allowed to be undiscoverable (docs/ios-platform-features.md §0).
    private func publishUpscaleStatus(_ plan: XiosUpscaler.Plan?) {
        let value: String
        if let upscaler, !upscaleMode.isOff {
            value = upscaler.statusValue(for: plan)
        } else {
            value = "off"
        }
        guard value != lastUpscaleStatus else { return }
        lastUpscaleStatus = value
        iosc_status_set_value("upscale", value)
    }

    @discardableResult
    private func loadConfig() -> Bool {
        guard let obj = readConfig() else { return false }
        let ddx = DDXFields(obj)

        let oldWidth = fbWidth
        let oldHeight = fbHeight
        let oldDisplay = xDisplay
        let oldIsIOSurface = ddxIsIOSurface
        let oldSocket = ddxSockPath
        let oldIoscSock = ioscInputSock
        let oldIoscClipSock = ioscClipboardSock
        let oldInputConfigurationError = inputConfigurationError
        let oldClipboardConfigurationError = clipboardConfigurationError

        resetConfigDefaults(resetDisplay: true)
        configuredTouchReplacesPointer = Self.parseTouchPointerPolicy(obj)
        if let w = ddx.width { fbWidth = w }
        if let h = ddx.height { fbHeight = h }
        ddxIsIOSurface = ddx.isIOSurface
        if let s = ddx.socket { ddxSockPath = s }
        // Keep the session's display label for diagnostics and display selection.
        if let d = obj["display"] as? String, !d.isEmpty { xDisplay = d }
        // Wayland compositors advertise their exact input endpoint. Never infer a
        // process-global socket from the DDX filename: slots can run concurrently,
        // and sending to the wrong compositor is worse than reporting a stale config.
        if ddxIsIOSurface {
            if let s = obj["input_socket"] as? String, !s.isEmpty {
                ioscInputSock = s
            } else {
                inputConfigurationError =
                    "config is missing input_socket; restart/update the compositor"
            }
            if let s = obj["clipboard_socket"] as? String, !s.isEmpty {
                ioscClipboardSock = s
            } else {
                clipboardConfigurationError =
                    "config is missing clipboard_socket; restart/update the compositor"
            }
        }
        if let sock = ioscInputSock {
            sock.withCString { sysint_set_iosc_socket($0) }
        } else {
            sysint_set_iosc_socket(nil)
        }

        let renderStateChanged = oldWidth != fbWidth || oldHeight != fbHeight ||
            oldIsIOSurface != ddxIsIOSurface || oldSocket != ddxSockPath
        let inputStateChanged = oldDisplay != xDisplay ||
            oldIoscSock != ioscInputSock || oldIoscClipSock != ioscClipboardSock ||
            oldInputConfigurationError != inputConfigurationError ||
            oldClipboardConfigurationError != clipboardConfigurationError
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
        // After the render/input decisions, because it deliberately does not
        // participate in them: flipping the upscale knob must not re-adopt the surface.
        compositorUpscaleHint = ddx.upscale
        applyUpscaleMode(resolveUpscaleMode())
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
        if let c = xconn {
            _ = submitHeldStreamRelease(c)
            xsurface_close(c)
            xconn = nil
        }
        iosurfaceCompositorID = ""
        iosTexture = nil
        iosSurfaceID = 0
        iosSurfaceFlags = 0
        presentFenceToken = nil
        presentFenceEvent = nil
        releaseFenceToken = nil
        releaseFenceEvent = nil
        pendingStreamFrame = false
        heldStreamFrame = nil
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

    @objc private func tick(_ link: CADisplayLink) {
        guard !appIsBackgrounded else { return }
        tickCount += 1
        sendPacing(link)
        serviceIoscClipboard()
        serviceIoscInputTraits()
        if inputConnected && !iosc_input_is_open() {
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
            if tickCount % 30 == 0 {
                if releasePinIfDisplayGone() { return }
                if !userPinned, ddxConfigChanged() {
                    teardownIOSurface()
                    return
                }
            }
            guard let conn = xconn else { return }
            var r: Int32 = 0
            if !pendingStreamFrame {
                r = xsurface_drain(conn)
                if r < 0 { teardownIOSurface(lost: true); return }
                if r > 0 {
                    /* The newly acquired frame replaces the one we retained for
                     * idle redraws. Submit the previous consumer-release fence
                     * now; the empty command buffer is ordered after every Metal
                     * sample of that IOSurface on `queue`. */
                    if !submitHeldStreamRelease(conn) {
                        teardownIOSurface(lost: true)
                        return
                    }
                    pendingStreamFrame = true
                    needsPresent = true
                }
            }
            if !syncSurfaceGeometry(conn) { teardownIOSurface(); return }
            // Reposition the cursor overlay independently of surface damage: a pure
            // pointer move updates the CALayer without re-presenting the framebuffer.
            updateCursorOverlay(conn)
            guard let tex = iosTexture else { return }
            if needsPresent {
                let seq = xsurface_dirty_sequence(conn)
                // The IOSurface arrives before the compositor's first DIRTY
                // record. Never sample that asynchronously rendered surface
                // until its matching brokered GPU fence has arrived; an empty
                // sequence here is startup ordering, not a malformed frame.
                if seq == 0 {
                    return
                }
                let fence = gpuFence(for: conn)
                if presentFenceDecodeFailed {
                    dbg("gpu-fence-decode-failed")
                    teardownIOSurface(lost: true)
                    return
                }
                if render(tex,
                          presentedSeq: seq,
                          conn: conn,
                          waitEvent: fence?.0,
                          waitValue: fence?.1 ?? 0,
                          flipY: (iosSurfaceFlags & UInt32(XIOS_SURFACE_FLAG_FLIP_Y)) != 0) {
                    needsPresent = false
                    if pendingStreamFrame {
                        heldStreamFrame = (iosSurfaceID, seq)
                        pendingStreamFrame = false
                    }
                }
            }
            return
        }

        // Poll for the IOSurface backend. Reached only while the holding frame is live.
        if tickCount % 30 == 0 {
            if releasePinIfDisplayGone() { return }
            if !userPinned { _ = loadConfig() }   // auto mode picks up xios.json; a manual
                                              // pick keeps its own display/backend choice
            let testWidth = awaitingCompositor ? 1 : fbWidth
            let testHeight = awaitingCompositor ? 1 : fbHeight
            if usingTestPattern,
               texture?.width != testWidth || texture?.height != testHeight {
                startTestPattern()
            }
            if ddxIsIOSurface {
                startIOSurfaceConnect()
            } else {
                awaitingCompositor = true
            }
        }
        // Keep the test buffer aligned with what will actually be uploaded: a 1x1
        // black texture while a compositor is absent, or a full-size animated
        // diagnostic only outside that normal launch/switch state. This check still
        // guards the historical resize overflow, without allocating ~50 MB of CPU+GPU
        // holding storage beside a new KDE compositor.
        let testWidth = awaitingCompositor ? 1 : fbWidth
        let testHeight = awaitingCompositor ? 1 : fbHeight
        if usingTestPattern,
           texture?.width != testWidth || texture?.height != testHeight {
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

        texture.replace(region: MTLRegionMake2D(0, 0, texture.width, texture.height),
                        mipmapLevel: 0, withBytes: base, bytesPerRow: texture.width * 4)
        if render(texture) { needsPresent = false }
    }

    /// Hand the compositor this tick's deadline so its coalesced repaint can be
    /// vblank-paced instead of event-loop paced (P0.4). Sent first thing in the tick,
    /// while `targetTimestamp` still describes the frame we are about to build.
    ///
    /// Everything on the wire is a delta from *now*: `targetTimestamp` lives in
    /// CACurrentMediaTime()'s domain and the compositor works in CLOCK_MONOTONIC, so
    /// a delta is the only thing both sides can read without a shared epoch.
    private func sendPacing(_ link: CADisplayLink) {
        guard let conn = xconn else { return }
        // duration is the link's own idea of the interval; targetTimestamp - timestamp
        // is what it actually got this tick. Prefer the latter and fall back.
        var interval = link.targetTimestamp - link.timestamp
        if !(interval > 0) { interval = link.duration }
        guard interval > 0, interval < 1 else { return }   // no clock yet, or nonsense

        let untilDeadline = link.targetTimestamp - CACurrentMediaTime()
        let untilUs = (untilDeadline * 1_000_000).rounded()
        let intervalUs = UInt32((interval * 1_000_000).rounded())
        lastLinkIntervalUs = intervalUs

        _ = xsurface_pacing(conn,
                            Int32(clamping: Int(untilUs.isFinite ? untilUs : 0)),
                            intervalUs,
                            Int32((pacingRange.minimum * 1000).rounded()),
                            Int32((pacingRange.maximum * 1000).rounded()))
        // Republish once the real interval is known, so `pacing=` reports the rate
        // CoreAnimation settled on rather than only the range we asked for.
        if tickCount % 120 == 0 { publishPacingStatus() }
    }

    /// Draw the texture using the current fit/zoom/pan transform.
    private func gpuFence(for conn: OpaquePointer) -> (MTLSharedEvent, UInt64)? {
        presentFenceDecodeFailed = false
        var bytes: UnsafeRawPointer?
        var length = 0
        var value: UInt64 = 0
        guard xsurface_gpu_fence_token(conn, &bytes, &length, &value) != 0 else {
            dbg("gpu-fence-missing-for-frame")
            presentFenceDecodeFailed = true
            return nil
        }
        guard let bytes, length > 0, value > 0 else {
            presentFenceDecodeFailed = true
            return nil
        }

        let token = Data(bytes: bytes, count: length)
        if token != presentFenceToken {
            guard let event = xios_metal_event_broker_copy_event(
                device, bytes, length
            ) else {
                dbg("gpu-fence-broker-import-failed")
                presentFenceDecodeFailed = true
                return nil
            }
            presentFenceToken = token
            presentFenceEvent = event
        }
        guard let event = presentFenceEvent else {
            presentFenceDecodeFailed = true
            return nil
        }
        return (event, value)
    }

    @discardableResult
    private func render(_ tex: MTLTexture,
                        presentedSeq: UInt64 = 0,
                        conn: OpaquePointer? = nil,
                        waitEvent: MTLSharedEvent? = nil,
                        waitValue: UInt64 = 0,
                        flipY: Bool = false) -> Bool {
        let presentInterval = signposter.beginInterval("present")
        defer { signposter.endInterval("present", presentInterval) }
        guard let drawable = metalLayer.nextDrawable(),
              let cmd = queue.makeCommandBuffer(),
              let fit = fitTransform(),
              var verts = fit.clipVertices() else { return false }
        if let waitEvent, waitValue > 0 {
            cmd.encodeWaitForEvent(waitEvent, value: waitValue)
        }
        if flipY {
            /* clipVertices is TL,BL,TR,BR with pos.xy/uv.xy. Client GL
             * IOSurfaces have bottom-left content; swap only each V component. */
            for index in stride(from: 3, to: verts.count, by: 4) {
                verts[index] = 1 - verts[index]
            }
        }
        // Optional MetalFX stage: composite into a smaller intermediate and let the
        // spatial scaler blow it up to the drawable. The fit transform needs no
        // adjustment — clipVertices() is in normalised device coordinates, and the
        // intermediate is a uniform scale of the drawable, so the same vertices frame
        // the desktop identically in both. A nil plan is the direct present, which is
        // the default and what every failure path degrades to.
        let plan = upscaler?.plan(
            mode: upscaleMode,
            drawableWidth: Int(metalLayer.drawableSize.width),
            drawableHeight: Int(metalLayer.drawableSize.height),
            sourceWidth: tex.width,
            sourceHeight: tex.height,
            drawableTexture: drawable.texture,
            pixelFormat: metalLayer.pixelFormat)
        publishUpscaleStatus(plan)

        // triangle strip: TL, BL, TR, BR  (pos.xy, uv.xy); uv origin top-left
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = plan?.source ?? drawable.texture
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        rpd.colorAttachments[0].storeAction = .store
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return false }
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBytes(&verts, length: verts.count * MemoryLayout<Float>.size, index: 0)
        enc.setFragmentTexture(tex, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
        if let plan, let upscaler {
            let up = signposter.beginInterval("upscale")
            upscaler.encode(plan, into: drawable.texture, commandBuffer: cmd)
            signposter.endInterval("upscale", up)
        }
        if let conn, presentedSeq != 0 {
            // Ack on the DRAWABLE's presented handler, not the command buffer's
            // completed handler. Completion means "the GPU finished rendering"; the
            // presentation-time protocol asks for the moment the content actually
            // reached the display, which is what presentedTime reports — acking at
            // completion is how the old feedback ran up to a frame early. Moving the
            // ack here is also what makes wl_surface.frame callbacks retire on
            // present rather than on repaint, which is the rest of P0.4.
            //
            // The handler fires even for a drawable that never made it to the panel
            // (presentedTime == 0), which is the case worth acking without a
            // measurement rather than not at all. If the process is suspended before
            // it runs at all, iosc's existing 100ms present-ack valve retires the
            // callbacks — that valve is exactly the safety net this needs, so there
            // is no second ack path here to race with.
            drawable.addPresentedHandler { [weak self] presented in
                let at = presented.presentedTime
                DispatchQueue.main.async {
                    guard let self, self.xconn == conn else { return }
                    guard at > 0 else {
                        _ = xsurface_presented(conn, presentedSeq)
                        return
                    }
                    let ageUs = (max(0, CACurrentMediaTime() - at) * 1_000_000).rounded()
                    _ = xsurface_presented_at(
                        conn, presentedSeq,
                        UInt32(clamping: Int(ageUs.isFinite ? ageUs : 0)))
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
            inp = "input-configuration-missing"
        }
        var lines = [fb, inp]
        if let error = inputConfigurationError {
            lines.append("configuration-error \(error)")
        }
        if let error = clipboardConfigurationError {
            lines.append("configuration-error \(error)")
        }
        try? (lines.joined(separator: "\n") + "\n").write(
            toFile: XiosRuntimePaths.tmp("xios-status.txt"),
            atomically: true,
            encoding: .utf8)
        refreshShellOverlay()
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

    private func sessionDisplaySummary() -> String {
        if let p = pendingSessionDisplay {
            return "\(p.name): \(p.detail)" + (p.dpi > 0 ? " at \(p.dpi) DPI" : "")
        }
        return "Each desktop uses its own default size"
    }

    /// Blocking worker primitive. UI actions dispatch this through requestIOSCD.
    /// `stopAtNewline` returns as soon as one complete line is in hand instead
    /// of reading to EOF. Single-reply verbs (SESSION) use it so the picker
    /// never waits on the daemon closing the connection — a session child that
    /// inherits the socket would otherwise stall the reply to the recv timeout.
    /// Streaming verbs (APPS_LIST/APPS_SYNC) still need the read-to-EOF path.
    private func sendIOSCDRequest(_ line: String, maxBytes: Int = 1 << 20,
                                  timeout: TimeInterval = 2.0,
                                  stopAtNewline: Bool = false) -> String? {
        let fd = xiosConnectUnixSocket(ioscdSocketPath, timeout: timeout)
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
                if stopAtNewline, data.contains(UInt8(ascii: "\n")) { break }
            } else if n < 0 && errno == EINTR {
                continue
            } else if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                return nil
            } else {
                break
            }
        }
        return String(data: data, encoding: .utf8)
    }

    private func requestIOSCD(_ line: String, maxBytes: Int = 1 << 20,
                              timeout: TimeInterval = 2.0,
                              stopAtNewline: Bool = false,
                              completion: @escaping (String?) -> Void) {
        ioscdRequestQueue.async { [weak self] in
            guard let self else { return }
            let response = self.sendIOSCDRequest(
                line, maxBytes: maxBytes, timeout: timeout,
                stopAtNewline: stopAtNewline)
            DispatchQueue.main.async {
                completion(response)
            }
        }
    }

    private func parseIOSCDResponseLines(_ response: String?) -> [String]? {
        response?.split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .newlines) }
            .filter { !$0.isEmpty }
    }

    private func requestIOSCDLines(_ line: String, timeout: TimeInterval = 2.0,
                                   completion: @escaping ([String]?) -> Void) {
        requestIOSCD(line, timeout: timeout) { [weak self] response in
            completion(self?.parseIOSCDResponseLines(response))
        }
    }

    private func sessionRequestLine(_ preset: String, app: String?,
                                    display: DisplayProfile?,
                                    slot: String? = nil) -> String {
        var width = ""
        var height = ""
        var dpi = ""
        if preset != "app", preset != "stop", let display {
            width = String(display.width)
            height = String(display.height)
            if display.dpi > 0 { dpi = String(display.dpi) }
        }
        return ["SESSION", preset, app ?? "", width, height, dpi, slot ?? ""]
            .joined(separator: "\t") + "\n"
    }

    /// Pick a desktop flavor from the device through ioscd's request/reply socket.
    private func writeSessionRequest(_ preset: String, app: String? = nil,
                                     display: DisplayProfile? = nil,
                                     slot: String? = nil,
                                     completion: ((Bool) -> Void)? = nil) {
        guard !sessionRequestInFlight else {
            lastToolMessage = "A desktop request is already being sent"
            toolMessageLabel?.text = lastToolMessage
            completion?(false)
            return
        }
        sessionRequestInFlight = true
        let requestDescription: String
        switch preset {
        case "app": requestDescription = "Opening \(app ?? "app")…"
        case "stop": requestDescription = "Stopping desktop…"
        case "resize": requestDescription = "Resizing desktop…"
        default: requestDescription = "Starting \(desktopLabel(preset))…"
        }
        lastToolMessage = requestDescription
        toolMessageLabel?.text = requestDescription
        if preset != "app" {
            startSessionIndicator()
        }

        let line = sessionRequestLine(preset, app: app, display: display, slot: slot)
        requestIOSCD(line, maxBytes: 4096, stopAtNewline: true) { [weak self] rawResponse in
            guard let self else { return }
            self.sessionRequestInFlight = false
            let response = rawResponse?.trimmingCharacters(in: .whitespacesAndNewlines)
            if response?.hasPrefix("SESSION_STARTED") == true ||
                response?.hasPrefix("SESSION_ACTIVE") == true {
                if preset == "app" {
                    self.lastToolMessage = "Launch requested: \(app ?? "app")"
                } else {
                    self.lastToolMessage = "Session: \(preset)"
                        + (slot.map { " slot=\($0)" } ?? "")
                        + (display.map { " \($0.detail)" } ?? "")
                    self.startSessionIndicator()
                }
                completion?(true)
            } else {
                let detail = response?.isEmpty == false ? response! : "ioscd timed out"
                self.lastToolMessage = "Session request failed: \(detail)"
                completion?(false)
            }
            self.toolMessageLabel?.text = self.lastToolMessage
            self.refreshShellOverlay()
            self.writeDebugSnapshot()
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
        if ddxIsIOSurface, !usingIOSurface {
            awaitingCompositor = true
            startIOSurfaceConnect()
        }
        if !ddxIsIOSurface { awaitingCompositor = true; startTestPattern() }
        connectInput()
        needsPresent = true
        writeStatus()
    }

    /// Tear down connections tied to the compositor input endpoint.
    private func closeInput() {
        hardwareKeyboard.releasePressedKeys()
        releaseHardwarePointerButtons()
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
        if inputConfigurationError != nil { return "misconfigured" }
        return usingIosc ? "iosc" : "not-configured"
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
        // Plasma Desktop is still a mouse-first shell on this stack. Sending a
        // real wl_touch sequence there made taps depend on KWin/Qt touch
        // activation while the proven pointer lane sat idle. Mobile is the
        // touch-native flavor and keeps the direct wl_touch path.
        return preset == "kde-mobile"
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
            UIAction(title: "Open Xios", image: UIImage(systemName: "rectangle.3.group")) {
                [weak self] _ in self?.presentDisplayControl()
            },
            UIAction(title: "Open an App...", image: UIImage(systemName: "square.grid.2x2")) {
                [weak self] _ in self?.presentAppLauncher()
            },
            UIAction(title: "Show Keyboard", image: UIImage(systemName: "keyboard")) { [weak self] _ in
                _ = self?.becomeFirstResponder()
            },
            UIAction(title: "Paste", image: UIImage(systemName: "doc.on.clipboard"),
                     attributes: pasteAttrs) { [weak self] _ in
                self?.sendText(pasteString ?? "")
            },
            UIAction(title: "Fit to Screen",
                     image: UIImage(systemName: "arrow.up.left.and.arrow.down.right")) { [weak self] _ in
                self?.resetZoom()
                self?.lastToolMessage = "Fit current display"
                self?.refreshShellOverlay()
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

        children.append(UIAction(title: "Advanced...",
                                 image: UIImage(systemName: "slider.horizontal.3")) {
            [weak self] _ in self?.presentAdvanced()
        })

        if activeDesktopPreset() != nil {
            children.append(UIAction(title: "Stop Desktop", image: UIImage(systemName: "stop.circle"),
                                     attributes: [.destructive]) { [weak self] _ in
                self?.writeSessionRequest("stop")
            })
        }

        return UIMenu(title: "", children: children)
    }

    private func debugSnapshot() -> String {
        let ds = metalLayer.drawableSize
        let nb = UIScreen.main.nativeBounds
        let cfg = (try? String(contentsOfFile: configPath, encoding: .utf8))?
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
            // Which config the app is actually following. A pin outliving its
            // compositor reads as a frozen, tap-deaf desktop, so name it explicitly.
            "config=\(configPath) pinned=\(userPinned)",
            "ddx_socket=\(ddxSockPath)",
            "iosc_input=\(ioscInputSock ?? "(none)")",
            "iosc_clipboard=\(ioscClipboardSock ?? "(none)")",
            "input_configuration_error=\(inputConfigurationError ?? "(none)")",
            "clipboard_configuration_error=\(clipboardConfigurationError ?? "(none)")",
            "test_pattern=\(usingTestPattern)",
            "last_message=\(lastToolMessage)",
            "xios_json=\(cfg)",
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

    // MARK: compositor input

    private func connectInput() {
        guard inputConfigurationError == nil, let sock = ioscInputSock else {
            inputConnected = false
            return
        }
        if inputConnected && iosc_input_is_open() { return }
        inputConnected = iosc_input_open(sock)
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

    private func sendMotion(_ x: Int32, _ y: Int32) {
        iosc_input_motion(x, y)
    }
    private func sendButton(_ button: Int32, _ down: Bool, at p: (Int32, Int32)?) {
        let q = p ?? lastTouchPt ?? (Int32(0), Int32(0))
        iosc_input_button(button, down, q.0, q.1)
    }
    private func sendKeysym(_ ks: UInt, ctrl: Bool, alt: Bool, shift: Bool) {
        var mods: UInt32 = 0
        if shift { mods |= 1 }; if ctrl { mods |= 2 }; if alt { mods |= 4 }
        // Accessory/OSK keys are taps. Hardware uses sendHardwareKey() below
        // and preserves independent down/up transitions.
        iosc_input_key(UInt32(ks), true, mods)
        iosc_input_key(UInt32(ks), false, 0)
    }

    private func sendHardwareKey(_ keysym: UInt32, down: Bool, modifiers: UInt32) {
        guard inputConnected else { return }
        iosc_input_key(keysym, down, modifiers)
    }

    private func sendText(_ text: String) {
        guard inputConnected else { return }
        text.withCString { iosc_input_text($0) }
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
        guard inputConnected else { return }
        let step: Int32 = 36 * 256
        switch button {
        case 4: iosc_input_axis(0, -step, 1, 0, false)
        case 5: iosc_input_axis(0, step, 1, 0, false)
        case 6: iosc_input_axis(-step, 0, 1, 0, false)
        case 7: iosc_input_axis(step, 0, 1, 0, false)
        default: return
        }
        iosc_input_axis(0, 0, 1, 0, true)
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
        needsPresent = true
    }

    /// dx/dy are view-point finger deltas. AXIS records use 1/256 framebuffer
    /// pixels with wl_pointer's sign (fingers up means content scrolls down).
    private func sendScroll(dx: CGFloat, dy: CGFloat, source: UInt32) {
        guard inputConnected else { return }
        guard let fit = fitTransform(), fit.scale > 0 else { return }
        let ptToFb = 256 / fit.scale
        axisRemainder.x -= dx * ptToFb
        axisRemainder.y -= dy * ptToFb
        let sx = axisRemainder.x.rounded(.towardZero)
        let sy = axisRemainder.y.rounded(.towardZero)
        if sx != 0 || sy != 0 {
            axisRemainder.x -= sx
            axisRemainder.y -= sy
            axisSource = source
            iosc_input_axis(Int32(sx), Int32(sy), source, 0, false)
            axisActive = true
        }
    }

    /// Fingers left the glass: end the axis gesture so clients kinetic-fling.
    private func sendScrollStop() {
        axisRemainder = .zero
        guard axisActive else { return }
        axisActive = false
        if inputConnected && usingIosc { iosc_input_axis(0, 0, axisSource, 0, true) }
        axisSource = 0
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
        // Hover means the pointer is moving with no touch of its own. If a button is
        // still marked down here the press outlived its touch (a cancelled sequence, or
        // a release UIKit never delivered), and every motion from now on would be a
        // drag: let it go before moving.
        if hardwareButtonMask != 0 && !hardwarePointerTouchDown {
            releaseHardwarePointerButtons()
        }
        guard inputConnected, let (x, y) = framebufferPoint(from: g.location(in: self)) else { return }
        lastTouchPt = (x, y)
        sendMotion(x, y)
    }

    /// Whether an `.indirectPointer` touch is starting, continuing, or finished.
    private enum HardwarePointerPhase { case down, move, up }

    @available(iOS 13.4, *)
    private func handleHardwarePointer(_ touches: Set<UITouch>, event: UIEvent?,
                                      phase: HardwarePointerPhase) -> Bool {
        guard let touch = touches.first(where: { $0.type == .indirectPointer }) else { return false }
        activateCursorOverlayForHardwarePointer()
        if inputConnected, let point = framebufferPoint(from: touch.location(in: self)) {
            lastTouchPt = point
            sendMotion(point.0, point.1)
        }
        hardwarePointerTouchDown = phase != .up
        updateHardwarePointerButtons(hardwarePointerMask(event, phase: phase))
        return true
    }

    /// Button state for a mouse/trackpad press. The touch phase is authoritative and
    /// `buttonMask` only refines it: an `.indirectPointer` touch exists solely while a
    /// button is held, so a press with an empty mask is still a press and an ended touch
    /// is always all-up. Deriving the state from the mask alone latched the button down
    /// on the first click, which made every later hover a drag-select and meant no click
    /// ever activated anything (the press landed, the release never did).
    private func hardwarePointerMask(_ event: UIEvent?, phase: HardwarePointerPhase) -> Int {
        if phase == .up { return 0 }
        let mask = event?.buttonMask.rawValue ?? 0
        if mask != 0 { return mask }
        // Something is held but iPadOS did not say which: keep what we had, else assume
        // the primary button (bit 0).
        return hardwareButtonMask != 0 ? hardwareButtonMask : 1
    }

    private func updateHardwarePointerButtons(_ nextMask: Int) {
        let changed = hardwareButtonMask ^ nextMask
        guard changed != 0 else { return }
        let ioscButtons: [Int32] = [1, 3, 2, 0x113, 0x114]
        for index in 0..<ioscButtons.count where changed & (1 << index) != 0 {
            let down = nextMask & (1 << index) != 0
            sendButton(ioscButtons[index], down, at: lastTouchPt)
        }
        hardwareButtonMask = nextMask
    }

    private func releaseHardwarePointerButtons() {
        hardwarePointerTouchDown = false
        guard hardwareButtonMask != 0 else { return }
        updateHardwarePointerButtons(0)
    }

    // MARK: trackpad gestures (pinch / rotate -> zwp_pointer_gestures_v1)

    /// wl_pointer wants ONE gesture carrying both scale and rotation, but UIKit reports
    /// them through two independent recognizers that can run simultaneously. They share
    /// this state: whichever starts first opens the Wayland gesture, whichever ends last
    /// closes it.
    private var trackpadGestureActive = 0
    private var trackpadPinchScale: CGFloat = 1
    private var trackpadRotationDegrees: CGFloat = 0
    private var trackpadGestureCenter: CGPoint?

    /// A pinch or rotate with no touches on the glass came from the trackpad — the same
    /// test the indirect scroll recognizers use. Finger pinches keep zooming our own
    /// framebuffer; only indirect ones are the compositor's business.
    private func isTrackpadGesture(_ g: UIGestureRecognizer) -> Bool {
        g.numberOfTouches == 0 && usingIosc && inputConnected
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

    private enum XiosGesturePhase {
        static let begin: UInt32 = 0, update: UInt32 = 1, end: UInt32 = 2, cancel: UInt32 = 3
    }

    /// One gesture frame. Scale and rotation are absolute since begin — UIKit reports
    /// them that way and so does wl_pointer, so neither needs accumulating. Translation
    /// is the centre's movement since the previous frame, converted pt->fb px through the
    /// same fit transform scroll uses.
    private func sendTrackpadGesture(phase: UInt32, at point: CGPoint? = nil) {
        guard inputConnected, usingIosc else { return }
        var dx256: Int32 = 0, dy256: Int32 = 0
        if let point, let last = trackpadGestureCenter, let fit = fitTransform(), fit.scale > 0 {
            let ptToFb = 256 / fit.scale
            dx256 = Int32(clamping: Int(((point.x - last.x) * ptToFb).rounded()))
            dy256 = Int32(clamping: Int(((point.y - last.y) * ptToFb).rounded()))
        }
        if let point { trackpadGestureCenter = point }
        let scale256 = UInt32(max(0, (trackpadPinchScale * 256).rounded()))
        let rot256 = Int32(clamping: Int((trackpadRotationDegrees * 256).rounded()))
        iosc_input_gesture(2 /* pinch */, phase, 2, dx256, dy256, scale256, rot256)
    }

    /// Rotation reaches us only if iPadOS forwards two-finger trackpad rotation to the
    /// recognizer. If it does not this simply never fires and pinch still works alone,
    /// since the scale and rotation fields are independent.
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

    @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
        // Trackpad pinch belongs to the desktop (KDE/GTK zoom); finger pinch stays ours.
        // The second test keeps a gesture that a rotation opened flowing through the same
        // path even if this recognizer's touch count is read at an awkward moment.
        if isTrackpadGesture(g) || (trackpadGestureActive > 0 && g.numberOfTouches == 0) {
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
            return
        }
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
        let isIndirectScroll = g.numberOfTouches == 0
        let source: UInt32 = (g === discreteScrollPan) ? 1 : 0
        switch g.state {
        case .began:
            twoFingerBegan()
            panStartOffset = panOffset
            panLastTranslation = .zero
            axisRemainder = .zero
        case .changed:
            let t = g.translation(in: self)
            if zoomScale > 1.01 {
                panOffset = clampedPanOffset(
                    CGPoint(x: panStartOffset.x + t.x, y: panStartOffset.y + t.y),
                    zoom: zoomScale)
                needsPresent = true
            } else {
                if twoFingerMode == .undecided, isIndirectScroll || abs(t.x) + abs(t.y) > 12 {
                    twoFingerMode = .scroll
                    if let (x, y) = framebufferPoint(from: g.location(in: self)) {
                        lastTouchPt = (x, y)
                        sendMotion(x, y)   // focus the surface under the fingers
                    }
                }
                if twoFingerMode == .scroll {
                    sendScroll(dx: t.x - panLastTranslation.x,
                               dy: t.y - panLastTranslation.y,
                               source: source)
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
        if #available(iOS 13.4, *), handleHardwarePointer(touches, event: event, phase: .down) { return }
        suppressCursorOverlayForTouchFirstInput(touches)
        if appGestureTouchSuppression { return }
        if (event?.allTouches?.count ?? touches.count) >= 3 {
            beginAppGestureSuppression(event: event)
            return
        }
        let touchCount = event?.allTouches?.count ?? touches.count
        let touchConsumesPointer = shouldTouchReplacePointer(for: touches)
        let directPointerOnly = touchCount == 1 && !touchConsumesPointer
            && touches.allSatisfy { $0.type == .direct }
        activeDirectTouchUsesPointer = directPointerOnly
        if !directPointerOnly && forwardIoscAll(touches, phase: 1, event: event) {
            activeTouchReplacesPointer = touchConsumesPointer
            if touchConsumesPointer { return }
        }
        guard touchCount == 1 else {
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
        if #available(iOS 13.4, *), handleHardwarePointer(touches, event: event, phase: .move) { return }
        suppressCursorOverlayForTouchFirstInput(touches)
        if appGestureTouchSuppression { return }
        if !activeDirectTouchUsesPointer,
           forwardIoscAll(touches, phase: 2, event: event),
           activeTouchReplacesPointer { return }
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
        if #available(iOS 13.4, *), handleHardwarePointer(touches, event: event, phase: .up) { return }
        suppressCursorOverlayForTouchFirstInput(touches)
        if appGestureTouchSuppression {
            if allTouchesEndedOrCancelled(event) { appGestureTouchSuppression = false }
            return
        }
        if !activeDirectTouchUsesPointer,
           forwardIoscAll(touches, phase: 0, event: event),
           activeTouchReplacesPointer {
            if allTouchesEndedOrCancelled(event) { activeTouchReplacesPointer = false }
            return
        }
        guard inputConnected else { cancelPendingPress(); longPressFired = false; return }
        if longPressFired { longPressFired = false; return }
        if pendingPress != nil { flushPendingPress() }   // stationary tap = click
        releaseLeftPress()
        if allTouchesEndedOrCancelled(event) {
            activeTouchReplacesPointer = false
            activeDirectTouchUsesPointer = false
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        if #available(iOS 13.4, *), handleHardwarePointer(touches, event: event, phase: .up) {
            return
        }
        suppressCursorOverlayForTouchFirstInput(touches)
        if appGestureTouchSuppression {
            if allTouchesEndedOrCancelled(event) {
                appGestureTouchSuppression = false
                touchSlots.removeAll()
                activeTouchReplacesPointer = false
                activeDirectTouchUsesPointer = false
            }
            return
        }
        if !activeDirectTouchUsesPointer,
           forwardIoscAll(touches, phase: 3, event: event),
           activeTouchReplacesPointer {
            if allTouchesEndedOrCancelled(event) { activeTouchReplacesPointer = false }
            return
        }
        cancelPointerInteraction()
        if allTouchesEndedOrCancelled(event) {
            activeTouchReplacesPointer = false
            activeDirectTouchUsesPointer = false
        }
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

    /// One visible compositor target from xios-displays.d or the active xios.json.
    private struct XDisplayInfo {
        let number: Int
        let config: [String: Any]?
        let configPath: String?
        let slot: String?
        let preset: String?
        let state: String?
        let wayland: String?
        /// The xios-displays.d entry this row came from, for removing a dead one.
        let registryPath: String?
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
                wayland: obj["wayland"] as? String,
                registryPath: registryPath)
        }
    }

    /// Discover only compositor outputs with renderable xios.json state. Raw X
    /// sockets belong to nested Xwayland and are never standalone display targets.
    private func discoverDisplays() -> [XDisplayInfo] {
        let cfg = readConfig()
        let cfgDisplay = cfg?["display"] as? String
        let cfgNumber = cfgDisplay.flatMap { value in
            value.hasPrefix(":") ? Int(value.dropFirst()) : nil
        } ?? -1
        var rows: [XDisplayInfo] = cfg.map {
            [XDisplayInfo(number: cfgNumber, config: $0, configPath: configPath,
                          slot: nil, preset: nil, state: nil, wayland: nil,
                          registryPath: nil)]
        } ?? []
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
        ioscInputSock = nil
        ioscClipboardSock = nil
        inputConfigurationError = nil
        clipboardConfigurationError = nil
        sysint_set_iosc_socket(nil)
        XiosRuntimePaths.tmp("xios-sysint.sock").withCString {
            sysint_set_sysint_socket($0)
        }
        if resetDisplay { xDisplay = ":3" }
    }

    /// Drop every connection tied to the current display so we can load another.
    private func teardownConnections(resetTransform: Bool = true) {
        closeInput()
        if let c = xconn {
            _ = submitHeldStreamRelease(c)
            xsurface_close(c)
            xconn = nil
        }
        removeCursorOverlay()
        iosTexture = nil
        iosSurfaceID = 0
        iosSurfaceFlags = 0
        presentFenceToken = nil
        presentFenceEvent = nil
        releaseFenceToken = nil
        releaseFenceEvent = nil
        pendingStreamFrame = false
        heldStreamFrame = nil
        usingIOSurface = false; iosConnectStarted = false; needsPresent = false
        testBuf?.deallocate(); testBuf = nil
        usingTestPattern = false
        if resetTransform { resetZoom() }
    }

    /// Switch to a compositor output the user picked.
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
            awaitingCompositor = true
            if ddxIsIOSurface {
                startTestPattern()
                startIOSurfaceConnect()
            } else {
                awaitingCompositor = true
                startTestPattern()
            }
        } else { startTestPattern() }
        connectInput()
        writeStatus()
    }

    /// Is anything actually serving this row? A slot's registry entry outlives its
    /// processes (the launcher only deletes it on a clean stop), so "live" means the
    /// Wayland socket is still there, or we can still read its display config.
    private func displayIsLive(_ d: XDisplayInfo) -> Bool {
        if let wayland = d.wayland,
           FileManager.default.fileExists(atPath: XiosRuntimePaths.tmp(wayland)) {
            return true
        }
        if d.config != nil { return true }
        return !(d.state == "stopped" || d.state == "error" || d.state == nil)
    }

    /// Stop one display. A slot stops on its own — `xios-session` reaps that slot's
    /// process groups, its sockets and its registry entry, and ioscd treats slotted
    /// requests as non-destructive so it always honors them. A row with no slot is
    /// the shared session, so stopping it stops everything.
    private func stopDisplay(_ d: XDisplayInfo) {
        if let slot = d.slot {
            writeSessionRequest("stop", slot: slot)
        } else {
            writeSessionRequest("stop")
        }
        unpinIfShowing(d)
        presentAdvanced()
    }

    /// Drop a dead slot's `xios-displays.d` entry so it stops appearing. Only offered
    /// for slots nothing is serving — a live one has to be stopped first, or its
    /// processes would keep running with no way back to them.
    private func removeDisplayFromList(_ d: XDisplayInfo) {
        guard let path = d.registryPath else { return }
        let name = d.slot ?? pathBasename(path)
        do {
            try FileManager.default.removeItem(atPath: path)
            lastToolMessage = "Removed \(name) from the list"
        } catch {
            lastToolMessage = "Could not remove \(name): \(error.localizedDescription)"
        }
        unpinIfShowing(d)
        presentAdvanced()
    }

    /// If we were pinned to the display that just went away, stop following it and
    /// fall back to whatever xios.json points at.
    private func unpinIfShowing(_ d: XDisplayInfo) {
        guard d.configPath != nil, d.configPath == selectedConfigPath else { return }
        releasePin(reason: nil)
    }

    private func releasePin(reason: String?) {
        userPinned = false
        selectedConfigPath = nil
        pinnedDeadPolls = 0
        if let reason {
            lastToolMessage = reason
            toolMessageLabel?.text = reason
        }
        reloadRuntimeConfig()
    }

    /// A pinned display can also go away without the app ever being told: a slot
    /// stopped over SSH (or reaped after a crash) has its config and sockets deleted,
    /// and Stop/Remove in Advanced — the only paths that dropped the pin — never ran.
    /// The pin then outlived its compositor, so every config reload read a dead path:
    /// the app held its last frame forever with `input-not-connected`, which on the
    /// glass looks exactly like a desktop that stopped responding to taps.
    /// Poll the pinned display and fall back to the live session once it is gone.
    /// Returns true when the pin was dropped (the caller's poll state is now stale).
    private func releasePinIfDisplayGone() -> Bool {
        guard userPinned, let path = selectedConfigPath else {
            pinnedDeadPolls = 0
            return false
        }
        let fm = FileManager.default
        // The launcher deletes a stopped slot's config; a crash can leave it behind,
        // but never its DDX socket. Either one missing means nothing is serving it.
        var gone = true
        if let obj = readConfig(path: path) {
            gone = DDXFields(obj).socket.map { !fm.fileExists(atPath: $0) } ?? true
        }
        guard gone else {
            pinnedDeadPolls = 0
            return false
        }
        pinnedDeadPolls += 1
        guard pinnedDeadPolls >= Self.pinnedDeadPollsToRelease else { return false }
        releasePin(reason: "Pinned display went away — following the current desktop")
        return true
    }

    // MARK: picker chrome

    private func installChrome() {
        let displayTap = UITapGestureRecognizer(target: self, action: #selector(openPicker))
        displayTap.numberOfTouchesRequired = 3
        displayTap.delegate = self
        addGestureRecognizer(displayTap)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self
        addGestureRecognizer(pinch)

        // Trackpad rotation, forwarded with pinch as one Wayland gesture. Harmless if
        // iPadOS never delivers indirect rotation: handleRotation just never fires.
        let rotation = UIRotationGestureRecognizer(target: self, action: #selector(handleRotation(_:)))
        rotation.delegate = self
        addGestureRecognizer(rotation)

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
        continuousScrollPan = wheelPan

        // A physical mouse wheel is discrete input. Keep it distinct from a
        // Magic Keyboard trackpad so Wayland clients receive the right source.
        let discreteWheelPan = UIPanGestureRecognizer(target: self, action: #selector(handleTwoFingerPan(_:)))
        discreteWheelPan.allowedScrollTypesMask = .discrete
        discreteWheelPan.allowedTouchTypes = []
        discreteWheelPan.maximumNumberOfTouches = 0
        discreteWheelPan.delegate = self
        addGestureRecognizer(discreteWheelPan)
        discreteScrollPan = discreteWheelPan

        let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerTap(_:)))
        twoFingerTap.numberOfTouchesRequired = 2
        twoFingerTap.delegate = self
        addGestureRecognizer(twoFingerTap)

        if #available(iOS 13.4, *) {
            let hover = UIHoverGestureRecognizer(target: self, action: #selector(handlePointerHover(_:)))
            hover.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
            hover.delegate = self
            addGestureRecognizer(hover)

            // Dress iPadOS's own pointer as the desktop's cursor while a mouse or
            // trackpad is connected. Pointer styles are an iPad behavior; where the
            // system draws no pointer this stays nil and updateCursorOverlay keeps
            // drawing ours.
            if UIDevice.current.userInterfaceIdiom == .pad {
                let pointer = UIPointerInteraction(delegate: self)
                addInteraction(pointer)
                systemPointerInteraction = pointer
            }
        }

        addInteraction(UIContextMenuInteraction(delegate: self))
    }

    private func installShellOverlay() {
        if shellOverlay != nil { return }
        let overlay = XiosShellOverlay()
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.openPanel = { [weak self] in self?.presentDisplayControl() }
        overlay.fitDisplay = { [weak self] in
            guard let self else { return }
            self.resetZoom()
            self.lastToolMessage = "Fit current display"
            self.refreshShellOverlay()
        }
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

    @objc private func openPicker() { presentDisplayControl() }

    private typealias LauncherState = (apps: [LauncherApp], error: String?)

    private func fetchLauncherApps(completion: @escaping (LauncherState) -> Void) {
        requestIOSCDLines("APPS_LIST\n", timeout: 5.0) { lines in
            guard let lines else {
                completion(([], "ioscd timed out"))
                return
            }
            completion(Self.launcherState(from: lines))
        }
    }

    private static func launcherState(from lines: [String]) -> LauncherState {
        var apps: [LauncherApp] = []
        for line in lines {
            if line.hasPrefix("ERR ") { return (apps, line) }
            if line.hasPrefix("APPS_END") { break }
            guard let app = LauncherApp.parseIOSCDLine(line) else { continue }
            apps.append(app)
        }
        apps.sort {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        return (apps, nil)
    }

    private func sendLauncherToggle(_ app: LauncherApp, enabled: Bool,
                                    completion: @escaping (Bool) -> Void) {
        let verb = enabled ? "APP_ENABLE" : "APP_DISABLE"
        requestIOSCDLines("\(verb)\t\(app.id)\n", timeout: 5.0) { [weak self] lines in
            guard let self else { return }
            guard let lines, let last = lines.last else {
                self.lastToolMessage = "Launcher update failed: ioscd timed out"
                completion(false)
                return
            }
            if last == "APPS_END\t0" {
                self.lastToolMessage = "\(enabled ? "Enabled" : "Disabled") \(app.name)"
                completion(true)
                return
            }
            self.lastToolMessage = "Launcher update failed: \(lines.first ?? last)"
            completion(false)
        }
    }

    private func sendLauncherSync(native: Bool, dryRun: Bool,
                                  completion: @escaping ([String]?) -> Void) {
        let mode = native ? "native" : "classic"
        let dry = dryRun ? "dry" : "apply"
        requestIOSCDLines("APPS_SYNC\t\(mode)\t\(dry)\n", timeout: 15.0) { [weak self] lines in
            guard let self else { return }
            guard let lines else {
                self.lastToolMessage = "Launcher sync failed: ioscd timed out"
                completion(nil)
                return
            }
            let ok = lines.last == "APPS_END\t0"
            self.lastToolMessage =
                "\(dryRun ? "Dry run" : "Synced") \(mode) launchers\(ok ? "" : " with errors")"
            completion(lines)
        }
    }

    private func runLauncherSync(native: Bool, dryRun: Bool, title: String,
                                 message: UILabel) {
        let originOverlay = pickerOverlay
        let mode = native ? "native" : "classic"
        lastToolMessage = "\(dryRun ? "Checking" : "Syncing") \(mode) launchers…"
        message.text = lastToolMessage
        sendLauncherSync(native: native, dryRun: dryRun) {
            [weak self, weak originOverlay, weak message] lines in
            guard let self, let originOverlay,
                  self.pickerOverlay === originOverlay else { return }
            guard let lines else {
                message?.text = self.lastToolMessage
                return
            }
            self.presentLauncherSyncReport(title: title, lines: lines)
        }
    }

    /// Parse the session launcher's status file (preset / state / human message). nil when the
    /// file is absent or unparseable. State walks stopping → starting → waiting →
    /// relaunching → up (or error / compositor-only).
    private func sessionStatus() -> SessionStatus? {
        SessionStatus.load(from: sessionStatusPath)
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
        sessionStatusLabel?.text = runningDesktopDetail()       // status card, if open
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

    /// Plain-English one-liner for the state names the session launcher writes.
    private func friendlyState(_ state: String) -> String {
        switch state {
        case "up":              return "Running"
        case "starting":        return "Starting…"
        case "stopping":        return "Stopping…"
        case "waiting":         return "Waiting for the desktop…"
        case "relaunching":     return "Reconnecting…"
        case "compositor-only": return "Running, reconnecting the display…"
        case "stopped":         return "Stopped"
        case "error":           return "Error"
        default:                return state
        }
    }

    /// What the status card calls the thing on screen right now.
    private func runningDesktopTitle() -> String {
        if let preset = activeDesktopPreset() { return desktopLabel(preset) }
        if let preset = sessionStatus()?.preset, !preset.isEmpty, preset != "stop" {
            return desktopLabel(preset)
        }
        return usingIOSurface ? "Desktop" : "No desktop running"
    }

    /// State, size and whether input is wired up — no backend jargon; the technical
    /// view of the same thing lives in Advanced and in the debug snapshot.
    private func runningDesktopDetail() -> String {
        var parts: [String] = []
        if let s = sessionStatus() {
            parts.append(friendlyState(s.state))
            if !s.message.isEmpty, s.state != "up" { parts.append(s.message) }
        } else if usingIOSurface {
            parts.append("Running")
        } else {
            parts.append("Nothing to show yet")
        }
        parts.append("\(fbWidth)×\(fbHeight)")
        parts.append(inputConnected ? "touch and keyboard ready" : "input offline")
        return parts.joined(separator: " · ")
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

    /// Title row + close button. Every sheet in the app opens with this.
    private func addPanelHeader(_ title: String, to stack: UIStackView) {
        let titleRow = UIStackView()
        titleRow.axis = .horizontal
        titleRow.alignment = .center
        titleRow.spacing = 10

        let label = panelLabel(title, size: 20, weight: .bold)
        label.numberOfLines = 1
        titleRow.addArrangedSubview(label)
        titleRow.addArrangedSubview(UIView())
        titleRow.addArrangedSubview(iconPanelButton("xmark", label: "Close") { [weak self] in
            self?.dismissPicker()
        })
        stack.addArrangedSubview(titleRow)
    }

    /// One status card — what's running, how big, is input alive — plus the line
    /// that echoes the last thing the user did. Returns that line so callers can
    /// update it in place instead of rebuilding the sheet.
    @discardableResult
    private func addStatusCard(to stack: UIStackView) -> UILabel {
        let healthy = usingIOSurface && inputConnected
        let card = infoPanel(title: runningDesktopTitle(),
                             detail: runningDesktopDetail(),
                             iconName: "display",
                             accent: healthy ? UIColor.systemGreen : UIColor.systemOrange)
        sessionStatusLabel = card.detailLabel
        stack.addArrangedSubview(card.view)
        startSessionIndicator()

        let message = panelLabel(lastToolMessage, size: 12,
                                 color: UIColor(white: 0.70, alpha: 1))
        toolMessageLabel = message
        stack.addArrangedSubview(message)
        return message
    }

    /// Size is one control with one meaning: pick a size and it takes effect. If a
    /// desktop is already up it resizes now; otherwise it's what the next one starts
    /// at. (The old panel had three separate places to set this.)
    private func addScreenSizeControls(to stack: UIStackView) {
        let apply: (DisplayProfile?) -> Void = { [weak self] profile in
            guard let self else { return }
            self.pendingSessionDisplay = profile
            if let profile, self.activeDesktopPreset() != nil {
                self.writeSessionRequest("resize", display: profile)
            } else {
                self.lastToolMessage = profile.map { "New desktops start at \($0.detail)" }
                    ?? "New desktops use their default size"
            }
            self.presentDisplayControl()
        }

        let names = ["Landscape", "Portrait", "Compact"]
        var chips = [sizeButton("Default", selected: pendingSessionDisplay == nil) { apply(nil) }]
        for (index, name) in names.enumerated() {
            let profile = sessionDisplayProfiles[index]
            chips.append(sizeButton(name, selected: pendingSessionDisplay?.name == name) {
                apply(profile)
            })
        }
        stack.addArrangedSubview(buttonRow(chips))
        stack.addArrangedSubview(panelButton("Custom Size") { [weak self] in
            self?.presentCustomSize()
        })
        stack.addArrangedSubview(panelLabel(sessionDisplaySummary(), size: 11,
                                            color: UIColor(white: 0.62, alpha: 1)))
    }

    /// Present-side MetalFX upscaling, as a user-visible control rather than only an
    /// env var. Unlike Screen Size this needs no session restart and no compositor
    /// involvement — it changes how the display app scales its own drawable, so the
    /// next frame already looks different.
    private func addRenderScaleControls(to stack: UIStackView) {
        let chips = XiosUpscaleMode.selectable.map { mode in
            sizeButton(mode.title, selected: upscaleMode == mode) { [weak self] in
                // Choosing Off explicitly still records a preference, so it pins the
                // app against a compositor that starts advertising a hint later.
                self?.setUpscalePreference(mode)
                self?.presentDisplayControl()
            }
        }
        stack.addArrangedSubview(buttonRow(chips))

        // Report what actually happened, not what was asked for. Auto declines when
        // the desktop is already at or above panel resolution, and a device whose GPU
        // has no MetalFX spatial scaler falls back to a direct present — both are
        // states the user would otherwise experience as "the setting does nothing".
        stack.addArrangedSubview(panelLabel(renderScaleSummary(), size: 11,
                                            color: UIColor(white: 0.62, alpha: 1)))
        if hasUpscalePreference {
            stack.addArrangedSubview(panelButton("Follow Session Setting") { [weak self] in
                self?.setUpscalePreference(nil)
                self?.presentDisplayControl()
            })
        }
    }

    /// One line describing the live upscale state and its trade-off.
    private func renderScaleSummary() -> String {
        if upscaleMode.isOff {
            return "Off renders the desktop at the panel's full resolution. "
                + "A lower scale draws fewer pixels and scales up on screen: "
                + "easier on the GPU, slightly softer."
        }
        // lastUpscaleStatus is the value published to `xios-status`, i.e. ground truth.
        switch lastUpscaleStatus {
        case let s where s.hasPrefix("off (") :
            return "Requested \(upscaleMode.title), but this GPU has no MetalFX spatial "
                + "scaler — presenting directly instead."
        case "off", "":
            return upscaleMode == .auto
                ? "Auto is on, but the desktop is already at or below the panel's "
                  + "resolution, so nothing is being upscaled."
                : "Requested \(upscaleMode.title); waiting for the next frame."
        default:
            return "Active: \(lastUpscaleStatus)"
        }
    }

    private func sizeButton(_ title: String, selected: Bool,
                            action: @escaping () -> Void) -> UIButton {
        let button = panelButton(title, action)
        stylePanelToggle(button, on: selected)
        return button
    }

    /// A desktop to run. The one that's already up is highlighted and says so;
    /// tapping it restarts it.
    private func desktopRow(_ preset: DesktopPreset, current: String?,
                            message: UILabel) -> UIButton {
        let active = preset.preset == current
        return detailPanelButton(
            title: active ? "\(preset.title) — running" : preset.title,
            detail: active ? "Tap to restart it" : preset.detail,
            iconName: preset.iconName,
            fill: active ? UIColor.systemBlue.withAlphaComponent(0.34)
                         : UIColor(white: 0.20, alpha: 0.84)
        ) { [weak self, weak message] in
            guard let self else { return }
            self.writeSessionRequest(preset.preset, display: self.pendingSessionDisplay)
            message?.text = self.lastToolMessage
        }
    }

    /// The screen the app opens to. Four questions, in the order they get asked:
    /// what's running, which desktop do I want, how big should it be, and open an
    /// app. Display slots, input plumbing and diagnostics live behind Advanced so
    /// they aren't in the way of the common path.
    private func presentDisplayControl() {
        let (_, _, _, stack) = presentScrollableModalCard(maxWidth: 620)
        addPanelHeader("Xios", to: stack)
        let message = addStatusCard(to: stack)

        let current = activeDesktopPreset()

        addSection("Desktop", to: stack)
        for preset in desktopPresets {
            stack.addArrangedSubview(desktopRow(preset, current: current, message: message))
        }

        addSection("Screen Size", to: stack)
        addScreenSizeControls(to: stack)

        addSection("Render Scale", to: stack)
        addRenderScaleControls(to: stack)

        addSection("Apps", to: stack)
        stack.addArrangedSubview(detailPanelButton(
            title: "Open an App",
            detail: "Everything installed on the desktop",
            iconName: "square.grid.2x2") { [weak self] in
                self?.presentAppLauncher()
            })

        var footer: [UIButton] = []
        if current != nil {
            let stop = panelButton("Stop Desktop") { [weak self, weak message] in
                self?.writeSessionRequest("stop")
                message?.text = self?.lastToolMessage
            }
            stop.backgroundColor = UIColor.systemRed.withAlphaComponent(0.44)
            footer.append(stop)
        }
        footer.append(panelButton("Advanced") { [weak self] in self?.presentAdvanced() })
        stack.addArrangedSubview(buttonRow(footer))
    }

    /// Everything the main panel deliberately doesn't show: which display we're
    /// rendering, extra display slots, home-screen launcher sync, the key/click pad,
    /// and the debug snapshot.
    private func presentAdvanced() {
        let (_, _, _, stack) = presentScrollableModalCard(maxWidth: 620)
        addPanelHeader("Advanced", to: stack)
        let message = addStatusCard(to: stack)

        addSection("Display", to: stack)
        stack.addArrangedSubview(infoPanel(title: currentDisplayTitle(),
                                           detail: currentDisplaySummary(),
                                           iconName: "rectangle.on.rectangle",
                                           accent: UIColor.systemTeal).view)
        let displays = discoverDisplays()
        if displays.isEmpty {
            stack.addArrangedSubview(emptyPanel("No displays or slots were found."))
        } else {
            stack.addArrangedSubview(panelLabel("Tap to switch. Touch and hold to stop one, or to clear out an entry nothing is serving.",
                                                size: 11, color: UIColor(white: 0.62, alpha: 1)))
            for d in displays {
                stack.addArrangedSubview(makeRow(d))
            }
        }
        stack.addArrangedSubview(buttonRow([
            panelButton("Rescan") { [weak self] in self?.presentAdvanced() },
            panelButton(userPinned ? "Follow Current" : "Following Current") { [weak self] in
                guard let self else { return }
                self.userPinned = false
                self.selectedConfigPath = nil
                self.reloadRuntimeConfig()
                self.lastToolMessage = "Following xios.json"
                self.presentAdvanced()
            },
        ]))
        stack.addArrangedSubview(buttonRow([
            panelButton("Fit") { [weak self, weak message] in
                self?.resetZoom()
                self?.lastToolMessage = "Fit current display"
                message?.text = self?.lastToolMessage
            },
            panelButton("Reload") { [weak self] in
                guard let self else { return }
                self.reloadRuntimeConfig()
                self.lastToolMessage = "Reloaded xios.json"
                self.presentAdvanced()
            },
            panelButton("Reconnect Input") { [weak self] in
                guard let self else { return }
                self.reconnectInput()
                self.lastToolMessage = "Reconnected \(self.inputBackendName())"
                self.presentAdvanced()
            },
        ]))

        addSection("Extra Display Slot", to: stack)
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

        addSection("Home Screen Apps", to: stack)
        stack.addArrangedSubview(detailPanelButton(
            title: "Manage Home Screen Apps",
            detail: "Choose which desktop apps get an iOS icon",
            iconName: "square.grid.3x3") { [weak self] in
                self?.presentHomeScreenApps()
            })

        addSection("Keyboard & Mouse", to: stack)
        stack.addArrangedSubview(detailPanelButton(
            title: "Key & Click Pad",
            detail: "Esc, Tab, arrows, clicks and scroll",
            iconName: "keyboard") { [weak self] in
                self?.presentInputPad()
            })

        addSection("Diagnostics", to: stack)
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
            panelButton("Save Debug File") { [weak self, weak debugView, weak message] in
                self?.writeDebugSnapshot()
                self?.lastToolMessage = "Wrote xios-debug.txt"
                debugView?.text = self?.debugSnapshot()
                message?.text = self?.lastToolMessage
            },
        ]))

        stack.addArrangedSubview(buttonRow([
            panelButton("Back") { [weak self] in self?.presentDisplayControl() },
            panelButton("Close") { [weak self] in self?.dismissPicker() },
        ]))
    }

    private func presentCustomSize() {
        let (overlay, card) = presentModalCard()

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        stack.addArrangedSubview(panelLabel("Custom Size", size: 18, weight: .bold))
        stack.addArrangedSubview(panelLabel("How big the desktop should be, in points. DPI is optional.",
                                            size: 12, color: UIColor(white: 0.72, alpha: 1)))

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
                let profile = DisplayProfile(name: "Custom", width: w, height: h, dpi: dpi,
                                             detail: "\(w)×\(h)")
                self.pendingSessionDisplay = profile
                if self.activeDesktopPreset() != nil {
                    self.writeSessionRequest("resize", display: profile)
                } else {
                    self.lastToolMessage = "New desktops start at \(profile.detail)"
                }
                self.presentDisplayControl()
            },
            panelButton("Clear") { [weak self] in
                self?.pendingSessionDisplay = nil
                self?.presentDisplayControl()
            },
            panelButton("Back") { [weak self] in self?.presentDisplayControl() },
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
    /// it rides all the existing ioscd-socket / status plumbing.
    private func presentAppLauncher() {
        let (_, _, _, stack) = presentScrollableModalCard()

        stack.addArrangedSubview(panelLabel("Launch App", size: 18, weight: .bold))
        let compositorPaths = [
            XiosRuntimePaths.tmp("wayland-0"),
            XiosRuntimePaths.tmp("xios-kde-runtime/kwin-ios-test"),
            XiosRuntimePaths.tmp("xios-kde-runtime/wayland-0"),
        ]
        let hasCompositor = compositorPaths.contains {
            FileManager.default.fileExists(atPath: $0)
        }
        let message = panelLabel(
            hasCompositor
                ? "Opens into the running desktop."
                : "No desktop is running — start iosc or GNOME first.",
            size: 12, color: UIColor(white: 0.72, alpha: 1))
        toolMessageLabel = message
        stack.addArrangedSubview(message)

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
            panelButton("Back") { [weak self] in self?.presentDisplayControl() },
        ]))
        stack.addArrangedSubview(panelButton("Close") { [weak self] in self?.dismissPicker() })
    }

    /// One left-aligned row: app name on top, the command it runs beneath. Keep
    /// the panel open on a rejected request so the daemon's error remains visible.
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
                self.writeSessionRequest("app", app: app.exec, display: nil) {
                    [weak self] accepted in
                    if accepted { self?.dismissPicker() }
                }
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
            self.writeSessionRequest("app", app: app.exec, display: nil) {
                [weak self] accepted in
                if accepted { self?.dismissPicker() }
            }
        }, for: .touchUpInside)
        return b
    }

    private func presentHomeScreenApps(query initialQuery: String = "",
                                       state: LauncherState? = nil) {
        let (overlay, _, _, stack) = presentScrollableModalCard(maxWidth: 720)

        stack.addArrangedSubview(panelLabel("Home Screen Apps", size: 18, weight: .bold))
        let message = panelLabel(lastToolMessage, size: 12, color: UIColor(white: 0.72, alpha: 1))
        stack.addArrangedSubview(message)

        guard let state else {
            message.text = "Loading launchers…"
            stack.addArrangedSubview(panelLabel(
                "Asking ioscd for the installed launcher set.",
                size: 13, color: UIColor(white: 0.72, alpha: 1)))
            stack.addArrangedSubview(buttonRow([
                panelButton("Back") { [weak self] in self?.presentAdvanced() },
                panelButton("Close") { [weak self] in self?.dismissPicker() },
            ]))
            fetchLauncherApps { [weak self, weak overlay] loaded in
                guard let self, let overlay, self.pickerOverlay === overlay else { return }
                self.presentHomeScreenApps(query: initialQuery, state: loaded)
            }
            return
        }

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
            panelButton("Dry Native") { [weak self, weak message] in
                guard let self, let message else { return }
                self.runLauncherSync(native: true, dryRun: true,
                                     title: "Native Dry Run", message: message)
            },
            panelButton("Dry Classic") { [weak self, weak message] in
                guard let self, let message else { return }
                self.runLauncherSync(native: false, dryRun: true,
                                     title: "Classic Dry Run", message: message)
            },
        ]))
        stack.addArrangedSubview(buttonRow([
            panelButton("Apply Native") { [weak self, weak message] in
                guard let self, let message else { return }
                self.runLauncherSync(native: true, dryRun: false,
                                     title: "Native Sync", message: message)
            },
            panelButton("Apply Classic") { [weak self, weak message] in
                guard let self, let message else { return }
                self.runLauncherSync(native: false, dryRun: false,
                                     title: "Classic Sync", message: message)
            },
        ]))

        stack.addArrangedSubview(buttonRow([
            panelButton("Refresh") { [weak self, weak search] in
                self?.presentHomeScreenApps(query: search?.text ?? "")
            },
            panelButton("Back") { [weak self] in self?.presentAdvanced() },
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
            let originOverlay = self.pickerOverlay
            let requestedState = toggle.isOn
            toggle.isEnabled = false
            message?.text = "\(requestedState ? "Enabling" : "Disabling") \(app.name)…"
            self.sendLauncherToggle(app, enabled: requestedState) {
                [weak self, weak toggle, weak message, weak originOverlay] succeeded in
                guard let self, let originOverlay,
                      self.pickerOverlay === originOverlay else { return }
                if succeeded {
                    self.presentHomeScreenApps(query: query)
                } else {
                    toggle?.isEnabled = true
                    toggle?.isOn = app.enabled
                    message?.text = self.lastToolMessage
                }
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
        b.menu = displayRowMenu(d, active: active)
        b.showsMenuAsPrimaryAction = false
        b.addAction(UIAction { [weak self] _ in
            self?.dismissPicker()
            self?.load(d)
        }, for: .touchUpInside)
        return b
    }

    /// Touch and hold a display row: switch to it, stop it, or — once nothing is
    /// serving it — drop its leftover entry from the list.
    private func displayRowMenu(_ d: XDisplayInfo, active: Bool) -> UIMenu {
        var actions: [UIMenuElement] = []
        if !active {
            actions.append(UIAction(title: "Switch to This Display",
                                    image: UIImage(systemName: "arrow.right.circle")) {
                [weak self] _ in
                self?.dismissPicker()
                self?.load(d)
            })
        }
        let live = displayIsLive(d)
        if live {
            let title = d.slot != nil ? "Stop This Display" : "Stop the Desktop"
            actions.append(UIAction(title: title, image: UIImage(systemName: "stop.circle"),
                                    attributes: [.destructive]) { [weak self] _ in
                self?.stopDisplay(d)
            })
        }
        if d.registryPath != nil, !live {
            actions.append(UIAction(title: "Remove from List",
                                    image: UIImage(systemName: "trash"),
                                    attributes: [.destructive]) { [weak self] _ in
                self?.removeDisplayFromList(d)
            })
        }
        return UIMenu(title: displayName(d, active: false), children: actions)
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

    /// Keys and clicks the touchscreen can't send: Esc/Tab/arrows, modifier
    /// combinations, raw keysyms, middle/right click and wheel.
    private func presentInputPad() {
        let (_, _, _, stack) = presentScrollableModalCard(maxWidth: 560)
        addPanelHeader("Key & Click Pad", to: stack)

        addSection("Send Text", to: stack)
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

        addSection("Keys", to: stack)
        stack.addArrangedSubview(panelLabel("Modifiers stay armed until you tap them again.",
                                            size: 11, color: UIColor(white: 0.62, alpha: 1)))
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

        addSection("Mouse", to: stack)
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

        addSection("Raw Keysym", to: stack)
        let keysymField = panelTextField("Hex, e.g. ff1b")
        stack.addArrangedSubview(keysymField)
        stack.addArrangedSubview(panelButton("Send Keysym") { [weak self, weak keysymField] in
            let raw = (keysymField?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let cleaned = raw.lowercased().hasPrefix("0x") ? String(raw.dropFirst(2)) : raw
            if let value = UInt(cleaned, radix: 16) {
                self?.sendKeysym(value, ctrl: customCtrl, alt: customAlt, shift: customShift)
            }
        })

        stack.addArrangedSubview(buttonRow([
            panelButton("Back") { [weak self] in self?.presentAdvanced() },
            panelButton("Close") { [weak self] in self?.dismissPicker() },
        ]))
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

    // MARK: keyboard (iOS keyboard -> compositor input)

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

// The screen view itself is the keyboard responder and forwards text/key events to
// the active compositor. Backspace stays live via hasText.
extension XScreenView: UIKeyInput {
    var hasText: Bool { true }

    func insertText(_ text: String) {
        guard inputConnected else { return }
        if hardwareKeyboard.isLikelyUIKitEcho() { return }
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
        if hardwareKeyboard.isLikelyUIKitEcho() { return }
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

extension XScreenView: UIPointerInteractionDelegate {
    /// The whole screen is one region: the desktop decides the cursor, not UIKit hit
    /// testing, so the style never varies by position.
    func pointerInteraction(_ interaction: UIPointerInteraction,
                            regionFor request: UIPointerRegionRequest,
                            defaultRegion: UIPointerRegion) -> UIPointerRegion? {
        defaultRegion
    }

    func pointerInteraction(_ interaction: UIPointerInteraction,
                            styleFor region: UIPointerRegion) -> UIPointerStyle? {
        systemPointerStyle()
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
        // Pinch and rotation must run together: one Wayland gesture carries both, so
        // letting either win exclusively would drop half of it.
        gestureRecognizer is UIPinchGestureRecognizer || otherGestureRecognizer is UIPinchGestureRecognizer
            || gestureRecognizer is UIRotationGestureRecognizer
            || otherGestureRecognizer is UIRotationGestureRecognizer
    }
}

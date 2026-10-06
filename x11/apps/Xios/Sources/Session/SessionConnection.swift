import UIKit
import Metal

/// One desktop the app knows about. It always carries the registry's view of the
/// session (`info`) and its thumbnail; it holds live links (surface, input,
/// clipboard, sysint) ONLY while it is the presented session. Detaching releases
/// every one of them (invariants 20-22, 42).
///
/// All state is main-thread. Blocking work (connect, fence import, input open)
/// runs on worker queues and returns through the generation tokens below, so a
/// stale result can never touch a newer connection.
final class SessionConnection {
    enum Phase: Equatable {
        /// Not presented: no links at all.
        case detached
        /// Presented, first connect in flight.
        case connecting
        /// Presented and showing frames.
        case live
        /// Presented; the stream dropped (rotation, compositor restart) and we are
        /// reconnecting right away rather than waiting for a poll.
        case reconnecting
        /// Presented but there is nothing to connect to yet or any more.
        case waiting
    }

    let slot: String
    private(set) var info: SessionInfo
    private(set) var phase = Phase.detached
    private(set) var waitingReason: String?
    var thumbnail: UIImage?

    private(set) var surface: SurfaceLink?
    private(set) var input: InputLink?
    private(set) var clipboard: ClipboardLink?
    private(set) var sysint: SysIntLink?
    /// When the stream was last lost (nil while live). The presenter shows the
    /// last frame for a short grace and black after it.
    private(set) var lostAt: Date?

    private unowned let manager: SessionManager

    /// Bumped on attach and detach: guards everything.
    private let attachGen = Epoch()
    /// Bumped to abandon an in-flight surface connect job.
    private let surfaceGen = Epoch()
    private let inputGen = Epoch()
    private let ddxPath = Locked<String?>(nil)
    private var connectInFlight = false
    private var inputInFlight = false
    private var retryAt: Date?
    /// The consumer-release event, cached across reconnects by token (invariant 11).
    private var releaseCache: (token: Data?, event: MTLSharedEvent?) = (nil, nil)

    private static let connectQueue = DispatchQueue(
        label: "com.max.xios.connect", qos: .userInitiated, attributes: .concurrent)
    /// Total time a connect job keeps trying before it reports "not responding".
    private static let connectBudget: TimeInterval = 60
    private static let retryAfterBudget: TimeInterval = 5

    init(info: SessionInfo, manager: SessionManager) {
        self.slot = info.slot
        self.info = info
        self.manager = manager
    }

    var isAttached: Bool { phase != .detached }
    var isLive: Bool { phase == .live }

    /// The input link, only while it is open. Releases and sends go through this
    /// so nothing is written to a connection that already dropped (invariant 42).
    var openInput: InputLink? {
        guard let input, input.isOpen else { return nil }
        return input
    }

    // MARK: attach / detach

    /// Make this the presented session: open every link.
    func attach() {
        guard phase == .detached else { return }
        attachGen.bump()
        surfaceGen.bump()
        inputGen.bump()
        lostAt = nil
        retryAt = nil
        phase = .connecting
        openClipboard()
        openSysInt()
        connectInputIfNeeded()
        startConnect()
        manager.connectionDidChange(self)
    }

    /// Release everything. `captureThumbnail` blits the last presented frame into
    /// a small texture first (encoded ahead of the release fence on the same queue).
    func detach(captureThumbnail: Bool) {
        guard phase != .detached else { return }
        // Let go of every key, button and touch while the input link is still
        // open, so the releases reach this compositor and not nowhere (invariant 42).
        manager.connectionWillRelease(self)
        attachGen.bump()
        surfaceGen.bump()
        inputGen.bump()
        connectInFlight = false
        inputInFlight = false
        retryAt = nil
        if let surface {
            if captureThumbnail {
                surface.captureThumbnail { [weak self] image in
                    guard let self, let image else { return }
                    self.thumbnail = image
                    self.manager.connectionDidChange(self)
                }
            }
            releaseCache = (surface.releaseFenceToken, surface.releaseFenceEvent)
            surface.close()
            self.surface = nil
        }
        input?.close(); input = nil
        clipboard?.close(); clipboard = nil
        closeSysInt()
        lostAt = nil
        waitingReason = nil
        phase = .detached
        manager.connectionDidChange(self)
    }

    /// Refresh the launcher thumbnail from the frame on glass (app resigning
    /// active). The link stays open.
    func refreshThumbnail() {
        surface?.captureThumbnail { [weak self] image in
            guard let self, let image else { return }
            self.thumbnail = image
            self.manager.connectionDidChange(self)
        }
    }

    // MARK: registry updates

    func update(_ new: SessionInfo) {
        let old = info
        info = new
        guard isAttached else { return }

        let oldEP = old.endpoints, newEP = new.endpoints
        if oldEP.ddx != newEP.ddx || oldEP.isIOSurface != newEP.isIOSurface {
            // The compositor restarted somewhere else (or a different one took
            // over): the old connection is of no further use.
            dropSurface()
            cancelConnect()
            startConnect()
        }
        if oldEP.input != newEP.input {
            inputGen.bump()
            inputInFlight = false
            if input != nil {
                manager.connectionWillRelease(self)
                input?.close(); input = nil
            }
            connectInputIfNeeded()
            // The aux link rides the same input socket.
            closeSysInt(); openSysInt()
        } else if oldEP.sysint != newEP.sysint {
            closeSysInt(); openSysInt()
        }
        if oldEP.clipboard != newEP.clipboard {
            clipboard?.close(); clipboard = nil
            openClipboard()
        }

        if new.state.isTerminal {
            if surface == nil {
                cancelConnect()
                setWaiting(new.message.isEmpty ? new.state.title : new.message)
            }
        } else if surface == nil, !connectInFlight, old.state != new.state || phase == .waiting {
            startConnect()
        }
        manager.connectionDidChange(self)
    }

    // MARK: surface connect

    private func cancelConnect() {
        surfaceGen.bump()
        connectInFlight = false
    }

    private func setWaiting(_ reason: String) {
        phase = .waiting
        waitingReason = reason
    }

    private func startConnect() {
        guard isAttached, !connectInFlight, !manager.isBackgrounded,
              let renderer = manager.renderer else { return }
        guard !info.state.isTerminal else {
            setWaiting(info.message.isEmpty ? info.state.title : info.message)
            return
        }
        guard info.endpoints.isIOSurface, let path = info.endpoints.ddx else {
            setWaiting(info.endpoints.configurationError ?? "waiting for the desktop")
            return
        }
        if phase == .waiting || phase == .detached { phase = .connecting }
        waitingReason = nil
        ddxPath.value = path
        connectInFlight = true
        retryAt = nil
        let attach = attachGen.value, gen = surfaceGen.value
        let attachEpoch = attachGen, surfaceEpoch = surfaceGen
        let box = ddxPath
        let device = renderer.device
        let cache = releaseCache
        Self.connectQueue.async { [weak self] in
            let deadline = Date().addingTimeInterval(Self.connectBudget)
            var attempt = 0
            // Retry until the compositor's socket is up (it may launch after us), at
            // 100 ms for the first couple of seconds so a rotation reconnects
            // without a visible gap, then every 500 ms. Bail the moment a newer
            // attach, detach or endpoint change superseded this job (invariant 24).
            while Date() < deadline {
                guard attachEpoch.value == attach, surfaceEpoch.value == gen else { return }
                if let path = box.value, let conn = xsurface_connect(path) {
                    // The release-fence import is a broker round trip (blocking
                    // XPC), so it happens here, before the hop, not on main.
                    let release = SurfaceLink.importReleaseFence(conn, device: device,
                                                                 cached: cache)
                    DispatchQueue.main.async {
                        guard let self, attachEpoch.value == attach, surfaceEpoch.value == gen,
                              !self.manager.isBackgrounded else {
                            xsurface_close(conn)   // user switched away mid-connect
                            return
                        }
                        self.connectInFlight = false
                        self.adopt(conn, release: release)
                    }
                    return
                }
                Thread.sleep(forTimeInterval: attempt < 20 ? 0.1 : 0.5)
                attempt += 1
            }
            DispatchQueue.main.async {
                guard let self, attachEpoch.value == attach, surfaceEpoch.value == gen else { return }
                self.connectInFlight = false
                self.setWaiting("The desktop is not responding")
                self.retryAt = Date().addingTimeInterval(Self.retryAfterBudget)
                self.manager.connectionDidChange(self)
            }
        }
    }

    private func adopt(_ conn: OpaquePointer, release: SurfaceLink.ReleaseFenceImport) {
        guard let renderer = manager.renderer, isAttached else { xsurface_close(conn); return }
        if let failure = release.failure { StatusWriter.shared.metal(failure) }
        guard let link = SurfaceLink.adopt(conn: conn, release: release, renderer: renderer) else {
            StatusWriter.shared.metal("iosurface-texture-fail")
            retryAt = Date().addingTimeInterval(0.5)   // the tick retries the connect
            return
        }
        if release.ok, release.token != nil { releaseCache = (release.token, release.event) }
        surface = link
        phase = .live
        lostAt = nil
        waitingReason = nil
        manager.connectionDidAdopt(self)
        connectInputIfNeeded()
        manager.connectionDidChange(self)
    }

    private func dropSurface() {
        guard let surface else { return }
        releaseCache = (surface.releaseFenceToken, surface.releaseFenceEvent)
        surface.close()
        self.surface = nil
    }

    /// The stream ended (EOF, protocol break, a frame with no fence). Release the
    /// IOSurface and textures NOW (that is what keeps a flavor switch out of jetsam,
    /// invariant 20) and reconnect immediately: iosc drops its app clients on every
    /// OUTPUT (rotation), so waiting for a poll showed up to 1.5 s of black
    /// (invariant 55).
    func surfaceLost() {
        guard surface != nil else { return }
        dropSurface()
        phase = .reconnecting
        lostAt = Date()
        manager.connectionLostSurface(self)
        startConnect()
        manager.connectionDidChange(self)
    }

    // MARK: input

    private func connectInputIfNeeded() {
        guard isAttached, input == nil, !inputInFlight,
              let path = info.endpoints.input else { return }
        inputInFlight = true
        let attach = attachGen.value, gen = inputGen.value
        let attachEpoch = attachGen, inputEpoch = inputGen
        // iosc_input_open blocks in connect(): off main, then adopt on main.
        Self.connectQueue.async { [weak self] in
            let link = InputLink.open(socket: path)
            DispatchQueue.main.async {
                guard let self, attachEpoch.value == attach, inputEpoch.value == gen else {
                    link?.close(); return
                }
                self.inputInFlight = false
                guard let link else { return }
                // A new connection starts with nothing held.
                self.manager.connectionWillRelease(self)
                self.input = link
                self.manager.connectionDidOpenInput(self)
                self.manager.connectionDidChange(self)
            }
        }
    }

    private func inputDropped() {
        // The link is already dead; this clears app-side latches only (a trackpad
        // button still physically held presses again on its next event).
        manager.connectionWillRelease(self)
        input?.close()
        input = nil
        // Redial now rather than on the 30-tick poll: iosc drops its clients on a
        // rotation and the keyboard and pointer should not wait half a second.
        connectInputIfNeeded()
        manager.connectionDidChange(self)
    }

    // MARK: clipboard + sysint

    private func openClipboard() {
        guard clipboard == nil, let path = info.endpoints.clipboard else { return }
        clipboard = ClipboardLink(socket: path)
    }

    private func openSysInt() {
        guard sysint == nil else { return }
        let link = SysIntLink(sysint: info.endpoints.sysint, iosc: info.endpoints.input) {
            [weak manager] event in manager?.handleSysIntEvent(event)
        }
        sysint = link
        manager.connectionDidOpenSysInt(self, link: link)
    }

    private func closeSysInt() {
        guard let link = sysint else { return }
        manager.connectionWillCloseSysInt(self, link: link)
        link.close()
        sysint = nil
    }

    // MARK: tick

    /// Per-display-tick service of everything that is not drawing: pacing, the
    /// clipboard, input health and TRAITS, and connect retries. Presented only.
    func tick(pacing link: CADisplayLink, range: CAFrameRateRange, tickCount: Int,
              onLinkInterval: (UInt32) -> Void) {
        guard isAttached else { return }
        // Pacing first, before anything else this tick (invariant 3).
        if let surface { sendPacing(surface, link: link, range: range, onLinkInterval) }
        clipboard?.service(tick: tickCount)
        serviceInput(tickCount)
        if surface == nil, !connectInFlight, let at = retryAt, Date() >= at {
            retryAt = nil
            startConnect()
        }
    }

    /// Hand the compositor this tick's deadline so its coalesced repaint can be
    /// vblank-paced instead of event-loop paced. Everything on the wire is a delta
    /// from now: `targetTimestamp` lives in CACurrentMediaTime()'s domain and the
    /// compositor works in CLOCK_MONOTONIC (invariant 2).
    private func sendPacing(_ surface: SurfaceLink, link: CADisplayLink, range: CAFrameRateRange,
                            _ onLinkInterval: (UInt32) -> Void) {
        var interval = link.targetTimestamp - link.timestamp
        if !(interval > 0) { interval = link.duration }
        guard interval > 0, interval < 1 else { return }   // no clock yet, or nonsense
        let untilUs = ((link.targetTimestamp - CACurrentMediaTime()) * 1_000_000).rounded()
        let intervalUs = UInt32((interval * 1_000_000).rounded())
        onLinkInterval(intervalUs)
        surface.sendPacing(
            untilDeadlineUs: Int32(clamping: Int(untilUs.isFinite ? untilUs : 0)),
            intervalUs: intervalUs,
            minMfps: Int32((range.minimum * 1000).rounded()),
            maxMfps: Int32((range.maximum * 1000).rounded()))
    }

    private func serviceInput(_ tickCount: Int) {
        guard let input else {
            manager.connectionTraits(self, hint: 0, purpose: 0, enabled: 0)
            if tickCount % 30 == 0 { connectInputIfNeeded() }
            return
        }
        guard input.isOpen else { inputDropped(); return }
        // poll_traits returns one record per call; drain them all so every
        // enable/disable transition reaches the responder policy.
        while true {
            switch input.pollTraits() {
            case .none:
                return
            case .closed:
                inputDropped(); return
            case let .record(hint, purpose, enabled):
                manager.connectionTraits(self, hint: hint, purpose: purpose, enabled: enabled)
            }
        }
    }
}

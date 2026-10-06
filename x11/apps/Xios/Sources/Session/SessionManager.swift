import UIKit

/// What the manager needs from whatever is putting the presented desktop on glass
/// (PresentView). Kept as a protocol so the session layer never imports UIKit views.
protocol SessionPresenter: AnyObject {
    /// A connection is about to lose (or replace) its input link: release every key,
    /// button and touch the app still thinks is held (invariant 42).
    func presenterWillRelease(_ connection: SessionConnection)
    /// A new presented connection took over: clean slate for zoom, cursor, clipboard.
    func presenterDidPresent(_ connection: SessionConnection)
    func presenterDidAdopt(_ connection: SessionConnection)
    func presenterLostSurface(_ connection: SessionConnection)
    func presenterInputOpened(_ connection: SessionConnection)
    func presenterTraits(hint: UInt32, purpose: UInt32, enabled: UInt32)
    func presenterRefresh()
}

/// Owns every SessionConnection and decides which one is on glass.
///
///  * Discovery comes from SessionRegistry (kqueue + slow poll, off main).
///  * Exactly one connection is presented; only it holds links. Switching is
///    detach old (thumbnail first), attach new, reset zoom, force OUTPUT, deferred
///    clipboard push.
///  * Desktop lifecycle (start, stop, resize, open app) goes through ioscd.
final class SessionManager {
    static let shared = SessionManager()

    let registry = SessionRegistry()
    private(set) var renderer: Renderer?
    private(set) var isBackgrounded = false
    weak var presenter: SessionPresenter?

    private var connections: [String: SessionConnection] = [:]
    private(set) var presented: SessionConnection?
    private var hasSnapshot = false

    /// The launcher listens: the set of sessions (or any card's content) changed.
    var onSessionsChanged: (() -> Void)?
    /// The presented session changed (nil = home).
    var onPresentedChanged: ((SessionConnection?) -> Void)?
    /// One-line feedback for the UI ("Starting KDE Plasma...", failures).
    var onMessage: ((String) -> Void)?

    private var requestInFlight = false
    private var pendingPresent: (slot: String, until: Date)?
    private var endedWork: DispatchWorkItem?
    private static let autoHomeDelay: TimeInterval = 3.0

    // MARK: lifecycle

    func start() {
        renderer = Renderer.make()
        registry.onChange = { [weak self] infos in self?.registryUpdated(infos) }
        registry.start()
    }

    var sessions: [SessionConnection] {
        connections.values.sorted {
            if $0.info.isLegacyMain != $1.info.isLegacyMain { return $0.info.isLegacyMain }
            return $0.slot.localizedStandardCompare($1.slot) == .orderedAscending
        }
    }

    func session(slot: String) -> SessionConnection? { connections[slot] }

    /// A desktop of this preset that is up or on its way (decision 1: one per preset).
    func liveSession(preset: String) -> SessionConnection? {
        sessions.first {
            $0.info.preset == preset && ($0.info.state == .running || $0.info.state == .starting)
        }
    }

    /// Whether the first registry scan has landed (the launcher shows "Looking for
    /// desktops..." until then rather than an empty-state flash).
    var didLoad: Bool { hasSnapshot }

    // MARK: registry

    private func registryUpdated(_ infos: [SessionInfo]) {
        hasSnapshot = true
        var seen = Set<String>()
        for info in infos {
            seen.insert(info.slot)
            if let existing = connections[info.slot] {
                existing.update(info)
            } else {
                connections[info.slot] = SessionConnection(info: info, manager: self)
            }
        }
        for (slot, connection) in connections where !seen.contains(slot) {
            if connection === presented {
                // The desktop vanished while we are looking at it: keep the object
                // (it owns the links) and let it report that it is gone.
                var gone = connection.info
                gone.state = .stopped
                if gone.message.isEmpty { gone.message = "The desktop was stopped." }
                connection.update(gone)
            } else {
                connections[slot] = nil
            }
        }
        if let pending = pendingPresent {
            if let target = connections[pending.slot], target.info.state != .stopped {
                pendingPresent = nil
                present(target)
            } else if Date() > pending.until {
                pendingPresent = nil
            }
        }
        reviewPresentedEnd()
        onSessionsChanged?()
    }

    /// A presented desktop that has ended goes back to the launcher, where its
    /// card says why and offers Restart. Debounced: a restart (resize) passes
    /// through a stopped state on its way back up.
    private func reviewPresentedEnd() {
        guard let presented, presented.info.state.isTerminal, !presented.isLive else {
            endedWork?.cancel(); endedWork = nil
            return
        }
        guard endedWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, let current = self.presented,
                  current.info.state.isTerminal, !current.isLive else { return }
            self.endedWork = nil
            self.goHome()
        }
        endedWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.autoHomeDelay, execute: work)
    }

    // MARK: presenting

    func present(slot: String) {
        guard let target = connections[slot] else { return }
        present(target)
    }

    func present(_ target: SessionConnection) {
        guard renderer != nil else {
            onMessage?("The GPU is not available yet. Try again in a moment.")
            return
        }
        guard presented !== target else { return }
        // Switching = detach old, attach new, reset zoom, force OUTPUT, deferred
        // clipboard push. Old goes first so its surface (up to ~70 MB) is released
        // before the new one's arrives.
        endedWork?.cancel(); endedWork = nil
        presented?.detach(captureThumbnail: true)
        presented = target
        presenter?.presenterDidPresent(target)
        if !isBackgrounded { target.attach() }
        onPresentedChanged?(target)
    }

    func goHome() {
        endedWork?.cancel(); endedWork = nil
        guard let old = presented else { return }
        old.detach(captureThumbnail: true)
        presented = nil
        onPresentedChanged?(nil)
        onSessionsChanged?()
    }

    // MARK: app lifecycle

    func appWillResignActive() {
        presented?.refreshThumbnail()
    }

    /// A backgrounded Xios keeps its UI and Metal pipeline but pins no compositor
    /// IOSurface and polls nothing: release input, surface, fences, textures and the
    /// upscaler, bump every generation (invariant 22).
    func appDidEnterBackground() {
        isBackgrounded = true
        registry.stop()
        presented?.detach(captureThumbnail: false)
        renderer?.releaseUpscalerResources()
    }

    func appDidBecomeActive() {
        let wasBackgrounded = isBackgrounded
        isBackgrounded = false
        if renderer == nil {
            // A background launch had no GPU (invariant 23): retry where it exists.
            renderer = Renderer.make()
            presenter?.presenterRefresh()
        }
        renderer?.syncUpscaler()      // rebuild the pass backgrounding released
        if wasBackgrounded || !hasSnapshot { registry.start() }
        if let presented, !presented.isAttached { presented.attach() }
    }

    // MARK: SessionConnection callbacks

    func connectionWillRelease(_ c: SessionConnection) {
        guard c === presented else { return }
        presenter?.presenterWillRelease(c)
    }

    func connectionDidAdopt(_ c: SessionConnection) {
        guard c === presented else { return }
        presenter?.presenterDidAdopt(c)
    }

    func connectionLostSurface(_ c: SessionConnection) {
        guard c === presented else { return }
        presenter?.presenterLostSurface(c)
    }

    func connectionDidOpenInput(_ c: SessionConnection) {
        guard c === presented else { return }
        presenter?.presenterInputOpened(c)
    }

    func connectionTraits(_ c: SessionConnection, hint: UInt32, purpose: UInt32, enabled: UInt32) {
        guard c === presented else { return }
        presenter?.presenterTraits(hint: hint, purpose: purpose, enabled: enabled)
    }

    func connectionDidOpenSysInt(_ c: SessionConnection, link: SysIntLink) {
        guard c === presented else { return }
        SystemIntegration.shared.attach(link: link)
    }

    func connectionWillCloseSysInt(_ c: SessionConnection, link: SysIntLink) {
        SystemIntegration.shared.detach(link: link)
    }

    func connectionDidChange(_ c: SessionConnection) {
        if c === presented { presenter?.presenterRefresh() }
        reviewPresentedEnd()
        onSessionsChanged?()
    }

    func handleSysIntEvent(_ event: SysIntLink.Event) {
        SystemIntegration.shared.handle(event)
    }

    // MARK: desktop lifecycle (ioscd)

    private func perform(_ description: String, preset: String, app: String? = nil,
                         display: DisplayProfile? = nil, slot: String?,
                         success: @escaping () -> Void = {}) {
        guard !requestInFlight else {
            onMessage?("A desktop request is already being sent.")
            return
        }
        requestInFlight = true
        onMessage?(description)
        IOSCDClient.shared.session(preset: preset, app: app, display: display, slot: slot) {
            [weak self] reply in
            guard let self else { return }
            self.requestInFlight = false
            switch reply {
            case .started:
                success()
            case .failed(let why):
                self.onMessage?("Request failed: \(why)")
            }
            self.registry.refreshNow()
        }
    }

    /// Start a new desktop in its own slot and present it as soon as it registers.
    func startDesktop(preset: String, display: DisplayProfile?) {
        // Reuse the slot of a dead desktop of this preset instead of leaving a
        // stale card beside the new one.
        let reusable = sessions.first {
            $0.info.preset == preset && !$0.info.isLegacyMain && $0.info.state.isTerminal
        }
        let slot = reusable?.slot ?? DesktopCatalog.newSlot(for: preset, taken: Set(connections.keys))
        perform("Starting \(DesktopCatalog.label(for: preset))...", preset: preset,
                display: display, slot: slot) { [weak self] in
            self?.pendingPresent = (slot, Date().addingTimeInterval(30))
        }
    }

    /// Restart a failed or killed desktop with the size it last had.
    func restart(_ c: SessionConnection) {
        let preset = c.info.preset.isEmpty ? "iosc" : c.info.preset
        perform("Restarting \(c.info.title)...", preset: preset,
                display: c.info.requestedProfile, slot: c.info.ioscdSlot) { [weak self] in
            if !c.info.isLegacyMain { self?.pendingPresent = (c.slot, Date().addingTimeInterval(30)) }
        }
    }

    /// Change a desktop's size: restart that slot's preset at the new size. (The
    /// `resize` verb restarts whatever owns the GLOBAL active marker, which is the
    /// wrong desktop for a slot.)
    func resize(_ c: SessionConnection, to display: DisplayProfile) {
        let preset = c.info.preset.isEmpty ? "iosc" : c.info.preset
        perform("Resizing \(c.info.title) to \(display.detail)...", preset: preset,
                display: display, slot: c.info.ioscdSlot)
    }

    /// Stop one desktop. A slot stops on its own; the legacy Main desktop has no
    /// slot, and an unqualified stop stops everything (invariant 58).
    func stop(_ c: SessionConnection) {
        perform("Stopping \(c.info.title)...", preset: "stop", slot: c.info.ioscdSlot) {
            [weak self] in
            if c === self?.presented { self?.goHome() }
        }
    }

    /// Open an ioscd launcher app in `c`. ioscd takes the slot field for `app`.
    func openApp(_ app: LauncherApp, in c: SessionConnection, completion: @escaping (Bool) -> Void) {
        guard IOSCDProtocol.isValidDesktopFileID(app.id) else {
            onMessage?("\(app.name) has no usable desktop-file id.")
            completion(false)
            return
        }
        guard !requestInFlight else {
            onMessage?("A desktop request is already being sent.")
            completion(false)
            return
        }
        requestInFlight = true
        onMessage?("Opening \(app.name)...")
        IOSCDClient.shared.session(preset: "app", app: app.id, slot: c.info.ioscdSlot) {
            [weak self] reply in
            self?.requestInFlight = false
            switch reply {
            case .started:
                self?.onMessage?("Launch requested: \(app.name)")
                completion(true)
            case .failed(let why):
                self?.onMessage?("Request failed: \(why)")
                completion(false)
            }
        }
    }

    func dismiss(_ c: SessionConnection) {
        registry.dismiss(slot: c.slot, stamp: c.info.stamp)
    }
}

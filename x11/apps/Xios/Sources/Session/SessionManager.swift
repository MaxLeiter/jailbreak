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
    /// The slots in the registry's latest snapshot. A presented desktop that left
    /// it is kept until we go home, then dropped.
    private var snapshotSlots = Set<String>()

    /// Which presets can start (see PresetAvailability). Unknown until the first
    /// answer, and unknown offers everything.
    private(set) var presetAvailability = PresetAvailability.unknown
    /// The New Desktop sheet listens: the installed-preset answer changed.
    var onPresetAvailabilityChanged: (() -> Void)?

    /// The launcher listens: the set of sessions (or any card's content) changed.
    var onSessionsChanged: (() -> Void)?
    /// The presented session changed (nil = home).
    var onPresentedChanged: ((SessionConnection?) -> Void)?
    /// One-line feedback for the UI ("Starting KDE Plasma...", failures).
    var onMessage: ((String) -> Void)?

    private var requestInFlight = false
    private var pendingPresent: (slot: String, until: Date)?
    /// Presets whose start request was accepted but whose registry entry has not
    /// shown up yet. Closes the window in which a second tap on the same preset
    /// would start a second desktop (decision 1: one per preset).
    private var startingPresets: [String: Date] = [:]
    private static let startingWindow: TimeInterval = 60
    private var endedWork: DispatchWorkItem?
    private static let autoHomeDelay: TimeInterval = 3.0

    // MARK: lifecycle

    func start() {
        writeLauncherStatus()
        renderer = Renderer.make()
        registry.onChange = { [weak self] infos in self?.registryUpdated(infos) }
        registry.onStartFailed = { [weak self] slot, preset, why in
            self?.startFailed(slot: slot, preset: preset, why)
        }
        registry.start()
        refreshPresetAvailability()
    }

    // MARK: installed presets

    /// Ask which presets are installed: ioscd's PRESETS first (it runs
    /// `xios-session presets`), else the same checks on the files directly, else
    /// unknown (offer everything; xios-session's preflight then refuses a missing
    /// flavor and its words are shown).
    func refreshPresetAvailability() {
        IOSCDClient.shared.presets { [weak self] fromIOSCD in
            if let fromIOSCD {
                self?.setPresetAvailability(PresetAvailability(installed: fromIOSCD, source: .ioscd))
                return
            }
            let jb = XiosRuntimePaths.jbroot
            DispatchQueue.global(qos: .userInitiated).async {
                let probed = PresetProbe.installed(jb: jb)
                DispatchQueue.main.async {
                    self?.setPresetAvailability(
                        probed.map { PresetAvailability(installed: $0, source: .files) } ?? .unknown)
                }
            }
        }
    }

    private func setPresetAvailability(_ value: PresetAvailability) {
        guard value != presetAvailability else { return }
        presetAvailability = value
        let list = value.installed.map { $0.sorted().joined(separator: " ") } ?? "(all offered)"
        StatusWriter.shared.write("xios-presets.txt", "source=\(value.source.rawValue) installed=\(list)\n")
        onPresetAvailabilityChanged?()
    }

    var sessions: [SessionConnection] {
        connections.values.sorted {
            if $0.info.isLegacyMain != $1.info.isLegacyMain { return $0.info.isLegacyMain }
            return $0.slot.localizedStandardCompare($1.slot) == .orderedAscending
        }
    }

    func session(slot: String) -> SessionConnection? { connections[slot] }

    /// A desktop of this preset that is up or on its way (decision 1: one per preset).
    /// A state we cannot read counts as live while the preset is still starting.
    func liveSession(preset: String) -> SessionConnection? {
        let starting = isStarting(preset: preset)
        return sessions.first {
            $0.info.preset == preset
                && ($0.info.state == .running || $0.info.state == .starting
                    || ($0.info.state == .unknown && starting))
        }
    }

    /// A start for `preset` was accepted and is still within its window.
    func isStarting(preset: String) -> Bool {
        guard let until = startingPresets[preset] else { return false }
        if Date() > until { startingPresets[preset] = nil; return false }
        return true
    }

    /// Whether the first registry scan has landed (the launcher shows "Looking for
    /// desktops..." until then rather than an empty-state flash).
    var didLoad: Bool { hasSnapshot }

    // MARK: registry

    private func registryUpdated(_ infos: [SessionInfo]) {
        hasSnapshot = true
        var seen = Set<String>()
        defer { snapshotSlots = seen }
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
            let target = connections[pending.slot]
            if Date() > pending.until {
                pendingPresent = nil
            } else if let target, target !== presented,
                      target.info.state == .starting || target.info.state == .running {
                pendingPresent = nil
                present(target)
            }
            // When the target is already presented the entry stays until it
            // expires: it is what keeps a restart or resize from sending us home.
        }
        // Once a preset is visibly coming up the registry entry carries the truth.
        for (preset, _) in startingPresets where connections.values.contains(where: {
            $0.info.preset == preset && ($0.info.state == .starting || $0.info.state == .running) }) {
            startingPresets[preset] = nil
        }
        reviewPresentedEnd()
        syncAppearanceTargets()
        writeLauncherStatus()
        onSessionsChanged?()
    }

    /// Dark mode is applied per session bus by that session's sysintd, so every
    /// running desktop's sysint socket gets the appearance, not just the presented one
    /// (decision 3). The presented desktop has its own full link already.
    private func syncAppearanceTargets() {
        guard !isBackgrounded else { SystemIntegration.shared.setAppearanceTargets([]); return }
        var paths = Set<String>()
        for c in connections.values where c !== presented && c.info.state == .running {
            if let path = c.info.endpoints.sysint { paths.insert(path) }
        }
        if let own = presented?.info.endpoints.sysint { paths.remove(own) }
        SystemIntegration.shared.setAppearanceTargets(paths)
    }

    /// While nothing is presented the app still says what it knows: xios-status.txt
    /// (so a stale "presented desktop" line never outlives the desktop) and the
    /// per-desktop summary. Presented desktops write xios-status.txt themselves.
    func writeLauncherStatus() {
        StatusWriter.shared.write("xios-app-sessions.txt", DebugReport.sessionsSummary(manager: self))
        guard presented == nil else { return }
        StatusWriter.shared.write("xios-status.txt",
            "home\npresented=(home)\n" + DebugReport.sessionsSummary(manager: self))
    }

    /// A presented desktop that has ended goes back to the launcher, where its
    /// card says why and offers Restart. Debounced: a restart (resize) passes
    /// through a stopped state on its way back up.
    private func reviewPresentedEnd() {
        // A restart or resize we asked for passes through a stopped state: stay put.
        if let pending = pendingPresent, pending.slot == presented?.slot, Date() < pending.until {
            endedWork?.cancel(); endedWork = nil
            return
        }
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
        syncAppearanceTargets()
        onPresentedChanged?(target)
    }

    func goHome() {
        endedWork?.cancel(); endedWork = nil
        guard let old = presented else { return }
        old.detach(captureThumbnail: true)
        presented = nil
        // A desktop that left the registry while on screen was kept only because it
        // was presented. The registry publishes on change, so nothing else would
        // ever remove its card.
        if !snapshotSlots.contains(old.slot), connections[old.slot] === old {
            connections[old.slot] = nil
        }
        onPresentedChanged?(nil)
        syncAppearanceTargets()
        writeLauncherStatus()
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
        SystemIntegration.shared.setAppearanceTargets([])
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
        // A flavor may have been installed or removed in Sileo meanwhile.
        if wasBackgrounded { refreshPresetAvailability() }
        if let presented, !presented.isAttached {
            // Black first: the layer still holds the last frame from before the
            // background, and the desktop may have changed since.
            presenter?.presenterDidPresent(presented)
            presented.attach()
        }
        syncAppearanceTargets()
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

    /// `watchPreset`: the desktop this request starts, restarts or resizes. ioscd
    /// answers SESSION_STARTED once it has forked xios-session, so a refusal from
    /// xios-session itself (its preflight's "GNOME is not installed: install
    /// xios-gnome", "slot already running", ...) lands only in the request's status
    /// file; the registry watches that file and `startFailed` shows the words.
    private func perform(_ description: String, preset: String, app: String? = nil,
                         display: DisplayProfile? = nil, slot: String?,
                         watchPreset: String? = nil,
                         success: @escaping () -> Void = {}) {
        guard !requestInFlight else {
            onMessage?("A desktop request is already being sent.")
            return
        }
        requestInFlight = true
        onMessage?(description)
        let sentAt = Date()
        IOSCDClient.shared.session(preset: preset, app: app, display: display, slot: slot) {
            [weak self] reply in
            guard let self else { return }
            self.requestInFlight = false
            switch reply {
            case .started:
                if let watchPreset {
                    // xios-session's status file for this request: the slot's own, or
                    // the global one for the legacy Main desktop.
                    let status = slot.map { XiosRuntimePaths.tmp("xios-session-\($0).json") }
                        ?? XiosRuntimePaths.firstExisting("xios-session-status.json")
                    self.registry.watchStart(slot: slot ?? SessionInfo.mainSlot, statusPath: status,
                                             preset: watchPreset, since: sentAt)
                }
                success()
            case .failed(let why):
                self.onMessage?("Request failed: \(why)")
            }
            self.registry.refreshNow()
        }
    }

    /// xios-session refused or failed a request ioscd had accepted. Its words go to
    /// the user unchanged, and nothing keeps waiting for that desktop: no present
    /// when it registers, no "already starting" for the next attempt.
    private func startFailed(slot: String, preset: String, _ why: String) {
        if pendingPresent?.slot == slot { pendingPresent = nil }
        startingPresets[preset] = nil
        onMessage?(why)
        onSessionsChanged?()
    }

    /// Start a new desktop in its own slot and present it as soon as it registers.
    func startDesktop(preset: String, display: DisplayProfile?) {
        // Reuse the slot of a dead desktop of this preset instead of leaving a
        // stale card beside the new one.
        let reusable = sessions.first {
            $0.info.preset == preset && !$0.info.isLegacyMain && $0.info.state.isTerminal
        }
        guard !isStarting(preset: preset) else {
            onMessage?("\(DesktopCatalog.label(for: preset)) is already starting.")
            return
        }
        let slot = reusable?.slot ?? DesktopCatalog.newSlot(for: preset, taken: Set(connections.keys))
        perform("Starting \(DesktopCatalog.label(for: preset))...", preset: preset,
                display: display, slot: slot, watchPreset: preset) { [weak self] in
            self?.pendingPresent = (slot, Date().addingTimeInterval(30))
            self?.startingPresets[preset] = Date().addingTimeInterval(Self.startingWindow)
        }
    }

    /// Restart a failed or killed desktop with the size it last had.
    func restart(_ c: SessionConnection) {
        // Never guess the preset: restarting the wrong flavor tears down a desktop.
        guard !c.info.preset.isEmpty else {
            onMessage?("\(c.info.title) has no recorded desktop type, so it cannot be restarted from here.")
            return
        }
        let preset = c.info.preset
        perform("Restarting \(c.info.title)...", preset: preset,
                display: c.info.requestedProfile, slot: c.info.ioscdSlot,
                watchPreset: preset) { [weak self] in
            self?.pendingPresent = (c.slot, Date().addingTimeInterval(30))
            self?.startingPresets[preset] = Date().addingTimeInterval(Self.startingWindow)
        }
    }

    /// Change a desktop's size: xios-session's `resize` restarts the desktop that
    /// owns the request's active marker at the new size. With a slot that is the
    /// slot's own marker (per-slot since M0), and it stops the slot first. Sending
    /// the preset itself is refused by xios-session for a running slot ("slot
    /// already running"), and that error then lands on the live desktop's card.
    func resize(_ c: SessionConnection, to display: DisplayProfile) {
        guard !c.info.preset.isEmpty else {
            onMessage?("\(c.info.title) has no recorded desktop type, so it cannot be resized from here.")
            return
        }
        let preset = c.info.preset
        perform("Resizing \(c.info.title) to \(display.detail)...", preset: "resize",
                display: display, slot: c.info.ioscdSlot, watchPreset: preset) { [weak self] in
            // The desktop passes through a stopped state on its way back: keep it
            // presented (and re-present it if the debounce still sent us home).
            self?.pendingPresent = (c.slot, Date().addingTimeInterval(45))
            self?.startingPresets[preset] = Date().addingTimeInterval(Self.startingWindow)
        }
    }

    /// Whether Restart / Change size can be offered for this desktop.
    func canRestart(_ c: SessionConnection) -> Bool { !c.info.preset.isEmpty }

    /// Stop one desktop. A slot stops on its own; the legacy Main desktop has no
    /// slot, and an unqualified stop means the non-slot session (M0: the Xios app
    /// and the shared services go with it only when no slot is alive).
    func stop(_ c: SessionConnection) {
        perform("Stopping \(c.info.title)...", preset: "stop", slot: c.info.ioscdSlot) {
            [weak self] in
            if c === self?.presented { self?.goHome() }
        }
    }

    /// Open an ioscd launcher app in `c`. ioscd takes the slot field for `app`.
    /// `completion` gets nil when ioscd accepted it, else the reason word for word,
    /// so a sheet over the desktop can show it (the toast sits underneath).
    func openApp(_ app: LauncherApp, in c: SessionConnection, completion: @escaping (String?) -> Void) {
        guard IOSCDProtocol.isValidDesktopFileID(app.id) else {
            let why = "\(app.name) has no usable desktop-file id."
            onMessage?(why)
            completion(why)
            return
        }
        guard !requestInFlight else {
            let why = "A desktop request is already being sent."
            onMessage?(why)
            completion(why)
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
                completion(nil)
            case .failed(let why):
                self?.onMessage?("Request failed: \(why)")
                completion("Request failed: \(why)")
            }
        }
    }

    func dismiss(_ c: SessionConnection) {
        registry.dismiss(slot: c.slot, stamp: c.info.stamp)
    }
}

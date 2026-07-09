import UIKit
import IOSurface

/// Process-wide coordinator for a single per-app host: owns the one
/// iosc-native.sock connection (this app_id), a background reader thread, and the
/// window <-> UIWindowScene registry. Marshals every compositor event to the main
/// actor and maps it onto scene lifecycle.
///
/// One host = one app_id = potentially several toplevels (e.g. a dialog), each in
/// its own UIWindowScene. The FIRST window reuses the launch scene; each extra
/// window requests another scene (UIApplicationSupportsMultipleScenes).
///
/// The iosc server half is implemented in native mode; this manager now drives
/// real iosc-native.sock events (x11/docs/native-ipados-protocol.md).
final class NativeManager: NSObject {
    static let shared = NativeManager()

    private var appID = ""
    private var exec = ""
    private var appName = "app"

    private var client: OpaquePointer?          // iosc_native_client*
    private var reader: Thread?
    private var running = false

    /// The activity key that carries a window id across scene activation.
    static let windowActivityType = "com.max.iosc.host.window"

    private struct PendingWindow {
        var surface: IOSurfaceRef
        var width: Int
        var height: Int
        var title: String
    }
    // WINDOW_NEW arrived, no scene bound yet (also: window whose scene the system
    // reclaimed, parked here until its session reconnects).
    private var pending: [UInt32: PendingWindow] = [:]
    // Bound windows. `bound` mirrors the live canvas state so an unbind can park
    // the window back in `pending` for rebinding.
    private var bound: [UInt32: PendingWindow] = [:]
    private var views: [UInt32: HostScreenView] = [:]
    private var scenes: [UInt32: UIWindowScene] = [:]
    // Scene session -> window id, this process run only. Scene DISCONNECT keeps the
    // entry (the session persists and can reconnect); WINDOW_GONE and session
    // DISCARD remove it. Being in-memory scopes it correctly: discards replayed at
    // the next launch can never close a new compositor run's window via a stale id.
    private var sessionWindows: [String: UInt32] = [:]
    // Connected scenes with no window yet (the launch scene, or a just-activated one
    // whose window id we haven't matched). Ordered oldest-first. A restored session
    // (relaunch after jetsam) remembers which window it wants: its WINDOW_NEW replay
    // usually arrives after the scene connects, so the id must survive the wait.
    private struct WaitingScene {
        let scene: UIWindowScene
        let wantedID: UInt32?
    }
    private var waitingScenes: [WaitingScene] = []

    // MARK: launch

    /// Read the bundle's launch target and kick everything off. Called once from the
    /// app delegate at didFinishLaunching.
    func startup() {
        let info = Bundle.main.infoDictionary ?? [:]
        appID   = (info["IOSCAppID"] as? String) ?? ""
        exec    = (info["IOSCExec"]  as? String) ?? ""
        appName = (info["IOSCName"]  as? String) ?? (info["CFBundleDisplayName"] as? String) ?? "app"

        // Ask ioscd to spawn the Linux client (root, outside our sandbox).
        DispatchQueue.global(qos: .userInitiated).async { [exec, appID] in
            _ = exec.withCString { e in appID.withCString { a in ioscd_send_launch(a, e) } }
        }
        startReader()
        // VoiceOver bridge (inert until xios-a11yd ships; gated on VoiceOver).
        HostA11yClient.shared.startup(appID: appID, exec: exec)
    }

    /// Connect (retrying) and pump events on a background thread.
    private func startReader() {
        guard reader == nil else { return }
        running = true
        let t = Thread { [weak self] in self?.readerLoop() }
        t.name = "iosc-native-reader"
        t.stackSize = 512 * 1024
        reader = t
        t.start()
    }

    private func sceneSizePx() -> (Int, Int, Int) {
        let scale = Int(UIScreen.main.scale)
        let b = UIScreen.main.bounds
        return (Int(b.width) * scale, Int(b.height) * scale, scale)
    }

    private func readerLoop() {
        // Connect, retrying while iosc comes up (it may launch after us via ioscd).
        // Bounded backoff: a leftover host whose compositor never comes back must
        // not poll at 2Hz forever (see the 2026-07-08 stale-wrapper incident —
        // leftover GNOME hosts hammering the desktop stack from the background).
        var retryDelay = 0.5
        while running && client == nil {
            let (w, h, scale) = sceneSizePx()
            client = appID.withCString { iosc_native_connect(nil, $0, Int32(w), Int32(h), Int32(scale)) }
            if client == nil {
                Thread.sleep(forTimeInterval: retryDelay)
                retryDelay = min(retryDelay * 2, 8.0)
            }
        }
        guard let c = client else { return }

        var ev = iosc_native_event()
        while running {
            let r = iosc_native_next(c, 250, &ev)
            if r < 0 { break }                 // disconnected
            if r == 0 { continue }             // timeout
            let e = ev                         // copy out for the main hop
            DispatchQueue.main.async { [weak self] in self?.handle(e) }
        }
        DispatchQueue.main.async { [weak self] in self?.handleDisconnect() }
    }

    // MARK: event handling (main actor)

    private func handle(_ e: iosc_native_event) {
        switch e.type {
        case IOSC_NEV_WINDOW_NEW:
            // The C client retained the surface (+1); consume that here.
            guard let surf = e.surface?.takeRetainedValue() else { break }
            let title = withUnsafeBytes(of: e.title) { raw -> String in
                String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
            }
            windowNew(e.window, surface: surf, w: Int(e.width), h: Int(e.height), title: title)
        case IOSC_NEV_WINDOW_GEOM:
            guard let surf = e.surface?.takeRetainedValue() else { break }
            updateState(e.window) {
                $0.surface = surf; $0.width = Int(e.width); $0.height = Int(e.height)
            }
            views[e.window]?.adoptCanvas(surf, width: Int(e.width), height: Int(e.height))
        case IOSC_NEV_DIRTY:
            views[e.window]?.markDirty()
        case IOSC_NEV_TITLE:
            let title = withUnsafeBytes(of: e.title) { raw -> String in
                String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
            }
            updateState(e.window) { $0.title = title }
            scenes[e.window]?.title = title
        case IOSC_NEV_WINDOW_GONE:
            windowGone(e.window)
        case IOSC_NEV_CURSOR:
            break   // per-scene UIPointerStyle: later (see protocol spec §CURSOR)
        default:
            break
        }
    }

    private func windowNew(_ id: UInt32, surface: IOSurfaceRef, w: Int, h: Int, title: String) {
        // Already bound (replayed WINDOW_NEW after a reconnect, or a restarted
        // compositor reusing the id): re-adopt the new canvas into the existing
        // scene instead of spawning a duplicate.
        if let view = views[id] {
            bound[id] = PendingWindow(surface: surface, width: w, height: h, title: title)
            view.adoptCanvas(surface, width: w, height: h)
            scenes[id]?.title = title.isEmpty ? appName : title
            return
        }
        pending[id] = PendingWindow(surface: surface, width: w, height: h, title: title)
        // A restored scene waiting for exactly this window wins; otherwise take the
        // oldest scene with no preference (the launch scene). Scenes wanting a
        // different id keep waiting for their own replay.
        if let idx = waitingScenes.firstIndex(where: { $0.wantedID == id })
                  ?? waitingScenes.firstIndex(where: { $0.wantedID == nil }) {
            let scene = waitingScenes.remove(at: idx).scene
            bind(scene: scene, to: id)
        } else {
            // Need another scene. Carry the window id on the activation activity so the
            // new scene binds to exactly this window in willConnectTo.
            let activity = NSUserActivity(activityType: Self.windowActivityType)
            activity.userInfo = ["window": NSNumber(value: id)]
            UIApplication.shared.requestSceneSessionActivation(
                nil, userActivity: activity, options: nil, errorHandler: nil)
        }
    }

    /// Mutate a live window's parked/bound state (exactly one map holds it).
    private func updateState(_ id: UInt32, _ mutate: (inout PendingWindow) -> Void) {
        if var st = bound[id] { mutate(&st); bound[id] = st }
        else if var st = pending[id] { mutate(&st); pending[id] = st }
    }

    private func windowGone(_ id: UInt32) {
        // Compositor-initiated close: drop the session mapping so the discard that
        // follows the scene destruction below doesn't echo a CLOSED back for a
        // window that is already gone (whose id iosc may later reuse).
        sessionWindows = sessionWindows.filter { $0.value != id }
        if let scene = scenes[id] {
            let opts = UIWindowSceneDestructionRequestOptions()
            opts.windowDismissalAnimation = .standard
            UIApplication.shared.requestSceneSessionDestruction(scene.session, options: opts, errorHandler: nil)
        }
        forgetWindow(id)
    }

    private func handleDisconnect() {
        // iosc went away. Leave scenes up (frozen last frame); reconnect so a
        // relaunched compositor re-delivers this app's windows. The reader
        // thread has already exited, so releasing the client (fd + mach
        // receive right + struct) here is safe.
        if let c = client { iosc_native_close(c) }
        client = nil
        reader = nil
        for v in views.values { v.markDirty() }
        startReader()
    }

    // MARK: scene binding

    private func bind(scene: UIWindowScene, to id: UInt32) {
        guard let p = pending[id] else { return }
        pending[id] = nil
        let view = HostScreenView(window_id: id, manager: self)
        let vc = HostSceneViewController()
        vc.view = view
        let win = UIWindow(windowScene: scene)
        win.rootViewController = vc
        win.makeKeyAndVisible()
        HostSystemAppearance.shared.update(from: scene.traitCollection)
        objc_setAssociatedObject(scene, &Self.windowKey, win, .OBJC_ASSOCIATION_RETAIN)
        view.start()
        view.adoptCanvas(p.surface, width: p.width, height: p.height)
        scene.title = p.title.isEmpty ? appName : p.title
        views[id] = view
        scenes[id] = scene
        bound[id] = p
        sessionWindows[scene.session.persistentIdentifier] = id
    }
    private static var windowKey = 0

    // MARK: called by the scene delegate

    /// A scene connected. If it carries a window id (extra window, or a restored
    /// session) and that window is pending, bind it; if the window isn't here yet,
    /// park the scene with its wanted id until the window arrives. An id-less scene
    /// is the launch scene: give it any waiting window, else park it.
    func sceneConnected(_ scene: UIWindowScene, windowID: UInt32?) {
        // A session reconnecting after the system reclaimed its scene knows its
        // window even without a restoration activity.
        let wanted = windowID ?? sessionWindows[scene.session.persistentIdentifier]
        if let id = wanted, pending[id] != nil {
            bind(scene: scene, to: id)
            return
        }
        if wanted == nil, let (id, _) = pending.first {   // window already waiting for a scene
            bind(scene: scene, to: id)
            return
        }
        waitingScenes.removeAll { $0.scene === scene }
        waitingScenes.append(WaitingScene(scene: scene, wantedID: wanted))
    }

    /// The window id bound to a scene. The scene delegate snapshots it as the
    /// session's stateRestorationActivity so a relaunched host rebinds restored
    /// scenes to their original windows.
    func windowID(for scene: UIWindowScene) -> UInt32? {
        windowID(boundTo: scene)
    }

    private func windowID(boundTo scene: UIWindowScene) -> UInt32? {
        scenes.first(where: { $0.value === scene })?.key
    }

    private func forgetWindow(_ id: UInt32) {
        pending[id] = nil
        bound[id] = nil
        views[id]?.teardown()
        views[id] = nil
        scenes[id] = nil
    }

    /// A scene disconnected: the user swiped it away OR the system reclaimed a
    /// background scene's resources (the session persists and can reconnect later).
    /// Either way only unbind, parking the window back in `pending` so a
    /// reconnecting scene rebinds to it. The user-close signal is session DISCARD
    /// (sessionsDiscarded), which is where the toplevel actually closes.
    func sceneDisconnected(_ scene: UIWindowScene) {
        waitingScenes.removeAll { $0.scene === scene }
        guard let id = windowID(boundTo: scene) else { return }
        views[id]?.teardown()
        views[id] = nil
        scenes[id] = nil
        if let st = bound.removeValue(forKey: id) { pending[id] = st }
    }

    /// The user removed scenes from the app switcher (didDiscardSceneSessions):
    /// the one signal that really means "close". Tell iosc to close the toplevels
    /// those sessions displayed (their scenes already disconnected above).
    func sessionsDiscarded(_ sessions: Set<UISceneSession>) {
        for session in sessions {
            guard let id = sessionWindows.removeValue(forKey: session.persistentIdentifier) else { continue }
            if let c = client { iosc_native_closed(c, id) }
            forgetWindow(id)
        }
    }

    func sceneBecameKey(_ scene: UIWindowScene) {
        guard let c = client, let id = windowID(boundTo: scene) else { return }
        iosc_native_activate(c, id, 1)
    }
    func sceneResignedKey(_ scene: UIWindowScene) {
        guard let c = client, let id = windowID(boundTo: scene) else { return }
        iosc_native_activate(c, id, 0)
    }

    /// A scene's backing view resized (Split View drag, rotation). Tell iosc to
    /// reflow the app to the new pixel size.
    func sceneResized(_ id: UInt32, w: Int, h: Int) {
        guard let c = client else { return }
        iosc_native_resize(c, id, Int32(w), Int32(h))
    }

    /// Bound views for the a11y client's window matching, creation order
    /// (iosc window ids are monotonic). See docs/native-ipados-a11y.md.
    func a11yCandidates() -> [(id: UInt32, view: HostScreenView, title: String)] {
        views.sorted { $0.key < $1.key }
             .map { (id: $0.key, view: $0.value, title: scenes[$0.key]?.title ?? "") }
    }
}

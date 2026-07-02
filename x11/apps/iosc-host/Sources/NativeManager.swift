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
/// NOTE: the iosc server half of this protocol is not built yet, so end to end this
/// stays a scaffold — but the connect/read/scene wiring is complete and drives off
/// real events the moment iosc lands native mode (x11/docs/native-ipados-protocol.md).
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
        let surface: IOSurfaceRef
        let width: Int
        let height: Int
        let title: String
    }
    // WINDOW_NEW arrived, no scene bound yet.
    private var pending: [UInt32: PendingWindow] = [:]
    // Bound windows.
    private var views: [UInt32: HostScreenView] = [:]
    private var scenes: [UInt32: UIWindowScene] = [:]
    // Connected scenes with no window yet (the launch scene, or a just-activated one
    // whose window id we haven't matched). Ordered oldest-first.
    private var waitingScenes: [UIWindowScene] = []

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
        HostA11yClient.shared.startup(appID: appID)
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
        while running && client == nil {
            let (w, h, scale) = sceneSizePx()
            client = appID.withCString { iosc_native_connect(nil, $0, Int32(w), Int32(h), Int32(scale)) }
            if client == nil { Thread.sleep(forTimeInterval: 0.5) }
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
            views[e.window]?.adoptCanvas(surf, width: Int(e.width), height: Int(e.height))
        case IOSC_NEV_DIRTY:
            views[e.window]?.markDirty()
        case IOSC_NEV_TITLE:
            let title = withUnsafeBytes(of: e.title) { raw -> String in
                String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
            }
            scenes[e.window]?.title = title
        case IOSC_NEV_WINDOW_GONE:
            windowGone(e.window)
        case IOSC_NEV_CURSOR:
            break   // per-scene UIPointerStyle: later (see protocol spec §CURSOR)
        case IOSC_NEV_DISCONNECT:
            handleDisconnect()
        default:
            break
        }
    }

    private func windowNew(_ id: UInt32, surface: IOSurfaceRef, w: Int, h: Int, title: String) {
        pending[id] = PendingWindow(surface: surface, width: w, height: h, title: title)
        if let scene = waitingScenes.first {
            waitingScenes.removeFirst()
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

    private func windowGone(_ id: UInt32) {
        pending[id] = nil
        views[id]?.teardown()
        views[id] = nil
        if let scene = scenes[id] {
            scenes[id] = nil
            let opts = UIWindowSceneDestructionRequestOptions()
            opts.windowDismissalAnimation = .standard
            UIApplication.shared.requestSceneSessionDestruction(scene.session, options: opts, errorHandler: nil)
        }
    }

    private func handleDisconnect() {
        // iosc went away. Leave scenes up (frozen last frame); reconnect so a
        // relaunched compositor re-delivers this app's windows.
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
    }
    private static var windowKey = 0

    // MARK: called by the scene delegate

    /// A scene connected. If it carries a window id (extra window) and that window is
    /// pending, bind it; otherwise it's the launch scene — park it until a window
    /// arrives (or bind immediately if one already did).
    func sceneConnected(_ scene: UIWindowScene, windowID: UInt32?) {
        if let id = windowID, pending[id] != nil {
            bind(scene: scene, to: id)
            return
        }
        if let (id, _) = pending.first {   // window already waiting for a scene
            bind(scene: scene, to: id)
            return
        }
        waitingScenes.append(scene)
    }

    /// A scene was disconnected by the system OR swiped away by the user. If a window
    /// is still bound to it, tell iosc to close that toplevel.
    func sceneDisconnected(_ scene: UIWindowScene) {
        waitingScenes.removeAll { $0 === scene }
        guard let (id, _) = scenes.first(where: { $0.value === scene }) else { return }
        if let c = client { iosc_native_closed(c, id) }
        views[id]?.teardown()
        views[id] = nil
        scenes[id] = nil
    }

    func sceneBecameKey(_ scene: UIWindowScene) {
        guard let c = client, let (id, _) = scenes.first(where: { $0.value === scene }) else { return }
        iosc_native_activate(c, id, 1)
    }
    func sceneResignedKey(_ scene: UIWindowScene) {
        guard let c = client, let (id, _) = scenes.first(where: { $0.value === scene }) else { return }
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

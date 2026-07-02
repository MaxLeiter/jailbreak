import UIKit

/// Per-app host: a scene-based UIKit app. Each Linux window presents in its own
/// UIWindowScene (Variant A). The app delegate starts the native manager (which
/// asks ioscd to spawn the Linux client and connects iosc-native.sock); the scene
/// delegate registers each scene with the manager, which binds it to a window.
@main
final class HostAppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        NativeManager.shared.startup()
        return true
    }

    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let cfg = UISceneConfiguration(name: "Default", sessionRole: connectingSceneSession.role)
        cfg.delegateClass = HostSceneDelegate.self
        return cfg
    }
}

final class HostSceneDelegate: UIResponder, UIWindowSceneDelegate {
    // NativeManager owns the UIWindow (it's created when a window's canvas arrives,
    // which is after willConnectTo). This property is unused but satisfies the
    // UIWindowSceneDelegate convention.
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let ws = scene as? UIWindowScene else { return }
        // A window id may ride in on the activation activity (extra windows) or a
        // restored session (relaunch). Absent => the launch scene (waits for the
        // first window).
        let id = windowID(from: connectionOptions.userActivities.first
                          ?? session.stateRestorationActivity)
        NativeManager.shared.sceneConnected(ws, windowID: id)
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        if let ws = scene as? UIWindowScene { NativeManager.shared.sceneDisconnected(ws) }
    }
    func sceneDidBecomeActive(_ scene: UIScene) {
        HostSystemAppearance.shared.update(from: scene)
        if let ws = scene as? UIWindowScene { NativeManager.shared.sceneBecameKey(ws) }
    }
    func sceneWillResignActive(_ scene: UIScene) {
        if let ws = scene as? UIWindowScene { NativeManager.shared.sceneResignedKey(ws) }
    }

    private func windowID(from activity: NSUserActivity?) -> UInt32? {
        guard let a = activity, a.activityType == NativeManager.windowActivityType,
              let n = a.userInfo?["window"] as? NSNumber else { return nil }
        return n.uint32Value
    }
}

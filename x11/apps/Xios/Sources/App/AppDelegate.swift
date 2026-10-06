import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    private var root: RootViewController?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Name this process in the shared status table before anything publishes.
        StatusWriter.shared.start()
        XiosCameraBroker.shared.startIfDiagnosticEnabled()
        SessionManager.shared.start()

        let w = UIWindow(frame: UIScreen.main.bounds)
        let controller = RootViewController()
        w.rootViewController = controller
        w.makeKeyAndVisible()
        window = w
        root = controller
        return true
    }

    func applicationWillResignActive(_ application: UIApplication) {
        SessionManager.shared.appWillResignActive()
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        root?.setBackgrounded(true)
        SessionManager.shared.appDidEnterBackground()
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        SessionManager.shared.appDidBecomeActive()
        root?.setBackgrounded(false)
    }
}

import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let w = UIWindow(frame: UIScreen.main.bounds)
        w.rootViewController = XServerViewController()
        w.makeKeyAndVisible()
        window = w

        // A cold launch from the share sheet's fallback route delivers the URL
        // here rather than through application(_:open:).
        if let url = launchOptions?[.url] as? URL {
            handleXiosURL(url)
        }
        return true
    }

    func application(_ app: UIApplication, open url: URL,
                     options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        handleXiosURL(url)
    }

    /// `xios://open?url=<percent-encoded>` — the share extension's fallback when
    /// its own sandbox won't let it reach ioscd. The app is the process ioscd
    /// already trusts, so the OPEN_URL call is made from here instead.
    @discardableResult
    private func handleXiosURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "xios" else { return false }
        guard url.host?.lowercased() == "open",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let target = components.queryItems?.first(where: { $0.name == "url" })?.value,
              !target.isEmpty
        else { return false }

        // Off the main thread: this is a blocking socket round-trip, and ioscd
        // brings the compositor up before it answers.
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try XiosControl.openURL(target)
            } catch {
                NSLog("xios: share handoff failed: \(error.localizedDescription)")
            }
        }
        return true
    }
}

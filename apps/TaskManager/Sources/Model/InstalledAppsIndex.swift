import Foundation

/// Identity for a process that belongs to an installed app.
struct AppIdentity: Hashable {
    let bundleID: String
    let displayName: String
}

/// Maps a running process's executable path to the installed app that owns it,
/// using `LSApplicationWorkspace` — the same private, runtime-resolved API
/// `apps/KioskMode` uses for its picker.
///
/// The index is built once (app catalogs rarely change during a session) and
/// matched cheaply per process by executable path. Rebuild via `refresh()`.
final class InstalledAppsIndex {
    /// Exact executable path -> identity (fast path).
    private var byExecutable: [String: AppIdentity] = [:]
    /// Bundle directory path -> identity, for prefix matching when a process's
    /// libproc path doesn't string-equal the catalog's executable URL.
    private var byBundleDir: [(prefix: String, identity: AppIdentity)] = []

    init() { refresh() }

    func refresh() {
        byExecutable.removeAll(keepingCapacity: true)
        byBundleDir.removeAll(keepingCapacity: true)

        // Private class, no link stub — resolve dynamically and message through
        // the interface declared in the bridging header.
        guard let wsClass = NSClassFromString("LSApplicationWorkspace") as? LSApplicationWorkspace.Type,
              let ws = wsClass.default() else { return }

        // allApplications() is imported as an IUO ([LSApplicationProxy]!) — nil
        // would crash a direct for-in, so coalesce.
        let all: [LSApplicationProxy] = ws.allApplications() ?? []
        for proxy in all {
            guard let bundle = proxy.applicationIdentifier, !bundle.isEmpty else { continue }
            let name = proxy.localizedName ?? bundle
            let identity = AppIdentity(bundleID: bundle, displayName: name)
            // The array can contain LSApplicationRecord as well as LSApplicationProxy;
            // not every element responds to the URL accessors, so probe first — an
            // unguarded call raises "unrecognized selector" and aborts the app.
            if let exec = url(proxy, "bundleExecutableURL")?.path {
                byExecutable[exec] = identity
            }
            if let dir = url(proxy, "bundleURL")?.path {
                byBundleDir.append((prefix: dir + "/", identity: identity))
            }
        }
    }

    private func url(_ object: NSObject, _ key: String) -> URL? {
        guard object.responds(to: NSSelectorFromString(key)) else { return nil }
        return object.value(forKey: key) as? URL
    }

    /// The app that owns `executablePath`, or nil for system/daemon processes.
    func identity(forExecutablePath path: String?) -> AppIdentity? {
        guard let path else { return nil }
        if let hit = byExecutable[path] { return hit }
        // A process path like /private/var/containers/Bundle/Application/…/Foo.app/Foo
        // may differ from the catalog's URL only by a /private prefix or symlink
        // resolution, so fall back to a bundle-directory prefix match.
        return byBundleDir.first { path.hasPrefix($0.prefix) }?.identity
    }
}

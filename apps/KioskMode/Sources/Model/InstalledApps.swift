import Foundation

/// One installed app the user can lock the device to.
struct InstalledApp: Identifiable, Hashable {
    let bundleID: String
    let name: String
    var id: String { bundleID }

    /// First letter, used for the monogram tile in the picker.
    var monogram: String { String(name.prefix(1)).uppercased() }
}

enum InstalledApps {
    /// Installed apps you could lock to, sorted by name. Includes both App Store
    /// ("User") apps and jailbreak/system ("System") apps — jailbreak apps in
    /// /var/jb/Applications register as System, so a User-only filter would hide
    /// exactly the apps a kiosk is likely to want (Filza, NewTerm, KitchenHub…).
    /// Nameless bundles (daemons, plugins) and KioskMode itself are excluded.
    static func userApps() -> [InstalledApp] {
        // LSApplicationWorkspace is a private class with no link stub in the SDK,
        // so resolve it at runtime and message it through the declared interface
        // (ObjC dispatch is dynamic — no link-time class symbol needed).
        guard let wsClass = NSClassFromString("LSApplicationWorkspace") as? LSApplicationWorkspace.Type,
              let ws = wsClass.default() else { return [] }
        let visibleTypes: Set<String> = ["User", "System"]
        let apps: [InstalledApp] = ws.allApplications().compactMap { proxy in
            guard let type = proxy.applicationType, visibleTypes.contains(type) else { return nil }
            guard let bundle = proxy.applicationIdentifier,
                  !bundle.isEmpty, bundle != "com.max.kioskmode" else { return nil }
            // A launchable app has a localized name; nameless entries are plugins
            // or daemons with no Home Screen presence.
            guard let name = proxy.localizedName, !name.isEmpty else { return nil }
            // Skip apps SpringBoard hides from the Home Screen — Field Test,
            // Diagnostics, print/URL-handler services, etc. carry the "hidden"
            // app tag, which is exactly the signal SpringBoard uses. (KVC so a
            // missing accessor can't crash us.)
            var tags: [String] = []
            if proxy.responds(to: NSSelectorFromString("appTags")),
               let t = proxy.value(forKey: "appTags") as? [String] {
                tags = t
            }
            if tags.contains(where: { $0.localizedCaseInsensitiveContains("hidden") }) { return nil }
            return InstalledApp(bundleID: bundle, name: name)
        }
        // De-dupe by bundle id (some appear under multiple placements).
        var seen = Set<String>()
        let unique = apps.filter { seen.insert($0.bundleID).inserted }
        return unique.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

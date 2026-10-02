import FileProvider
import Foundation

/// Registers the Xios shared folder as a Files.app location.
///
/// The domain has to be registered by the containing app, not the extension — the
/// extension only exists once the system decides to launch it, which it will not do
/// until a domain names it. Registration is idempotent and survives app restarts, so
/// this is a cheap no-op on every launch after the first.
enum XiosFileProviderDomain {
    /// Best-effort by design. A device where FileProvider refuses the domain must
    /// still get a working desktop, so every failure here is logged and swallowed
    /// rather than propagated into launch.
    static func registerIfPossible() {
        guard XiosSharedRoot.ensureRootExists() else {
            NSLog("[xios-fileprovider] shared root unavailable at \(XiosSharedRoot.rootPath); skipping domain registration")
            return
        }

        let domain = NSFileProviderDomain(
            identifier: XiosSharedRoot.domainIdentifier,
            displayName: XiosSharedRoot.domainDisplayName)

        NSFileProviderManager.add(domain) { error in
            if let error {
                // Expected failure modes on a fakesigned install are a rejected
                // extension identity or a FileProvider daemon that never saw the
                // .appex get registered. Both look like this, so the message is worth
                // keeping verbatim for the device smoke.
                NSLog("[xios-fileprovider] domain registration failed: \(error.localizedDescription)")
                return
            }
            NSLog("[xios-fileprovider] domain registered at \(XiosSharedRoot.rootPath)")
        }
    }

    /// Tell the system the desktop changed the folder behind its back.
    ///
    /// The extension keeps no change journal, so this is what turns a passive stale
    /// view into a fresh one. It is not required for correctness — navigating into
    /// the folder always re-reads the live filesystem — so failures are ignored.
    static func signalChange() {
        let domain = NSFileProviderDomain(
            identifier: XiosSharedRoot.domainIdentifier,
            displayName: XiosSharedRoot.domainDisplayName)
        NSFileProviderManager(for: domain)?.signalEnumerator(for: .rootContainer) { _ in }
    }
}

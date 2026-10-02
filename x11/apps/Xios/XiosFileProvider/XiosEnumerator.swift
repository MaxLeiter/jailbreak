import FileProvider
import Foundation

/// Lists one directory under the shared root.
///
/// Dotfiles are NOT hidden. This folder is shared with a Linux desktop where a
/// dotfile is ordinary content, and silently withholding files from a file manager
/// is a worse failure than showing a little clutter.
final class XiosEnumerator: NSObject, NSFileProviderEnumerator {
    private let containerRelativePath: String

    init(containerRelativePath: String) {
        self.containerRelativePath = containerRelativePath
        super.init()
    }

    func invalidate() {}

    func enumerateItems(
        for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage
    ) {
        let directory = XiosSharedRoot.absolutePath(forRelativePath: containerRelativePath)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
            observer.finishEnumeratingWithError(
                NSFileProviderError(.noSuchItem))
            return
        }

        // A name that fails to stat between the listing and here was deleted by the
        // desktop mid-enumeration. That is normal on a live filesystem, so it is
        // skipped rather than failing the whole enumeration.
        let items = names.sorted().compactMap { name -> NSFileProviderItem? in
            XiosItem(relativePath: XiosSharedRoot.join(containerRelativePath, name))
        }

        observer.didEnumerate(items)
        observer.finishEnumerating(upTo: nil)
    }

    func enumerateChanges(
        for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor
    ) {
        // v1 keeps no change journal, because the writers are Linux processes that know
        // nothing about FileProvider and there is no reliable way to journal what they
        // did after the fact. Declaring the anchor expired makes the system discard its
        // cached view and re-run enumerateItems against the live directory. That is not
        // incremental, but it cannot serve a stale answer — which is the failure that
        // would actually matter here.
        observer.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired))
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        // nil means "no valid anchor", which routes the system into the full
        // re-enumeration path above rather than trusting an anchor we cannot honor.
        completionHandler(nil)
    }
}

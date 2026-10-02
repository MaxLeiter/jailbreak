import FileProvider
import Foundation

/// Maps between the on-disk shared folder and FileProvider item identifiers.
///
/// Item identifiers are an item's path RELATIVE to the shared root. That keeps them
/// stable across reboots with no sidecar database, which matters because the extension
/// is launched on demand and torn down aggressively, so it has nowhere durable to keep
/// one. The tradeoff is that renaming an item changes its identity, so the system sees
/// a delete plus a create rather than a move. That is visible only as a lost "recently
/// moved" affordance, and it is the right trade against carrying a database that would
/// have to stay consistent with a filesystem four other processes also write to.
enum XiosSharedRoot {
    static let domainIdentifier = NSFileProviderDomainIdentifier("com.max.xios.shared")
    static let domainDisplayName = "Xios"

    /// Desktop GUI apps are launched by ioscd as `mobile`, with HOME resolved from
    /// getpwnam("mobile")->pw_dir and falling back to /var/mobile (see
    /// x11/apps/iosc-desktop/src/ioscd.c). So the shared folder lives inside that home
    /// and both sides reach it as the same uid, with no permission translation.
    ///
    /// It is deliberately a dedicated subdirectory rather than /var/mobile itself:
    /// handing the whole iOS user home to every app's document picker would put
    /// Library/, Media/, and Containers/ one careless swipe away from deletion.
    static let candidatePaths = [
        "/var/mobile/Xios",
        "/private/var/mobile/Xios",
    ]

    static var rootPath: String {
        let fm = FileManager.default
        for candidate in candidatePaths where fm.fileExists(atPath: candidate) {
            return candidate
        }
        return candidatePaths[0]
    }

    /// Reject anything that could climb out of the shared root. Identifiers arrive
    /// from the system, but they round-trip through other processes' filenames, so
    /// this is validated rather than trusted.
    static func isSafeRelativePath(_ relative: String) -> Bool {
        if relative.isEmpty || relative.hasPrefix("/") { return false }
        for component in relative.split(separator: "/") {
            if component == ".." || component == "." { return false }
        }
        return true
    }

    /// Returns "" for the root container, a validated relative path otherwise, or
    /// nil if the identifier is not one we can safely resolve.
    static func relativePath(for identifier: NSFileProviderItemIdentifier) -> String? {
        if identifier == .rootContainer { return "" }
        let raw = identifier.rawValue
        return isSafeRelativePath(raw) ? raw : nil
    }

    static func absolutePath(forRelativePath relative: String) -> String {
        relative.isEmpty ? rootPath : rootPath + "/" + relative
    }

    static func absolutePath(for identifier: NSFileProviderItemIdentifier) -> String? {
        guard let relative = relativePath(for: identifier) else { return nil }
        return absolutePath(forRelativePath: relative)
    }

    static func identifier(forRelativePath relative: String) -> NSFileProviderItemIdentifier {
        relative.isEmpty ? .rootContainer : NSFileProviderItemIdentifier(relative)
    }

    static func parentIdentifier(ofRelativePath relative: String) -> NSFileProviderItemIdentifier {
        guard let slash = relative.lastIndex(of: "/") else { return .rootContainer }
        return NSFileProviderItemIdentifier(String(relative[relative.startIndex..<slash]))
    }

    static func join(_ relative: String, _ name: String) -> String {
        relative.isEmpty ? name : relative + "/" + name
    }

    /// Create the shared root if it is absent. Called from the app before registering
    /// the domain; the extension never creates it, so a missing root surfaces as an
    /// empty folder rather than the extension silently inventing one somewhere the
    /// desktop side is not looking.
    @discardableResult
    static func ensureRootExists() -> Bool {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: rootPath, isDirectory: &isDirectory) {
            return isDirectory.boolValue
        }
        do {
            try fm.createDirectory(atPath: rootPath, withIntermediateDirectories: true)
            return true
        } catch {
            return false
        }
    }
}

import FileProvider
import Foundation
import UniformTypeIdentifiers

/// One NSFileProviderItem built by stat'ing a real path under the shared root.
///
/// Nothing is cached. Every item is read from disk at the moment it is asked for,
/// because the authoritative writer is the Linux desktop, not this extension — a
/// cache here would only ever be a way to serve stale answers.
final class XiosItem: NSObject, NSFileProviderItem {
    let itemIdentifier: NSFileProviderItemIdentifier
    let parentItemIdentifier: NSFileProviderItemIdentifier
    let filename: String
    let contentType: UTType
    let documentSize: NSNumber?
    let creationDate: Date?
    let contentModificationDate: Date?
    let itemVersion: NSFileProviderItemVersion
    let capabilities: NSFileProviderItemCapabilities

    init?(relativePath relative: String) {
        let path = XiosSharedRoot.absolutePath(forRelativePath: relative)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
            return nil
        }

        let isDirectory = (attributes[.type] as? FileAttributeType) == .typeDirectory
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let modified = attributes[.modificationDate] as? Date
        let isRoot = relative.isEmpty

        itemIdentifier = XiosSharedRoot.identifier(forRelativePath: relative)
        parentItemIdentifier = isRoot
            ? .rootContainer
            : XiosSharedRoot.parentIdentifier(ofRelativePath: relative)
        filename = isRoot
            ? XiosSharedRoot.domainDisplayName
            : String(relative[(relative.lastIndex(of: "/").map { relative.index(after: $0) } ?? relative.startIndex)...])

        if isDirectory {
            contentType = .folder
            documentSize = nil
        } else {
            let ext = (relative as NSString).pathExtension
            contentType = (ext.isEmpty ? nil : UTType(filenameExtension: ext)) ?? .data
            documentSize = NSNumber(value: size)
        }

        creationDate = attributes[.creationDate] as? Date
        contentModificationDate = modified

        // Version identity is mtime + size. It is what the system diffs to decide an
        // item changed, so it must move whenever the bytes move. Sub-second mtime is
        // preserved here precisely because desktop apps rewrite files fast enough for
        // whole-second granularity to miss edits.
        let stamp = "\(modified?.timeIntervalSince1970 ?? 0)-\(size)"
        let version = Data(stamp.utf8)
        itemVersion = NSFileProviderItemVersion(
            contentVersion: version, metadataVersion: version)

        if isDirectory {
            var caps: NSFileProviderItemCapabilities = [
                .allowsContentEnumerating, .allowsReading, .allowsAddingSubItems,
            ]
            // The root is the domain itself: renaming or deleting it from Files.app
            // would mean deleting the shared folder out from under the desktop.
            if !isRoot {
                caps.formUnion([.allowsDeleting, .allowsRenaming, .allowsReparenting])
            }
            capabilities = caps
        } else {
            capabilities = [
                .allowsReading, .allowsWriting, .allowsDeleting,
                .allowsRenaming, .allowsReparenting,
            ]
        }

        super.init()
    }
}

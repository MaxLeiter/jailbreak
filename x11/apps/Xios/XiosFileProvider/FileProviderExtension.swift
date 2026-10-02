import FileProvider
import Foundation
import UniformTypeIdentifiers

/// Exposes the Xios shared folder as a location in the iPad Files app.
///
/// This is a thin view over a real POSIX directory, not a syncing service. Every
/// call reads or writes the live filesystem, because the authoritative writers are
/// desktop apps running as `mobile` under iosc — the same uid this extension runs
/// as, which is what lets the two sides share a directory with no bridging daemon.
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
    required init(domain: NSFileProviderDomain) {
        super.init()
    }

    func invalidate() {}

    // MARK: - Reading

    func item(
        for identifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        defer { progress.completedUnitCount = 1 }

        guard let relative = XiosSharedRoot.relativePath(for: identifier),
            let item = XiosItem(relativePath: relative)
        else {
            completionHandler(nil, NSFileProviderError(.noSuchItem))
            return progress
        }
        completionHandler(item, nil)
        return progress
    }

    func fetchContents(
        for itemIdentifier: NSFileProviderItemIdentifier,
        version requestedVersion: NSFileProviderItemVersion?,
        request: NSFileProviderRequest,
        completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        defer { progress.completedUnitCount = 1 }

        guard let relative = XiosSharedRoot.relativePath(for: itemIdentifier),
            !relative.isEmpty,
            let item = XiosItem(relativePath: relative)
        else {
            completionHandler(nil, nil, NSFileProviderError(.noSuchItem))
            return progress
        }

        // The system takes ownership of the URL handed back here and will move or
        // delete it, so it gets a private copy. Handing over the live path would let
        // the system relocate a file out of the desktop's filesystem.
        let source = XiosSharedRoot.absolutePath(forRelativePath: relative)
        let staged = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.copyItem(atPath: source, toPath: staged.path)
        } catch {
            completionHandler(nil, nil, error)
            return progress
        }

        completionHandler(staged, item, nil)
        return progress
    }

    func enumerator(
        for containerItemIdentifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest
    ) throws -> NSFileProviderEnumerator {
        guard let relative = XiosSharedRoot.relativePath(for: containerItemIdentifier) else {
            throw NSFileProviderError(.noSuchItem)
        }
        return XiosEnumerator(containerRelativePath: relative)
    }

    // MARK: - Writing

    func createItem(
        basedOn itemTemplate: NSFileProviderItem,
        fields: NSFileProviderItemFields,
        contents url: URL?,
        options: NSFileProviderCreateItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (
            NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?
        ) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        defer { progress.completedUnitCount = 1 }

        guard let parent = XiosSharedRoot.relativePath(for: itemTemplate.parentItemIdentifier)
        else {
            completionHandler(nil, [], false, NSFileProviderError(.noSuchItem))
            return progress
        }

        let name = itemTemplate.filename
        guard !name.isEmpty, !name.contains("/") else {
            completionHandler(nil, [], false, NSFileProviderError(.noSuchItem))
            return progress
        }

        let relative = XiosSharedRoot.join(parent, name)
        let destination = XiosSharedRoot.absolutePath(forRelativePath: relative)
        let isDirectory = itemTemplate.contentType == .folder

        do {
            if isDirectory {
                try FileManager.default.createDirectory(
                    atPath: destination, withIntermediateDirectories: false)
            } else if let source = url {
                // Replace rather than fail: the system reissues a create when it
                // retries an interrupted upload, and a leftover partial file must not
                // wedge that retry forever.
                if FileManager.default.fileExists(atPath: destination) {
                    try FileManager.default.removeItem(atPath: destination)
                }
                try FileManager.default.copyItem(at: source, to: URL(fileURLWithPath: destination))
            } else {
                FileManager.default.createFile(atPath: destination, contents: nil)
            }
        } catch {
            completionHandler(nil, [], false, error)
            return progress
        }

        guard let created = XiosItem(relativePath: relative) else {
            completionHandler(nil, [], false, NSFileProviderError(.noSuchItem))
            return progress
        }
        completionHandler(created, [], false, nil)
        return progress
    }

    func modifyItem(
        _ item: NSFileProviderItem,
        baseVersion version: NSFileProviderItemVersion,
        changedFields: NSFileProviderItemFields,
        contents newContents: URL?,
        options: NSFileProviderModifyItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (
            NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?
        ) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        defer { progress.completedUnitCount = 1 }

        guard var relative = XiosSharedRoot.relativePath(for: item.itemIdentifier),
            !relative.isEmpty
        else {
            completionHandler(nil, [], false, NSFileProviderError(.noSuchItem))
            return progress
        }

        // A rename and a reparent are the same syscall here, so they are resolved into
        // one destination and applied once — doing them as two moves would briefly put
        // the file somewhere neither side expects.
        if changedFields.contains(.filename) || changedFields.contains(.parentItemIdentifier) {
            let parentIdentifier =
                changedFields.contains(.parentItemIdentifier)
                ? item.parentItemIdentifier
                : XiosSharedRoot.parentIdentifier(ofRelativePath: relative)

            guard let parent = XiosSharedRoot.relativePath(for: parentIdentifier) else {
                completionHandler(nil, [], false, NSFileProviderError(.noSuchItem))
                return progress
            }

            let name = changedFields.contains(.filename) ? item.filename : lastComponent(relative)
            guard !name.isEmpty, !name.contains("/") else {
                completionHandler(nil, [], false, NSFileProviderError(.noSuchItem))
                return progress
            }

            let target = XiosSharedRoot.join(parent, name)
            if target != relative {
                do {
                    try FileManager.default.moveItem(
                        atPath: XiosSharedRoot.absolutePath(forRelativePath: relative),
                        toPath: XiosSharedRoot.absolutePath(forRelativePath: target))
                } catch {
                    completionHandler(nil, [], false, error)
                    return progress
                }
                relative = target
            }
        }

        if changedFields.contains(.contents), let source = newContents {
            let destination = XiosSharedRoot.absolutePath(forRelativePath: relative)
            do {
                if FileManager.default.fileExists(atPath: destination) {
                    try FileManager.default.removeItem(atPath: destination)
                }
                try FileManager.default.copyItem(at: source, to: URL(fileURLWithPath: destination))
            } catch {
                completionHandler(nil, [], false, error)
                return progress
            }
        }

        guard let updated = XiosItem(relativePath: relative) else {
            completionHandler(nil, [], false, NSFileProviderError(.noSuchItem))
            return progress
        }
        completionHandler(updated, [], false, nil)
        return progress
    }

    func deleteItem(
        identifier: NSFileProviderItemIdentifier,
        baseVersion version: NSFileProviderItemVersion,
        options: NSFileProviderDeleteItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        defer { progress.completedUnitCount = 1 }

        // An empty relative path is the root container. Deleting it would remove the
        // shared folder the desktop is writing into, so it is refused outright rather
        // than relying on the capability flags alone.
        guard let relative = XiosSharedRoot.relativePath(for: identifier), !relative.isEmpty
        else {
            completionHandler(NSFileProviderError(.noSuchItem))
            return progress
        }

        do {
            try FileManager.default.removeItem(
                atPath: XiosSharedRoot.absolutePath(forRelativePath: relative))
        } catch {
            completionHandler(error)
            return progress
        }
        completionHandler(nil)
        return progress
    }

    // MARK: - Helpers

    private func lastComponent(_ relative: String) -> String {
        guard let slash = relative.lastIndex(of: "/") else { return relative }
        return String(relative[relative.index(after: slash)...])
    }
}

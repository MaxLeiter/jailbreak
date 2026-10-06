import Darwin
import Foundation

/// A kqueue vnode watch on one path. The file or directory is opened with
/// O_EVTONLY (no read access, never blocks an unmount). `isDead` flips when the
/// inode is deleted or renamed over, which is what an atomic replace does: the
/// owner re-opens the new inode on its next scan.
final class FileWatcher {
    let path: String
    private(set) var isDead = false
    private var source: DispatchSourceFileSystemObject?

    init?(path: String, queue: DispatchQueue, onEvent: @escaping () -> Void) {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        self.path = path
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .attrib, .delete, .rename, .link],
            queue: queue)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let data = src.data
            if data.contains(.delete) || data.contains(.rename) { self.isDead = true }
            onEvent()
        }
        src.setCancelHandler { close(fd) }
        source = src
        src.resume()
    }

    func cancel() {
        source?.cancel()
        source = nil
    }

    deinit { cancel() }
}

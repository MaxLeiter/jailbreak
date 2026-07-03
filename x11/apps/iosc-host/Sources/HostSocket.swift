import Darwin

/// Connects a SOCK_STREAM AF_UNIX socket to `path`. Returns the fd, or -1 on
/// any failure (including a path too long for sun_path). SO_NOSIGPIPE is set
/// so a dead peer surfaces as EPIPE from write(2) instead of killing the
/// process — same convention as the C connectors (NativeClient.c, IoscInput.c).
func connectUnixSocket(_ path: String) -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return -1 }

    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on,
               socklen_t(MemoryLayout.size(ofValue: on)))

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    // sockaddr_un() zero-fills sun_path, so keeping count < capacity
    // guarantees NUL termination.
    let ok: Bool = withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        let bytes = Array(path.utf8)
        guard bytes.count < raw.count else { return false }
        raw.copyBytes(from: bytes)
        return true
    }
    guard ok else { close(fd); return -1 }

    let rc = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard rc == 0 else { close(fd); return -1 }
    return fd
}

func writeAll(_ fd: Int32, bytes: UnsafeRawBufferPointer) -> Bool {
    var offset = 0
    while offset < bytes.count {
        let wrote = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset),
                                 bytes.count - offset)
        if wrote > 0 {
            offset += wrote
        } else if wrote < 0 && errno == EINTR {
            continue
        } else {
            return false
        }
    }
    return true
}

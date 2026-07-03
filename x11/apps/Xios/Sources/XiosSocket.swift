import Darwin

/// Connects a SOCK_STREAM AF_UNIX socket to `path`. Returns the fd, or -1 on
/// failure. SO_NOSIGPIPE keeps a dead peer from terminating the process.
func xiosConnectUnixSocket(_ path: String) -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return -1 }

    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on,
               socklen_t(MemoryLayout.size(ofValue: on)))

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
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

func xiosWriteAll(_ fd: Int32, bytes: UnsafeRawBufferPointer) -> Bool {
    guard let base = bytes.baseAddress else { return bytes.isEmpty }
    var offset = 0
    while offset < bytes.count {
        let wrote = Darwin.write(fd, base.advanced(by: offset), bytes.count - offset)
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

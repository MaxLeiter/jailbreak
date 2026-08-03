import Darwin
import Foundation
import os

/// Answers the one question that decides this extension's architecture: can an
/// app-extension process reach `/var/jb/tmp` at all?
///
/// It matters because an appex is NOT the host app. It is a separate process with
/// its own sandbox, and it does not inherit the app's entitlements — so the
/// `no-container` + absolute-path-exception recipe that lets IOSCLaunch and Xios
/// connect to `ioscd.sock` (see iosc-desktop/launcher-ent.xml) has to be granted
/// again here, and may simply not be honored for an extension. If it isn't, the
/// direct socket path is dead and everything has to route through the main app.
///
/// So the extension does not assume either answer: it probes, records, and falls
/// back. `report()` is written into the share sheet's own diagnostics view and
/// os_log'd, so a device run produces evidence either way.
enum XiosSandboxProbe {

    private static let log = Logger(subsystem: "com.max.xios.share", category: "sandbox")

    struct Result {
        let tmpDirExists: Bool
        let socketPathExists: Bool
        let socketConnects: Bool
        let tmpWritable: Bool
        let socketPath: String
        /// errno from the failing connect(), if it failed. EPERM/EACCES here is
        /// the sandbox denying us; ENOENT/ECONNREFUSED means ioscd is just down.
        let connectErrno: Int32

        /// True when the direct appex -> ioscd path is usable.
        var directPathUsable: Bool { socketConnects }

        /// Distinguishes "sandboxed away" from "daemon not running". Only the
        /// first one forces the fallback architecture.
        var deniedBySandbox: Bool {
            if socketConnects { return false }
            return connectErrno == EPERM || connectErrno == EACCES || !tmpDirExists
        }
    }

    static func run() -> Result {
        let socketPath = XiosRuntimePaths.firstExisting("ioscd.sock")
        let fm = FileManager.default

        let tmpDir = XiosRuntimePaths.runtimeTmp
        let tmpDirExists = fm.fileExists(atPath: tmpDir)
        let socketPathExists = fm.fileExists(atPath: socketPath)

        // A write probe distinguishes "can see it" from "can use it": on iOS a
        // sandbox denial can surface as a path that stats fine but refuses I/O.
        let probeFile = tmpDir + "/xios-share-probe.txt"
        var tmpWritable = false

        var connectErrno: Int32 = 0
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var connects = false
        if fd >= 0 {
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let ok: Bool = withUnsafeMutableBytes(of: &addr.sun_path) { raw in
                let bytes = Array(socketPath.utf8)
                guard bytes.count < raw.count else { return false }
                raw.copyBytes(from: bytes)
                return true
            }
            if ok {
                let rc = withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                    }
                }
                connects = rc == 0
                if !connects { connectErrno = errno }
            }
            close(fd)
        } else {
            // socket() itself denied is the strongest possible signal — that is
            // what a confined profile does (see x11-ios-sandbox-confinement).
            connectErrno = errno
        }

        let stamp = ISO8601DateFormatter().string(from: Date())
        let note = """
            xios share-extension sandbox probe
            when=\(stamp)
            tmp=\(tmpDir) exists=\(tmpDirExists)
            socket=\(socketPath) exists=\(socketPathExists) connects=\(connects) errno=\(connectErrno)

            """
        do {
            try note.write(toFile: probeFile, atomically: true, encoding: .utf8)
            tmpWritable = true
        } catch {
            tmpWritable = false
        }

        let result = Result(tmpDirExists: tmpDirExists,
                            socketPathExists: socketPathExists,
                            socketConnects: connects,
                            tmpWritable: tmpWritable,
                            socketPath: socketPath,
                            connectErrno: connectErrno)

        log.info("""
            appex sandbox probe: tmpDir=\(tmpDirExists, privacy: .public) \
            sock=\(socketPathExists, privacy: .public) \
            connect=\(connects, privacy: .public) \
            errno=\(connectErrno, privacy: .public) \
            write=\(tmpWritable, privacy: .public)
            """)
        return result
    }

    /// Human-readable, for the diagnostics view and the device-run artifact.
    static func report(_ r: Result) -> String {
        var lines: [String] = []
        lines.append("socket: \(r.socketPath)")
        lines.append("/var/jb/tmp visible: \(r.tmpDirExists ? "yes" : "no")")
        lines.append("socket present: \(r.socketPathExists ? "yes" : "no")")
        lines.append("connect(): \(r.socketConnects ? "ok" : "failed (errno \(r.connectErrno) — \(errnoName(r.connectErrno)))")")
        lines.append("/var/jb/tmp writable: \(r.tmpWritable ? "yes" : "no")")
        if r.socketConnects {
            lines.append("verdict: direct appex → ioscd path WORKS")
        } else if r.deniedBySandbox {
            lines.append("verdict: appex is SANDBOXED away from /var/jb — must route via the app")
        } else {
            lines.append("verdict: path reachable, but ioscd is not running")
        }
        return lines.joined(separator: "\n")
    }

    private static func errnoName(_ e: Int32) -> String {
        switch e {
        case EPERM: return "EPERM"
        case EACCES: return "EACCES"
        case ENOENT: return "ENOENT"
        case ECONNREFUSED: return "ECONNREFUSED"
        case 0: return "none"
        default: return String(cString: strerror(e))
        }
    }
}

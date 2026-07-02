import Darwin
import UIKit

private let xiosAppearanceMessageType: UInt32 = 13
private let xiosSysintSocket = "/var/jb/tmp/xios-sysint.sock"

private struct XiosSysintMessage {
    var type: UInt32
    var x: Int32
    var y: Int32
    var code: UInt32
    var state: UInt32
    var mods: UInt32
}

/// Mirrors this native host process' resolved iOS appearance into the desktop
/// session. This is the native-host sibling of Xios' SystemIntegration path.
final class HostSystemAppearance {
    static let shared = HostSystemAppearance()

    private var fd: Int32 = -1
    private var lastConnectAttempt = Date.distantPast
    private var desiredDark: Int32?
    private var sentDark: Int32?

    private init() {}

    func update(from traits: UITraitCollection) {
        let dark: Int32 = traits.userInterfaceStyle == .dark ? 1 : 0
        desiredDark = dark
        flush()
    }

    func update(from scene: UIScene) {
        if let windowScene = scene as? UIWindowScene {
            update(from: windowScene.traitCollection)
        } else {
            update(from: UITraitCollection.current)
        }
    }

    private func flush() {
        guard let dark = desiredDark, dark != sentDark else { return }
        guard ensureConnected() else { return }

        let msg = XiosSysintMessage(type: xiosAppearanceMessageType,
                                    x: 0, y: 0,
                                    code: dark == 0 ? 0 : 1,
                                    state: 0, mods: 0)
        if writeAll(msg) {
            sentDark = dark
        } else {
            closeConnection()
        }
    }

    private func ensureConnected() -> Bool {
        if fd >= 0 { return true }
        let now = Date()
        guard now.timeIntervalSince(lastConnectAttempt) >= 1 else { return false }
        lastConnectAttempt = now

        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }

        var noSigpipe: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe,
                   socklen_t(MemoryLayout.size(ofValue: noSigpipe)))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let sunPathCapacity = MemoryLayout.size(ofValue: addr.sun_path)
        _ = xiosSysintSocket.withCString { pathPtr in
            withUnsafeMutablePointer(to: &addr.sun_path) { tuplePtr in
                tuplePtr.withMemoryRebound(to: CChar.self,
                                           capacity: sunPathCapacity) { sunPath in
                    strncpy(sunPath, pathPtr, sunPathCapacity - 1)
                }
            }
        }

        let rc = withUnsafePointer(to: &addr) { addrPtr -> Int32 in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                connect(sock, saPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else {
            close(sock)
            return false
        }

        fd = sock
        return true
    }

    private func writeAll(_ msg: XiosSysintMessage) -> Bool {
        var message = msg
        return withUnsafeBytes(of: &message) { bytes in
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
    }

    private func closeConnection() {
        if fd >= 0 {
            close(fd)
            fd = -1
        }
    }
}

final class HostSceneViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        HostSystemAppearance.shared.update(from: traitCollection)
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        HostSystemAppearance.shared.update(from: traitCollection)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            HostSystemAppearance.shared.update(from: traitCollection)
        }
    }
}

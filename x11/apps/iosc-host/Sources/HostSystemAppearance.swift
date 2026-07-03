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

    private func flush() {
        guard let dark = desiredDark, dark != sentDark else { return }
        guard ensureConnected() else { return }

        let msg = XiosSysintMessage(type: xiosAppearanceMessageType,
                                    x: 0, y: 0,
                                    code: dark == 0 ? 0 : 1,
                                    state: 0, mods: 0)
        if writeMessage(msg) {
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

        fd = connectUnixSocket(xiosSysintSocket)
        return fd >= 0
    }

    private func writeMessage(_ msg: XiosSysintMessage) -> Bool {
        var message = msg
        return withUnsafeBytes(of: &message) { writeAll(fd, bytes: $0) }
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

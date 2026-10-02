import Darwin
import UIKit

private let xiosSysintSocket = "/var/jb/tmp/xios-sysint.sock"

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

        var msg = xios_input_message(UInt32(XIOS_IN_APPEARANCE), 0, 0,
                                     dark == 0 ? 0 : 1, 0, 0)
        if writeMessage(&msg) {
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
        guard fd >= 0 else { return false }
        // xios-sysintd reads the shared XiosProtocol.h framing: the stream must
        // open with an exact-version HELLO, or the first record is fatal.
        var hello = xios_protocol_hello()
        guard writeMessage(&hello) else {
            closeConnection()
            return false
        }
        return true
    }

    private func writeMessage(_ msg: inout xios_msg) -> Bool {
        withUnsafeBytes(of: &msg) { writeAll(fd, bytes: $0) }
    }

    private func closeConnection() {
        if fd >= 0 {
            close(fd)
            fd = -1
        }
    }
}

final class HostSceneViewController: UIViewController {
    /// Raw-touch mode (bundle IOSCRawTouch; see HostScreenView.rawTouch). Defer
    /// every screen-edge system gesture and auto-hide the home indicator, so
    /// edge touches reach the client without the iOS edge delay and the home
    /// gesture needs a second swipe instead of firing on the first. Normal mode
    /// keeps UIKit's defaults ([] and false).
    var rawTouch = false {
        didSet {
            guard rawTouch != oldValue else { return }
            setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
            setNeedsUpdateOfHomeIndicatorAutoHidden()
        }
    }

    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge {
        rawTouch ? .all : []
    }

    override var prefersHomeIndicatorAutoHidden: Bool { rawTouch }

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

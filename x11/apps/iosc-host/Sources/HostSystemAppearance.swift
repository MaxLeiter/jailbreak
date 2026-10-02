import Darwin
import UIKit

private let xiosSysintSocket = "/var/jb/tmp/xios-sysint.sock"

/// Mirrors this native host process' resolved iOS appearance into the desktop
/// session. This is the native-host sibling of Xios' SystemIntegration path.
///
/// The connection is a full v1 xios-sysintd client, so sysintd also broadcasts
/// to it (its HELLO, desktop volume and brightness). Nothing here uses those,
/// but they are read and dropped as they arrive: left unread they fill the
/// server's per-client queue and sysintd cuts the host off. When the connection
/// goes away (sysintd restarted, or a write failed) the current appearance is
/// sent again on the next one, retrying with a capped backoff until it lands.
final class HostSystemAppearance {
    static let shared = HostSystemAppearance()

    private var fd: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var lastConnectAttempt = Date.distantPast
    private var desiredDark: Int32?
    private var sentDark: Int32?
    private var retryDelay: TimeInterval = 1
    private var retryScheduled = false

    private init() {}

    func update(from traits: UITraitCollection) {
        let dark: Int32 = traits.userInterfaceStyle == .dark ? 1 : 0
        desiredDark = dark
        flush()
    }

    private func flush() {
        guard let dark = desiredDark, dark != sentDark else { return }
        guard ensureConnected() else { scheduleRetry(); return }

        var msg = xios_input_message(UInt32(XIOS_IN_APPEARANCE), 0, 0,
                                     dark == 0 ? 0 : 1, 0, 0)
        if writeMessage(&msg) {
            sentDark = dark
            retryDelay = 1
        } else {
            closeConnection()
            scheduleRetry()
        }
    }

    /// Try flush() again later, 1 s doubling to 30 s, until the appearance is
    /// delivered. One pending retry at a time.
    private func scheduleRetry() {
        guard !retryScheduled else { return }
        retryScheduled = true
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 30)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.retryScheduled = false
            self.flush()
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
        let connected = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: connected, queue: .main)
        source.setEventHandler { [weak self] in self?.drainInbound() }
        // The fd is closed only once the source is cancelled, so its number
        // can't be reused under a source that is still armed.
        source.setCancelHandler { close(connected) }
        source.resume()
        readSource = source
        return true
    }

    /// Read and drop whatever sysintd sent. EOF or an error means it went away.
    private func drainInbound() {
        var buf = [UInt8](repeating: 0, count: 4096)
        while fd >= 0 {
            let n = buf.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, MSG_DONTWAIT) }
            if n > 0 { continue }
            if n < 0 && errno == EINTR { continue }
            if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { return }
            closeConnection()
            scheduleRetry()
            return
        }
    }

    private func writeMessage(_ msg: inout xios_msg) -> Bool {
        withUnsafeBytes(of: &msg) { writeAll(fd, bytes: $0) }
    }

    /// A new connection starts from nothing: whatever reached the old one is
    /// sent again (sentDark = nil), so a restarted sysintd gets the current
    /// appearance without waiting for the next flip.
    private func closeConnection() {
        if let source = readSource {
            readSource = nil
            source.cancel()           // its cancel handler closes the fd
        } else if fd >= 0 {
            close(fd)
        }
        fd = -1
        sentDark = nil
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

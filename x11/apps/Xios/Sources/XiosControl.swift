import Darwin
import Foundation

/// UI-free client for ioscd's control socket (`/var/jb/tmp/ioscd.sock`).
///
/// XScreen.swift has spoken this protocol for a while, but only from inside a
/// 4000-line UIKit view controller. App Intents and the share extension need the
/// same wire without the view controller, so the transport lives here and imports
/// nothing above Foundation — an app extension links this too.
///
/// This is a CLIENT of the existing control paths, not a new one. It sends the
/// verbs ioscd already documents in its header comment, and it never sends a path
/// or a command line: app launches are an app id, and ioscd resolves that id to a
/// trusted root-owned desktop entry itself. Preserving that is the whole point of
/// the daemon, so the `appIDIsValid` mirror below is defense in depth, not the
/// enforcement — ioscd re-validates authoritatively via xios_desktop_app_id_valid.
enum XiosControl {

    static var socketPath: String { XiosRuntimePaths.firstExisting("ioscd.sock") }
    static var sessionStatusPath: String {
        XiosRuntimePaths.firstExisting("xios-session-status.json")
    }

    enum ControlError: Error, LocalizedError {
        /// The socket is absent or refused the connection — ioscd is not running.
        case daemonUnreachable
        /// ioscd accepted the request and replied ERR, or the reply never came.
        case refused(String)
        /// The client rejected the argument before it ever reached the socket.
        case invalidArgument(String)

        var errorDescription: String? {
            switch self {
            case .daemonUnreachable:
                return "The desktop daemon (ioscd) isn't running on this device."
            case .refused(let detail):
                return detail
            case .invalidArgument(let detail):
                return detail
            }
        }
    }

    // MARK: - Transport

    /// One request, one reply, one connection — ioscd closes after each.
    ///
    /// Blocking: callers are intent `perform()` bodies (already off the main
    /// thread) or the extension's handler. The socket carries SO_RCVTIMEO /
    /// SO_SNDTIMEO from xiosConnectUnixSocket, so a wedged daemon bounds out
    /// rather than hanging Siri.
    static func send(_ line: String, maxBytes: Int = 1 << 20,
                     timeout: TimeInterval = 5.0) -> String? {
        let fd = xiosConnectUnixSocket(socketPath, timeout: timeout)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        guard line.data(using: .utf8)?.withUnsafeBytes({ xiosWriteAll(fd, bytes: $0) }) == true
        else { return nil }
        Darwin.shutdown(fd, SHUT_WR)

        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while data.count < maxBytes {
            let n = buf.withUnsafeMutableBytes { raw in
                read(fd, raw.baseAddress, raw.count)
            }
            if n > 0 {
                data.append(buf, count: Int(n))
            } else if n < 0 && errno == EINTR {
                continue
            } else if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                return data.isEmpty ? nil : String(data: data, encoding: .utf8)
            } else {
                break
            }
        }
        return String(data: data, encoding: .utf8)
    }

    static func sendLines(_ line: String, maxBytes: Int = 1 << 20,
                          timeout: TimeInterval = 5.0) -> [String]? {
        guard let response = send(line, maxBytes: maxBytes, timeout: timeout) else { return nil }
        return response.split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Can we reach the daemon at all? Used by the share extension's sandbox
    /// probe and by Desktop Status to distinguish "no desktop" from "no daemon".
    static func daemonReachable() -> Bool {
        let fd = xiosConnectUnixSocket(socketPath, timeout: 1.0)
        guard fd >= 0 else { return false }
        close(fd)
        return true
    }

    // MARK: - Sessions

    /// The flavors `xios-session` accepts as a desktop preset. "native" is the
    /// per-app iPadOS flavor; it has no single fullscreen desktop, so intents
    /// that mean "show me the desktop" should not offer it as a silent default.
    static let desktopPresets = ["iosc", "gnome", "kde", "mutter", "native"]

    enum SessionOutcome {
        case started
        case alreadyActive
    }

    /// `SESSION\t<preset>\t<app>\t<w>\t<h>\t<dpi>\t<slot>\n`
    ///
    /// `ensure` selects the SESSION_ENSURE verb, which never tears down a healthy
    /// desktop. Plain SESSION from this app is honored as an explicit user switch
    /// because ioscd's peer_is_xios_app() recognizes the host binary path — which
    /// is exactly why the intents backed by this must run IN-PROCESS. See
    /// XiosIntents.swift.
    @discardableResult
    static func startSession(preset: String, app: String? = nil,
                             width: Int? = nil, height: Int? = nil,
                             dpi: Int? = nil, slot: String? = nil,
                             ensure: Bool = false) throws -> SessionOutcome {
        let clean = preset.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !clean.isEmpty, !clean.contains("\t"), !clean.contains("\n") else {
            throw ControlError.invalidArgument("\"\(preset)\" isn't a desktop flavor.")
        }
        if let app, !app.isEmpty, !appIDIsValid(app) {
            throw ControlError.invalidArgument("\"\(app)\" isn't a valid app id.")
        }

        // Spelled out rather than built as one array literal of `?? ""` /
        // `.map(String.init)` expressions: that form pushed the type checker past
        // its time limit ("unable to type-check in reasonable time").
        let verb: String = ensure ? "SESSION_ENSURE" : "SESSION"
        let appField: String = app ?? ""
        let slotField: String = slot ?? ""
        var widthField = ""
        var heightField = ""
        var dpiField = ""
        if let width { widthField = String(width) }
        if let height { heightField = String(height) }
        if let dpi { dpiField = String(dpi) }

        var fields: [String] = [verb, clean, appField]
        fields.append(widthField)
        fields.append(heightField)
        fields.append(dpiField)
        fields.append(slotField)

        let request: String = fields.joined(separator: "\t") + "\n"
        guard let reply = send(request, maxBytes: 4096) else {
            throw ControlError.daemonUnreachable
        }
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("SESSION_STARTED") { return .started }
        if trimmed.hasPrefix("SESSION_ACTIVE") { return .alreadyActive }
        throw ControlError.refused(describe(trimmed))
    }

    // MARK: - App launches

    /// Mirror of ioscd's xios_desktop_app_id_valid: printable, no space, no
    /// slash, no backslash, no tab, under 256 bytes. Rejecting here gives the
    /// user a real sentence instead of a bare ERR from the daemon.
    static func appIDIsValid(_ appID: String) -> Bool {
        let bytes = Array(appID.utf8)
        guard !bytes.isEmpty, bytes.count < 256 else { return false }
        for b in bytes {
            if b < 0x21 || b == 0x7f || b == UInt8(ascii: "/")
                || b == UInt8(ascii: "\\") || b == UInt8(ascii: "\t") {
                return false
            }
        }
        return true
    }

    /// `LAUNCH\t<app_id>\n` -> LAUNCHED | RAISED | ERR.
    ///
    /// Only an id crosses the socket. ioscd resolves it against the installed,
    /// root-owned desktop entries and execs the result without a shell.
    @discardableResult
    static func launchApp(_ appID: String, native: Bool = false) throws -> String {
        guard appIDIsValid(appID) else {
            throw ControlError.invalidArgument("\"\(appID)\" isn't a valid app id.")
        }
        let verb = native ? "LAUNCH_NATIVE" : "LAUNCH"
        guard let reply = send("\(verb)\t\(appID)\n", maxBytes: 4096) else {
            throw ControlError.daemonUnreachable
        }
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("LAUNCHED") { return "LAUNCHED" }
        if trimmed.hasPrefix("RAISED") { return "RAISED" }
        throw ControlError.refused(describe(trimmed))
    }

    /// `APPS_LIST\n` -> TSV rows + `APPS_END\t<status>`.
    static func apps() -> [LauncherApp] {
        guard let lines = sendLines("APPS_LIST\n") else { return [] }
        return lines
            .prefix { !$0.hasPrefix("APPS_END") }
            .compactMap { LauncherApp.parseIOSCDLine($0) }
    }

    /// Launchable set for an intent's app parameter: everything the user has
    /// left enabled in the launcher list.
    static func launchableApps() -> [LauncherApp] {
        apps().filter { $0.enabled }
    }

    // MARK: - Share-sheet handoff

    /// `OPEN_URL\t<url>\n` -> OPENED | ERR.
    ///
    /// The URL is DATA, never text to execute: ioscd validates the scheme and
    /// passes it as one argv element to a trusted root-owned xdg-open. Screening
    /// the scheme here too keeps obvious junk off the socket.
    static let openableSchemes: Set<String> = ["http", "https", "file", "mailto"]

    @discardableResult
    static func openURL(_ url: String) throws -> String {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count < 4096,
              !trimmed.contains("\t"), !trimmed.contains("\n"),
              let scheme = URL(string: trimmed)?.scheme?.lowercased(),
              openableSchemes.contains(scheme)
        else {
            throw ControlError.invalidArgument(
                "Only http, https, file and mailto links can be opened on the desktop.")
        }
        guard let reply = send("OPEN_URL\t\(trimmed)\n", maxBytes: 4096, timeout: 8.0) else {
            throw ControlError.daemonUnreachable
        }
        let response = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if response.hasPrefix("OPENED") { return response }
        throw ControlError.refused(describe(response))
    }

    // MARK: - Status

    struct StatusEntry {
        let producer: String
        let key: String
        let value: String
    }

    /// `STATUS\n` -> `<producer>\t<key>\t<value>` rows + `STATUS_END\t<count>`.
    /// Same table `xios-status` prints.
    static func runtimeStatus() -> [StatusEntry] {
        guard let lines = sendLines("STATUS\n") else { return [] }
        return lines
            .prefix { !$0.hasPrefix("STATUS_END") }
            .compactMap { line in
                let f = line.split(separator: "\t", omittingEmptySubsequences: false)
                guard f.count >= 3 else { return nil }
                return StatusEntry(producer: String(f[0]), key: String(f[1]),
                                   value: String(f[2]))
            }
    }

    /// Which desktop preset is up, from the file `xios-session` publishes.
    /// Distinct from runtimeStatus(), which reports how the compositor is
    /// behaving rather than which flavor is running.
    static func sessionStatus() -> SessionStatus? {
        SessionStatus.load(from: sessionStatusPath)
    }

    // MARK: - Helpers

    /// Turn ioscd's `ERR <msg>` into something worth reading aloud.
    private static func describe(_ reply: String) -> String {
        guard !reply.isEmpty else { return "The desktop daemon didn't respond." }
        if reply.hasPrefix("ERR ") {
            return String(reply.dropFirst(4))
                .split(separator: "\n").first.map(String.init) ?? reply
        }
        return reply
    }
}

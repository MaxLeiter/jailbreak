import Darwin
import Foundation

/// ioscd's request/reply socket. ioscd is deliberately single-threaded and KDE
/// startup or a launcher sync can keep it busy for seconds, so every request runs
/// on this serial worker with a bounded timeout and its completion comes back on
/// the main queue (invariant 27).
final class IOSCDClient {
    static let shared = IOSCDClient()

    private let queue = DispatchQueue(label: "com.max.xios.ioscd", qos: .userInitiated)

    /// Blocking primitive; only ever called on `queue`. `stopAtNewline` returns as
    /// soon as one complete line is in hand: single-reply verbs (SESSION) use it so
    /// a session child that inherited the socket cannot stall the reply to the recv
    /// timeout. Streaming verbs (APPS_LIST, APPS_SYNC) read to EOF.
    private func send(_ line: String, maxBytes: Int, timeout: TimeInterval,
                      stopAtNewline: Bool) -> Result<String, IOSCDProtocol.Failure> {
        let fd = xiosConnectUnixSocket(XiosRuntimePaths.firstExisting("ioscd.sock"),
                                       timeout: timeout)
        guard fd >= 0 else { return .failure(.init(connectErrno: errno)) }
        defer { close(fd) }
        guard line.data(using: .utf8)?.withUnsafeBytes({ xiosWriteAll(fd, bytes: $0) }) == true
        else { return .failure(.unreachable(errno)) }
        Darwin.shutdown(fd, SHUT_WR)

        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while data.count < maxBytes {
            let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                data.append(buf, count: Int(n))
                if stopAtNewline, data.contains(UInt8(ascii: "\n")) { break }
            } else if n < 0 && errno == EINTR {
                continue
            } else if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                return .failure(.timedOut)
            } else {
                break
            }
        }
        guard !data.isEmpty else { return .failure(.noReply) }
        return .success(String(decoding: data, as: UTF8.self))
    }

    func request(_ line: String, maxBytes: Int = 1 << 20, timeout: TimeInterval = 2.0,
                 stopAtNewline: Bool = false,
                 completion: @escaping (Result<String, IOSCDProtocol.Failure>) -> Void) {
        queue.async { [self] in
            let response = send(line, maxBytes: maxBytes, timeout: timeout,
                                stopAtNewline: stopAtNewline)
            DispatchQueue.main.async { completion(response) }
        }
    }

    /// A successful reply always has at least one line (APPS_END, or ERR).
    func requestLines(_ line: String, timeout: TimeInterval = 2.0,
                      completion: @escaping (Result<[String], IOSCDProtocol.Failure>) -> Void) {
        request(line, timeout: timeout) { response in
            completion(response.flatMap { text in
                let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
                    .map { String($0).trimmingCharacters(in: .newlines) }
                    .filter { !$0.isEmpty }
                return lines.isEmpty ? .failure(.noReply) : .success(lines)
            })
        }
    }

    // MARK: verbs

    func session(preset: String, app: String? = nil, display: DisplayProfile? = nil,
                 slot: String? = nil,
                 completion: @escaping (IOSCDProtocol.SessionReply) -> Void) {
        let line = IOSCDProtocol.sessionLine(preset: preset, app: app,
                                             display: display, slot: slot)
        request(line, maxBytes: 4096, stopAtNewline: true) {
            completion(IOSCDProtocol.SessionReply($0))
        }
    }

    func appsList(completion: @escaping (IOSCDProtocol.AppsList) -> Void) {
        requestLines("APPS_LIST\n", timeout: 5.0) { result in
            switch result {
            case .success(let lines): completion(IOSCDProtocol.parseAppsList(lines))
            case .failure(let failure): completion(.init(apps: [], error: failure.description))
            }
        }
    }

    func setAppEnabled(_ app: LauncherApp, enabled: Bool,
                       completion: @escaping (String?) -> Void) {
        let verb = enabled ? "APP_ENABLE" : "APP_DISABLE"
        requestLines("\(verb)\t\(app.id)\n", timeout: 5.0) { result in
            switch result {
            case .failure(let failure):
                completion(failure.description)
            case .success(let lines):
                let last = lines.last ?? ""
                completion(last == "APPS_END\t0" ? nil : (lines.first ?? last))
            }
        }
    }

    func syncLaunchers(native: Bool, dryRun: Bool,
                       completion: @escaping (Result<[String], IOSCDProtocol.Failure>) -> Void) {
        requestLines("APPS_SYNC\t\(native ? "native" : "classic")\t\(dryRun ? "dry" : "apply")\n",
                     timeout: 15.0, completion: completion)
    }

    /// VoiceOver state for the desktop-side accessibility helper (invariant 59).
    func sendA11yState(_ enabled: Bool, completion: @escaping (Bool) -> Void) {
        request("A11Y_STATE\t\(enabled ? 1 : 0)\n", maxBytes: 256, timeout: 2.0,
                stopAtNewline: true) { completion((try? $0.get()) != nil) }
    }
}

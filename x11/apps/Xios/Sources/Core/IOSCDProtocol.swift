import Foundation

/// Line formats for ioscd's request/reply socket. Pure, so the exact bytes the
/// daemon parses are testable (a wrong field count silently shifts the slot).
enum IOSCDProtocol {
    /// SESSION\t<preset>\t<app>\t<w>\t<h>\t<dpi>\t<slot>\n
    /// Size fields are only meaningful for a desktop start; `app` and `stop`
    /// never carry one.
    static func sessionLine(preset: String, app: String? = nil,
                            display: DisplayProfile? = nil, slot: String? = nil) -> String {
        var width = "", height = "", dpi = ""
        if preset != "app", preset != "stop", let display {
            width = String(display.width)
            height = String(display.height)
            if display.dpi > 0 { dpi = String(display.dpi) }
        }
        return ["SESSION", preset, app ?? "", width, height, dpi, slot ?? ""]
            .joined(separator: "\t") + "\n"
    }

    /// Why a request got no answer, worded for the status line. Every one of these
    /// used to read "ioscd timed out", including the common case where ioscd was
    /// never installed (GitHub issue #11).
    enum Failure: Error, Equatable, CustomStringConvertible {
        case notRunning
        case unreachable(Int32)
        case timedOut
        case noReply

        /// connect(2) failing with nothing listening (no socket, or a stale one)
        /// means the daemon is down, not slow.
        init(connectErrno err: Int32) {
            self = err == ENOENT || err == ECONNREFUSED ? .notRunning : .unreachable(err)
        }

        var description: String {
            switch self {
            case .notRunning: return "ioscd is not running (is xios-launcher-tools installed?)"
            case .unreachable(let err): return "cannot reach ioscd: \(String(cString: strerror(err)))"
            case .timedOut: return "ioscd timed out"
            case .noReply: return "ioscd sent no reply"
            }
        }
    }

    enum SessionReply: Equatable {
        case started
        case failed(String)

        init(_ raw: Result<String, Failure>) {
            switch raw {
            case .failure(let failure):
                self = .failed(failure.description)
            case .success(let reply):
                let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.hasPrefix("SESSION_STARTED") || text.hasPrefix("SESSION_ACTIVE") {
                    self = .started
                } else {
                    self = .failed(text.isEmpty ? Failure.noReply.description : text)
                }
            }
        }
    }

    /// APPS_LIST reply: TSV rows then APPS_END\t<status>. An `ERR` line ends it early.
    struct AppsList {
        var apps: [LauncherApp]
        var error: String?
    }

    static func parseAppsList(_ lines: [String]) -> AppsList {
        var apps: [LauncherApp] = []
        for line in lines {
            if line.hasPrefix("ERR ") { return AppsList(apps: sorted(apps), error: line) }
            if line.hasPrefix("APPS_END") { break }
            if let app = LauncherApp.parse(line: line) { apps.append(app) }
        }
        return AppsList(apps: sorted(apps), error: nil)
    }

    private static func sorted(_ apps: [LauncherApp]) -> [LauncherApp] {
        apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// ioscd's own rule for a desktop-file id (xios_desktop_file_id_valid): 1 to
    /// 200 bytes of [A-Za-z0-9._+-], no leading '.' or '-', no "..". It also keeps
    /// the id one tab-free, newline-free field of the SESSION line.
    static func isValidDesktopFileID(_ id: String) -> Bool {
        let bytes = Array(id.utf8)
        guard (1...200).contains(bytes.count),
              bytes[0] != UInt8(ascii: "."), bytes[0] != UInt8(ascii: "-"),
              !id.contains("..") else { return false }
        return bytes.allSatisfy { b in
            (b >= UInt8(ascii: "a") && b <= UInt8(ascii: "z")) ||
            (b >= UInt8(ascii: "A") && b <= UInt8(ascii: "Z")) ||
            (b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9")) ||
            b == UInt8(ascii: ".") || b == UInt8(ascii: "_") ||
            b == UInt8(ascii: "+") || b == UInt8(ascii: "-")
        }
    }
}

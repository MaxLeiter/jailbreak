import Foundation

/// A process as presented in the UI: raw sample enriched with a computed CPU
/// rate, installed-app identity, and short history rings for the sparklines.
struct ProcessRow: Identifiable {
    let pid: pid_t
    var id: pid_t { pid }
    let ppid: pid_t
    let uid: uid_t

    /// App display name when matched to an installed bundle, else the process
    /// name from libproc.
    let displayName: String
    /// Raw process/executable name, always shown in the detail sheet.
    let processName: String
    let executablePath: String?
    let bundleID: String?
    var isApp: Bool { bundleID != nil }

    let residentBytes: UInt64
    let cpuPercent: Double        // percent of one core; multithreaded procs can exceed 100
    let threadCount: Int
    let startEpoch: TimeInterval

    /// Rolling history (oldest→newest), capped at `History.capacity` samples.
    var cpuHistory: [Double]      // percent
    var memoryHistory: [Double]   // megabytes

    var residentMB: Double { Double(residentBytes) / 1_048_576 }
    var uptime: TimeInterval { startEpoch > 0 ? Date().timeIntervalSince1970 - startEpoch : 0 }

    /// Whether this row satisfies a search query — display name, raw process
    /// name, or bundle id. Lives here (not in the view) so it sits at the same
    /// altitude as `ListScope.includes`.
    func matches(_ query: String) -> Bool {
        displayName.localizedCaseInsensitiveContains(query)
            || processName.localizedCaseInsensitiveContains(query)
            || (bundleID?.localizedCaseInsensitiveContains(query) ?? false)
    }
}

enum History {
    /// 60 samples at 1 Hz ≈ one minute of sparkline.
    static let capacity = 60

    /// Append `value`, dropping the oldest to stay within `capacity`.
    static func push(_ value: Double, into buffer: inout [Double]) {
        buffer.append(value)
        if buffer.count > capacity { buffer.removeFirst(buffer.count - capacity) }
    }
}

import Foundation

/// One process as observed in a single sampling pass. Cumulative counters
/// (`cpuTicks`) are turned into rates by `MonitorEngine`, which diffs
/// consecutive passes.
struct ProcessSample: Identifiable {
    let pid: pid_t
    var id: pid_t { pid }
    let ppid: pid_t
    let uid: uid_t
    /// Best-effort process name (from libproc, up to 32 chars). Not the app's
    /// display name — `InstalledAppsIndex` attaches that separately.
    let name: String
    let executablePath: String?
    let residentBytes: UInt64
    let virtualBytes: UInt64
    /// Cumulative user+system CPU time since the process started, in
    /// **mach-absolute-time units** (NOT nanoseconds — `PROC_PIDTASKALLINFO`'s
    /// `pti_total_*` come straight from `TASK_ABSOLUTETIME_INFO`, verified on
    /// device: 1 tick ≈ 41.7 ns on the A10). `MonitorEngine` diffs this against
    /// the wall clock, which `mach_absolute_time()` reports in the same units,
    /// so no timebase conversion is needed.
    let cpuTicks: UInt64
    let threadCount: Int
    /// Wall-clock start time (epoch seconds), for the "uptime" readout.
    let startEpoch: TimeInterval
}

/// Enumerates every live process and reads its per-process resource usage via
/// `sysctl(KERN_PROC_ALL)` + `proc_pidinfo(PROC_PIDTASKALLINFO)`.
///
/// This is stateless: it returns a raw snapshot. Rates, history and identity
/// live in `MonitorEngine`. Sampling is cheap enough (a few hundred syscalls)
/// to run at 1 Hz on an A10.
enum ProcessSampler {
    /// Live pid list from the kernel. Returns pids only; per-process detail is
    /// pulled with `proc_pidinfo` because that also carries the fuller name,
    /// parent, uid and start time in one call.
    private static func livePIDs() -> [pid_t] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var length = 0
        // First call sizes the buffer. The set of processes can change between
        // the sizing call and the data call, so oversize slightly and re-check.
        guard sysctl(&mib, 4, nil, &length, nil, 0) == 0, length > 0 else { return [] }
        let count = length / MemoryLayout<kinfo_proc>.stride + 16
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
        var got = count * MemoryLayout<kinfo_proc>.stride
        let r = procs.withUnsafeMutableBytes { raw -> Int32 in
            sysctl(&mib, 4, raw.baseAddress, &got, nil, 0)
        }
        guard r == 0 else { return [] }
        let n = got / MemoryLayout<kinfo_proc>.stride
        return (0..<n).compactMap { i -> pid_t? in
            let pid = procs[i].kp_proc.p_pid
            return pid > 0 ? pid : nil
        }
    }

    /// Per-process detail. Returns `nil` when the process has exited between
    /// enumeration and this call (a routine race — `proc_pidinfo` then returns
    /// a short count) or when the kernel denies the read.
    private static func detail(for pid: pid_t) -> ProcessSample? {
        var info = proc_taskallinfo()
        let size = Int32(MemoryLayout<proc_taskallinfo>.size)
        let r = proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, &info, size)
        guard r == Int(size) else { return nil }

        let name = procName(&info.pbsd) ?? "pid \(pid)"
        return ProcessSample(
            pid: pid,
            ppid: pid_t(bitPattern: info.pbsd.pbi_ppid),
            uid: info.pbsd.pbi_uid,
            name: name,
            executablePath: executablePath(for: pid),
            residentBytes: info.ptinfo.pti_resident_size,
            virtualBytes: info.ptinfo.pti_virtual_size,
            cpuTicks: info.ptinfo.pti_total_user &+ info.ptinfo.pti_total_system,
            threadCount: Int(info.ptinfo.pti_threadnum),
            startEpoch: TimeInterval(info.pbsd.pbi_start_tvsec)
        )
    }

    /// Full snapshot of every readable process.
    static func sample() -> [ProcessSample] {
        livePIDs().compactMap(detail(for:))
    }

    // MARK: - libproc string helpers

    private static func executablePath(for pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: Int(PROC_PIDPATHINFO_MAXSIZE))
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return nil }
        return String(cString: buf)
    }

    /// Prefer `pbi_name` (up to 2*MAXCOMLEN) and fall back to the 16-char
    /// `pbi_comm`. Both are fixed C arrays imported into Swift as tuples.
    private static func procName(_ bsd: inout proc_bsdinfo) -> String? {
        let full = withUnsafeBytes(of: &bsd.pbi_name) { raw -> String in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        if !full.isEmpty { return full }
        let comm = withUnsafeBytes(of: &bsd.pbi_comm) { raw -> String in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        return comm.isEmpty ? nil : comm
    }
}

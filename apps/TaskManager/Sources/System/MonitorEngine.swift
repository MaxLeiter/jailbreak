import Foundation
import Combine

/// The live model backing the whole app. Runs a 1 Hz sampling loop while the
/// app is foregrounded, diffs consecutive samples into CPU rates, keeps
/// per-process history rings, and publishes a ready-to-render snapshot.
///
/// Foreground-only by design: this is a live monitor, not a background daemon,
/// so `RootView` pauses it on `scenePhase != .active`.
@MainActor
final class MonitorEngine: ObservableObject {
    @Published private(set) var rows: [ProcessRow] = []
    @Published private(set) var memory = MemorySnapshot(
        total: 0, wired: 0, active: 0, inactive: 0, compressed: 0, free: 0)
    /// Per-core utilisation, 0…100.
    @Published private(set) var coreUsage: [Double] = []
    /// Mean utilisation across all cores, 0…100 (the dashboard "avg").
    ///
    /// CPU scale convention (top-style): a **per-process** `cpuPercent` is a
    /// share of *one* core, so a fully single-threaded-busy process reads 100%
    /// and a multithreaded one can exceed it (up to cores × 100). The system
    /// figure here is the **mean** across cores, 0…100. They reconcile as
    /// `Σ(per-process %) ≈ cores × overallCPU`.
    @Published private(set) var overallCPU: Double = 0
    @Published private(set) var overallCPUHistory: [Double] = []
    @Published private(set) var lastUpdate = Date()

    let appIndex = InstalledAppsIndex()

    private var timer: Timer?
    private var isRunning = false

    // Diff state.
    private var prevCPU: [pid_t: UInt64] = [:]       // pid -> cumulative cpu ticks (mach units)
    private var prevWall: UInt64 = 0                  // mach_absolute_time units
    private var prevCores: [CoreTicks] = []
    private var cpuHistory: [pid_t: [Double]] = [:]
    private var memHistory: [pid_t: [Double]] = [:]

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
        tick()   // immediate first frame so the UI isn't empty
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)   // keep sampling during scroll
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isRunning = false
    }

    // MARK: - Sampling

    private func tick() {
        let now = mach_absolute_time()
        // Wall interval in mach-absolute units — the same units as a process's
        // cumulative cpuTicks, so the ratio is unitless (no timebase needed).
        let elapsedTicks = prevWall == 0 ? 0 : now &- prevWall
        let samples = ProcessSampler.sample()

        var newRows: [ProcessRow] = []
        newRows.reserveCapacity(samples.count)
        var nextCPU: [pid_t: UInt64] = [:]
        nextCPU.reserveCapacity(samples.count)
        var nextCPUHist: [pid_t: [Double]] = [:]
        var nextMemHist: [pid_t: [Double]] = [:]
        let livePIDs = Set(samples.map(\.pid))

        for s in samples {
            nextCPU[s.pid] = s.cpuTicks
            var cpuPercent = 0.0
            if elapsedTicks > 0, let prior = prevCPU[s.pid], s.cpuTicks >= prior {
                // Share of one core: CPU ticks consumed ÷ wall ticks elapsed.
                cpuPercent = Double(s.cpuTicks - prior) / Double(elapsedTicks) * 100
            }

            let identity = appIndex.identity(forExecutablePath: s.executablePath)
            var cpuHist = cpuHistory[s.pid] ?? []
            var memHist = memHistory[s.pid] ?? []
            History.push(cpuPercent, into: &cpuHist)
            History.push(Double(s.residentBytes) / 1_048_576, into: &memHist)
            nextCPUHist[s.pid] = cpuHist
            nextMemHist[s.pid] = memHist

            newRows.append(ProcessRow(
                pid: s.pid, ppid: s.ppid, uid: s.uid,
                displayName: identity?.displayName ?? s.name,
                processName: s.name,
                executablePath: s.executablePath,
                bundleID: identity?.bundleID,
                residentBytes: s.residentBytes,
                cpuPercent: cpuPercent,
                threadCount: s.threadCount,
                startEpoch: s.startEpoch,
                cpuHistory: cpuHist,
                memoryHistory: memHist))
        }

        prevCPU = nextCPU
        cpuHistory = nextCPUHist.filter { livePIDs.contains($0.key) }
        memHistory = nextMemHist.filter { livePIDs.contains($0.key) }
        prevWall = now

        rows = newRows
        memory = SystemStats.memory()
        updateCPU(elapsedValid: elapsedTicks > 0)
        lastUpdate = Date()
    }

    private func updateCPU(elapsedValid: Bool) {
        let cores = SystemStats.cpuCores()
        defer { prevCores = cores }
        guard elapsedValid, prevCores.count == cores.count, !cores.isEmpty else {
            coreUsage = Array(repeating: 0, count: cores.count)
            return
        }
        var usages: [Double] = []
        usages.reserveCapacity(cores.count)
        for (now, prev) in zip(cores, prevCores) {
            let totalDelta = Double(now.total &- prev.total)
            let busyDelta = Double(now.busy &- prev.busy)
            usages.append(totalDelta > 0 ? min(100, max(0, busyDelta / totalDelta * 100)) : 0)
        }
        coreUsage = usages
        let mean = usages.reduce(0, +) / Double(usages.count)
        overallCPU = mean
        History.push(mean, into: &overallCPUHistory)
    }
}

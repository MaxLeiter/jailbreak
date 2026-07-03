import Foundation

/// Device-wide memory picture, one snapshot. Bytes.
struct MemorySnapshot {
    let total: UInt64
    let wired: UInt64
    let active: UInt64
    let inactive: UInt64
    let compressed: UInt64
    let free: UInt64

    /// Everything that isn't free — includes reclaimable file cache, so on iOS
    /// it sits near 100% and isn't a useful gauge on its own.
    var used: UInt64 { total > free ? total - free : 0 }

    /// Memory genuinely committed to running work: wired (kernel/pinned) + active
    /// (in-use app pages) + compressed. Excludes inactive file cache and free,
    /// which are reclaimable — this is the number that actually moves under load
    /// and the one the dashboard ring shows.
    var appUsed: UInt64 { wired + active + compressed }
    var appUsedFraction: Double { total > 0 ? min(1, Double(appUsed) / Double(total)) : 0 }
    var available: UInt64 { total > appUsed ? total - appUsed : 0 }
}

/// Cumulative CPU tick counts for one logical core (from the kernel's
/// `PROCESSOR_CPU_LOAD_INFO`). `MonitorEngine` diffs these to get utilisation.
struct CoreTicks {
    let user: UInt32
    let system: UInt32
    let idle: UInt32
    let nice: UInt32
    var total: UInt64 { UInt64(user) + UInt64(system) + UInt64(idle) + UInt64(nice) }
    var busy: UInt64 { UInt64(user) + UInt64(system) + UInt64(nice) }
}

/// Reads whole-device counters via Mach host APIs. Stateless, like
/// `ProcessSampler`; the engine turns tick counters into percentages.
enum SystemStats {
    /// Physical RAM, from `sysctl(HW_MEMSIZE)`. Constant for the device, so
    /// computed once.
    static let physicalMemory: UInt64 = {
        var size: UInt64 = 0
        var len = MemoryLayout<UInt64>.size
        var mib: [Int32] = [CTL_HW, HW_MEMSIZE]
        guard sysctl(&mib, 2, &size, &len, nil, 0) == 0 else { return 0 }
        return size
    }()

    private static let pageSize: UInt64 = {
        var size: vm_size_t = 0
        host_page_size(mach_host_self(), &size)
        return UInt64(size)
    }()

    static func memory() -> MemorySnapshot {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        let page = pageSize
        guard kr == KERN_SUCCESS else {
            return MemorySnapshot(total: physicalMemory, wired: 0, active: 0,
                                  inactive: 0, compressed: 0, free: physicalMemory)
        }
        return MemorySnapshot(
            total: physicalMemory,
            wired: UInt64(stats.wire_count) * page,
            active: UInt64(stats.active_count) * page,
            inactive: UInt64(stats.inactive_count) * page,
            compressed: UInt64(stats.compressor_page_count) * page,
            free: UInt64(stats.free_count) * page)
    }

    /// Per-core cumulative ticks. Empty on failure.
    static func cpuCores() -> [CoreTicks] {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                     &cpuCount, &info, &infoCount)
        guard kr == KERN_SUCCESS, let info else { return [] }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride))
        }
        let perCore = Int(CPU_STATE_MAX)
        return (0..<Int(cpuCount)).map { i in
            let base = i * perCore
            return CoreTicks(
                user: UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]),
                system: UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]),
                idle: UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]),
                nice: UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
        }
    }
}

import Foundation

/// Sends termination signals to other processes. Thin wrapper over `kill(2)`
/// with one hard guard: it refuses to signal TaskManager's own process, so a
/// stray tap can't kill the app mid-action.
enum ProcessKiller {
    enum Signal {
        case quit       // SIGTERM — polite, lets the process clean up
        case forceKill  // SIGKILL — immediate, uncatchable

        var raw: Int32 { self == .quit ? SIGTERM : SIGKILL }
        var label: String { self == .quit ? "Quit" : "Force Kill" }
    }

    enum Result: Equatable {
        case ok
        case refusedOwnProcess
        case notPermitted        // EPERM — kernel denied the signal
        case noSuchProcess       // ESRCH — already gone
        case failed(Int32)       // other errno
    }

    static func send(_ signal: Signal, to pid: pid_t) -> Result {
        guard pid != getpid() else { return .refusedOwnProcess }
        guard pid > 1 else { return .notPermitted }   // never touch pid 0/1
        if kill(pid, signal.raw) == 0 { return .ok }
        switch errno {
        case EPERM: return .notPermitted
        case ESRCH: return .noSuchProcess
        default: return .failed(errno)
        }
    }
}

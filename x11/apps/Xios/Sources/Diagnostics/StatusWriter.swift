import Foundation

/// Every diagnostic the app writes to disk goes through here: one serial
/// background queue, and a file is rewritten only when its text changed. Nothing
/// on the main thread or the touch path touches the filesystem (v2 rule).
///
/// The files keep their pre-v2 names and formats because tooling reads them:
///   xios-status.txt   what the presented desktop is doing (trust this one)
///   xios-geom.txt     view/drawable/framebuffer geometry
///   xios-touch.log    the latest committed press, for tap verification
///   xios-metal.txt    last Metal setup stage
/// plus xios-app-sessions.txt, one line per known desktop.
final class StatusWriter {
    static let shared = StatusWriter()

    private let queue = DispatchQueue(label: "com.max.xios.status", qos: .utility)
    private var lastText: [String: String] = [:]
    private var lastValue: [String: String] = [:]
    private var started = false

    /// Name this process in the shared status table explicitly rather than relying
    /// on getprogname(); iosc_status drops a table a killed predecessor left
    /// behind (invariant 29). Runs first on the queue, so every later set is ordered
    /// after it.
    func start() {
        queue.async { [self] in
            guard !started else { return }
            started = true
            iosc_status_set_producer("Xios")
        }
    }

    /// Replace the file `name` (under the runtime tmp dir) when `text` changed.
    func write(_ name: String, _ text: String) {
        queue.async { [self] in
            guard lastText[name] != text else { return }
            lastText[name] = text
            try? text.write(toFile: XiosRuntimePaths.tmp(name), atomically: true,
                            encoding: .utf8)
        }
    }

    /// Unconditional write for on-demand artifacts (debug snapshot, touch log).
    func overwrite(_ name: String, _ text: String) {
        queue.async {
            try? text.write(toFile: XiosRuntimePaths.tmp(name), atomically: true,
                            encoding: .utf8)
        }
    }

    /// Latch a key in the shared runtime status table (`pacing`, `upscale`).
    func setValue(_ key: String, _ value: String) {
        queue.async { [self] in
            guard lastValue[key] != value else { return }
            lastValue[key] = value
            iosc_status_set_value(key, value)
        }
    }

    // MARK: named artifacts

    func touchLog(_ text: String) { overwrite("xios-touch.log", text) }
    func geometry(_ text: String) { write("xios-geom.txt", text) }
    func metal(_ stage: String) { write("xios-metal.txt", stage) }
}

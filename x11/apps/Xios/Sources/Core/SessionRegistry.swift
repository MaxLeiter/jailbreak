import Foundation

/// Discovers desktops from the files the launcher scripts already write:
///   - the global xios.json + xios-session-status.json  -> slot "main"
///   - /var/jb/tmp/xios-displays.d/*.json               -> one slot each, which
///     names that slot's xios-<slot>.json
/// Everything runs on one background queue. Change detection is kqueue vnode
/// watches on those paths plus a slow fallback poll; the main thread only ever
/// receives a finished, changed snapshot.
///
/// Endpoints come only from each session's own config (invariant 47). A torn
/// read (the writers use plain fopen("w")) is retried and then ignored in favour
/// of the last good value: it is never treated as "the session is gone".
final class SessionRegistry {
    /// Delivered on the main queue, only when the snapshot changed.
    var onChange: (([SessionInfo]) -> Void)?
    /// A start, restart or resize that was handed to xios-session failed:
    /// (slot, preset, xios-session's own words). Main queue.
    var onStartFailed: ((_ slot: String, _ preset: String, _ why: String) -> Void)?

    private let queue = DispatchQueue(label: "com.max.xios.registry", qos: .utility)
    private var watchers: [String: FileWatcher] = [:]
    private var timer: DispatchSourceTimer?
    private var scanPending = false
    private var running = false

    // All below: queue only.
    private var lastPublished: [SessionInfo]?
    private var lastGoodJSON: [String: [String: Any]] = [:]
    private var socketMissingSince: [String: Date] = [:]
    private var dismissed: [String: String] = [:]   // slot -> stamp that was dismissed
    /// Requests whose outcome is read from their status file (see
    /// SessionParsing.startFailure), keyed by slot.
    private struct StartWatch {
        let statusPath: String
        let preset: String
        let since: Date
    }
    private var startWatches: [String: StartWatch] = [:]
    /// How long a request's status file is watched for a failure.
    static let startWatchSeconds: TimeInterval = 60

    private static let fallbackPollSeconds = 2.0
    private static let debounce = 0.08
    /// A running desktop whose display socket has been gone this long is `killed`
    /// (was the dead-pin rule of 3 consecutive 1.5 s polls, invariant 28).
    static let killedAfter: TimeInterval = 3.0

    init() {
        if let saved = UserDefaults.standard.dictionary(forKey: "XiosDismissedSessions")
            as? [String: String] { dismissed = saved }
    }

    func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + Self.fallbackPollSeconds,
                       repeating: Self.fallbackPollSeconds, leeway: .milliseconds(300))
            t.setEventHandler { [weak self] in self?.scan() }
            t.resume()
            timer = t
            scan()
        }
    }

    func stop() {
        queue.async { [self] in
            running = false
            timer?.cancel(); timer = nil
            for w in watchers.values { w.cancel() }
            watchers.removeAll()
        }
    }

    /// Ask for a scan soon (after an action the user just took).
    func refreshNow() { scheduleScan(after: 0.02) }

    /// Watch the status file a SESSION request for `slot` writes, and report a
    /// failure for `preset` written after `since` through `onStartFailed`. Ends on
    /// the first failure or after `startWatchSeconds`; a newer request for the same
    /// slot replaces it. The file may not exist yet: the fallback poll and the
    /// rescans below pick it up.
    func watchStart(slot: String, statusPath: String, preset: String, since: Date = Date()) {
        queue.async { [self] in
            startWatches[slot] = StartWatch(statusPath: statusPath, preset: preset, since: since)
        }
        // xios-session's preflight runs within a second or two of the fork.
        for delay in [0.4, 1.2, 2.5, 5.0] { scheduleScan(after: delay, coalesce: false) }
    }

    /// Hide a failed/killed/stopped card until the launcher writes a newer state.
    func dismiss(slot: String, stamp: String) {
        queue.async { [self] in
            dismissed[slot] = stamp
            UserDefaults.standard.set(dismissed, forKey: "XiosDismissedSessions")
            scan(forcePublish: true)
        }
    }

    // MARK: scanning (queue)

    /// `coalesce` folds the request into a scan that is already pending (kqueue
    /// bursts); a timed rescan passes false so it is not swallowed by an earlier one.
    private func scheduleScan(after delay: TimeInterval = SessionRegistry.debounce,
                              coalesce: Bool = true) {
        queue.async { [self] in
            guard running else { return }
            guard coalesce else {
                queue.asyncAfter(deadline: .now() + delay) { [self] in scan() }
                return
            }
            guard !scanPending else { return }
            scanPending = true
            queue.asyncAfter(deadline: .now() + delay) { [self] in
                scanPending = false
                scan()
            }
        }
    }

    private enum ReadResult {
        case value([String: Any])
        case missing
        case unreadable
    }

    /// Read + parse one JSON object. A short or unparsable read is retried a few
    /// times (the writer may be mid-write); if it stays unreadable the caller
    /// keeps the last good value.
    private func readJSON(_ path: String) -> ReadResult {
        for attempt in 0..<4 {
            guard let data = FileManager.default.contents(atPath: path) else {
                // Distinguish "not there" from "could not read it right now".
                return FileManager.default.fileExists(atPath: path) ? .unreadable : .missing
            }
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                lastGoodJSON[path] = obj
                return .value(obj)
            }
            if attempt < 3 { Thread.sleep(forTimeInterval: 0.02) }
        }
        return .unreadable
    }

    /// The value to use for `path`: the fresh read, the last good one for a torn
    /// read, nil for a file that is really gone (and its cache entry dropped).
    private func json(_ path: String) -> [String: Any]? {
        switch readJSON(path) {
        case .value(let obj): return obj
        case .unreadable: return lastGoodJSON[path]
        case .missing:
            lastGoodJSON[path] = nil
            return nil
        }
    }

    private func scan(forcePublish: Bool = false) {
        guard running else { return }
        let globalConfigPath = XiosRuntimePaths.firstExisting("xios.json")
        let statusPath = XiosRuntimePaths.firstExisting("xios-session-status.json")
        let defaults = SessionParsing.Defaults(
            sysint: XiosRuntimePaths.firstExisting("xios-sysint.sock"),
            a11y: XiosRuntimePaths.firstExisting("xios-a11y.sock"))

        // The specific files and the displays directory only: the tmp dir itself is
        // busy with unrelated files. A global file that does not exist yet is picked
        // up by the fallback poll.
        var watchPaths: Set<String> = [
            globalConfigPath, statusPath, XiosRuntimePaths.displaysDir,
        ]
        var infos: [SessionInfo] = []

        let globalConfig = json(globalConfigPath)
        if let main = SessionParsing.main(config: globalConfig, status: json(statusPath),
                                          configPath: globalConfigPath, defaults: defaults) {
            infos.append(main)
        }

        let dir = XiosRuntimePaths.displaysDir
        let entries = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
            .filter { $0.hasSuffix(".json") }.sorted()
        for entry in entries {
            let entryPath = XiosRuntimePaths.join(dir, entry)
            watchPaths.insert(entryPath)
            guard let obj = json(entryPath) else { continue }
            let config = (obj["json"] as? String).flatMap { path -> [String: Any]? in
                watchPaths.insert(path)
                return json(path)
            }
            guard let info = SessionParsing.slot(
                entry: obj, fallbackName: (entry as NSString).deletingPathExtension,
                config: config, defaults: defaults) else { continue }
            // The registry entry for the global session names the same config as
            // xios.json: that is "main", not a second desktop.
            if let path = info.configPath, path == globalConfigPath { continue }
            infos.append(info)
        }
        checkStartWatches(&watchPaths)
        // Prune cache entries for files that no longer exist in this scan.
        lastGoodJSON = lastGoodJSON.filter { watchPaths.contains($0.key) }
        // Forget the socket timers of desktops that are gone.
        let slots = Set(infos.map(\.slot))
        socketMissingSince = socketMissingSince.filter { slots.contains($0.key) }

        infos = infos.map(applyKilledDetection)
        infos = infos.filter { info in
            if info.state == .stopped { return false }
            if let stamp = dismissed[info.slot], stamp == info.stamp, info.state.isTerminal {
                return false
            }
            return true
        }

        refreshWatches(watchPaths)
        if forcePublish || infos != lastPublished {
            lastPublished = infos
            DispatchQueue.main.async { [weak self] in self?.onChange?(infos) }
        }
    }

    /// Report (once) a watched request whose status file now says it failed.
    private func checkStartWatches(_ watchPaths: inout Set<String>) {
        let now = Date()
        for (slot, watch) in startWatches {
            if now.timeIntervalSince(watch.since) > Self.startWatchSeconds {
                startWatches[slot] = nil
                continue
            }
            watchPaths.insert(watch.statusPath)
            // Only a write made after the request speaks for it: a failure left by
            // an older attempt at the same slot must not be reported again.
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: watch.statusPath),
                  let modified = attrs[.modificationDate] as? Date,
                  modified >= watch.since.addingTimeInterval(-0.5),
                  let status = json(watch.statusPath),
                  let why = SessionParsing.startFailure(status: status, preset: watch.preset)
            else { continue }
            startWatches[slot] = nil
            let preset = watch.preset
            DispatchQueue.main.async { [weak self] in self?.onStartFailed?(slot, preset, why) }
        }
    }

    /// A desktop that says it is running while its display socket has been gone
    /// for a few seconds died without telling anyone (jetsam, crash, ssh kill).
    private func applyKilledDetection(_ info: SessionInfo) -> SessionInfo {
        var info = info
        guard info.state == .running, let ddx = info.endpoints.ddx else {
            socketMissingSince[info.slot] = nil
            return info
        }
        if FileManager.default.fileExists(atPath: ddx) {
            socketMissingSince[info.slot] = nil
            return info
        }
        let since = socketMissingSince[info.slot] ?? Date()
        socketMissingSince[info.slot] = since
        if Date().timeIntervalSince(since) >= Self.killedAfter {
            info.state = .killed
            if info.message.isEmpty { info.message = "The desktop's display socket disappeared." }
        }
        return info
    }

    private func refreshWatches(_ wanted: Set<String>) {
        for (path, watcher) in watchers where watcher.isDead || !wanted.contains(path) {
            watcher.cancel()
            watchers[path] = nil
        }
        for path in wanted where watchers[path] == nil {
            if let w = FileWatcher(path: path, queue: queue, onEvent: { [weak self] in
                self?.scheduleScan()
            }) {
                watchers[path] = w
            }
        }
    }
}

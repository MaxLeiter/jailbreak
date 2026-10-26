import Foundation
import CoreGraphics

// Host-side checks for the pure parts of the app (no UIKit, no XCTest): run with
// Tests/run.sh. Each check prints on failure; the exit code is the failure count.

var failures = 0
func check(_ cond: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
    if !cond() { failures += 1; print("FAIL line \(line): \(message)") }
}
func near(_ a: CGFloat, _ b: CGFloat, _ eps: CGFloat = 0.001) -> Bool { abs(a - b) <= eps }

// MARK: FitTransform

do {
    // 4:3 desktop on a 1620x2160 px (810x1080 pt) portrait panel at 2x: letterboxed.
    let bounds = CGRect(x: 0, y: 0, width: 810, height: 1080)
    let geo = ViewportState.Geometry(fbWidth: 2880, fbHeight: 2160, bounds: bounds,
                                     drawableSize: CGSize(width: 1620, height: 2160),
                                     contentsScale: 2)
    let vp = ViewportState()
    let fit = vp.transform(geo)!
    check(near(fit.scale, 810.0 / 2880.0), "fit scale is width-limited")
    check(near(fit.contentRect.height, 607.5), "content height")
    check(near(fit.contentRect.minY, (1080 - 607.5) / 2), "content centred vertically")
    check(fit.framebufferPoint(from: CGPoint(x: 400, y: 10)) == nil, "letterbox is outside")
    let mid = fit.framebufferPoint(from: CGPoint(x: 405, y: 540))!
    check(near(mid.x, 1440, 2) && near(mid.y, 1080, 2), "centre maps to the framebuffer centre")
    // inverse mapping round trip
    let r = fit.viewRect(fromFramebuffer: CGRect(x: 1440, y: 1080, width: 0, height: 0))
    check(near(r.minX, 405, 0.5) && near(r.minY, 540, 0.5), "viewRect inverts framebufferPoint")
    let v = fit.clipVertices()!
    check(v.count == 16 && v[3] == 0 && v[7] == 1, "unflipped UV: TL v=0, BL v=1")
    let f = fit.clipVertices(flipY: true)!
    check(f[3] == 1 && f[7] == 0 && f[0] == v[0], "flipY swaps only V")
    check(FitTransform.make(fbWidth: 0, fbHeight: 10, viewBounds: bounds,
                            drawableSize: CGSize(width: 1, height: 1), contentsScale: 1,
                            zoom: 1, pan: .zero) == nil, "empty fb has no transform")
}

// MARK: ViewportState (zoom + pan)

do {
    let bounds = CGRect(x: 0, y: 0, width: 1000, height: 750)
    let geo = ViewportState.Geometry(fbWidth: 2000, fbHeight: 1500, bounds: bounds,
                                     drawableSize: CGSize(width: 2000, height: 1500), contentsScale: 2)
    var vp = ViewportState()
    check(vp.clampedPan(CGPoint(x: 50, y: 50), zoom: 1, geo) == .zero, "no pan at zoom 1")
    let anchor = CGPoint(x: 800, y: 200)
    let before = vp.transform(geo)!.framebufferPoint(from: anchor)!
    vp.setZoom(3, around: anchor, geo)
    let after = vp.transform(geo)!.framebufferPoint(from: anchor)!
    check(near(before.x, after.x, 1.5) && near(before.y, after.y, 1.5), "zoom keeps the anchored pixel")
    vp.setZoom(99, geo)
    check(vp.zoom == ViewportState.maxZoom, "zoom clamps to max")
    vp.setZoom(0.1, geo)
    check(vp.zoom == 1 && vp.pan == .zero, "zoom clamps to min and pan follows")
    vp.setZoom(2, geo)
    check(vp.clampedPan(CGPoint(x: 99999, y: 99999), zoom: 2, geo).x <= 500.001, "pan clamps to the content edge")
    vp.reset()
    check(vp == ViewportState(), "reset is the fit state")
}

// MARK: LaneTracker (invariant 37)

do {
    var lanes = LaneTracker()
    // KDE desktop: one direct finger, touch does not replace the pointer.
    var lane = lanes.began(isGestureStart: true, newTouches: 1, allDirect: true, replacesPointer: false)
    check(!lane.forwardsTouch, "first finger is pointer lane (no wl_touch)")
    // A second finger lands: the lane must NOT flip.
    lane = lanes.began(isGestureStart: false, newTouches: 1, allDirect: true, replacesPointer: false)
    check(!lane.forwardsTouch, "second finger does not flip the lane")
    lanes.reset()
    check(lanes.lane == .none, "reset forgets the lane")
    // Two simultaneous fingers start in the touch lane and stay there.
    lane = lanes.began(isGestureStart: true, newTouches: 2, allDirect: true, replacesPointer: false)
    check(lane.forwardsTouch && !lane.consumesPointer, "simultaneous multi-touch forwards wl_touch")
    lane = lanes.began(isGestureStart: false, newTouches: 1, allDirect: true, replacesPointer: false)
    check(lane.forwardsTouch, "late finger keeps the touch lane")
    lanes.reset()
    // kde-mobile: touch replaces the pointer.
    lane = lanes.began(isGestureStart: true, newTouches: 1, allDirect: true, replacesPointer: true)
    check(lane.forwardsTouch && lane.consumesPointer, "touch-native preset consumes the pointer")
    lanes.reset()
    // Pencil: tablet records plus the pointer fallback.
    lane = lanes.began(isGestureStart: true, newTouches: 1, allDirect: false, replacesPointer: false)
    check(lane.forwardsTouch && !lane.consumesPointer, "pencil forwards and keeps the pointer press")
}

// MARK: models + parsing

do {
    check(SessionState(launcher: "up") == .running, "up -> running")
    check(SessionState(launcher: "compositor-only") == .running, "compositor-only -> running")
    check(SessionState(launcher: "waiting") == .starting && SessionState(launcher: "relaunching") == .starting,
          "waiting/relaunching -> starting")
    check(SessionState(launcher: "error") == .failed, "error -> failed")
    check(SessionState(launcher: "nonsense") == .unknown, "unknown word")

    let cfg: [String: Any] = [
        "width": 2880, "height": 2160, "ddx": "iosurface", "socket": "/t/ddx.sock",
        "input_socket": "/t/in.sock", "clipboard_socket": "/t/clip.sock", "upscale": "auto",
    ]
    let defaults = SessionParsing.Defaults(sysint: "/t/xios-sysint.sock", a11y: "/t/xios-a11y.sock")
    let main = SessionParsing.main(config: cfg, status: ["preset": "kde", "state": "up", "message": "",
                                                         "requested_logical": "1440x1080", "requested_dpi": 176],
                                   configPath: "/t/xios.json", defaults: defaults)!
    check(main.isLegacyMain && main.slot == "main" && main.ioscdSlot == nil, "legacy main carries no slot")
    check(main.state == .running && main.preset == "kde", "main state + preset")
    check(main.endpoints.configurationError == nil, "complete config has no error")
    check(main.endpoints.sysint == "/t/xios-sysint.sock", "falls back to the global sysint socket")
    check(main.requestedProfile == DisplayProfile(name: "Current", width: 1440, height: 1080, dpi: 176),
          "requested size is the logical size, not the framebuffer's")
    check(main.config.upscaleHint == "auto", "upscale hint")
    check(SessionParsing.main(config: nil, status: nil, configPath: "/x", defaults: defaults) == nil,
          "no files, no main")

    var noInput = cfg; noInput["input_socket"] = nil
    let broken = SessionParsing.main(config: noInput, status: nil, configPath: "/t/xios.json", defaults: defaults)!
    check(broken.endpoints.configurationError?.contains("input_socket") == true,
          "missing input_socket is a reported config error, never inferred")
    check(broken.state == .running, "a hand-started compositor with a config reads as running")

    var perSession = cfg; perSession["sysint_socket"] = "/t/kde/sysint.sock"; perSession["a11y_socket"] = "/t/kde/a11y.sock"
    let slot = SessionParsing.slot(entry: ["slot": "kde-3fa9", "preset": "kde", "state": "waiting",
                                           "message": "starting", "json": "/t/xios-kde-3fa9.json", "at": "T1"],
                                   fallbackName: "x", config: perSession, defaults: defaults)!
    check(slot.slot == "kde-3fa9" && slot.ioscdSlot == "kde-3fa9" && !slot.isLegacyMain, "slot session")
    check(slot.state == .starting, "waiting -> starting")
    check(slot.endpoints.sysint == "/t/kde/sysint.sock" && slot.endpoints.a11y == "/t/kde/a11y.sock",
          "per-session helper sockets win over the globals")
    check(slot.configPath == "/t/xios-kde-3fa9.json", "config path from the entry")
    let bare = SessionParsing.slot(entry: ["preset": "gnome", "state": "up"], fallbackName: "gnome-1",
                                   config: nil, defaults: defaults)!
    check(bare.slot == "gnome-1" && bare.endpoints.ddx == nil, "slot name falls back to the file name")

    // touch policy
    check(SessionConfig(["touch_replaces_pointer": true]).touchReplacesPointer == true, "explicit policy")
    check(SessionConfig(["touch_pointer_policy": "additive"]).touchReplacesPointer == false, "additive policy")
    check(SessionConfig([:]).touchReplacesPointer == nil, "no policy")

    // slot naming
    var n: UInt32 = 0
    let taken: Set<String> = ["kde-0000", "kde-0001"]
    let name = DesktopCatalog.newSlot(for: "kde", taken: taken, random: { defer { n += 1 }; return n })
    check(name == "kde-0002", "slot name skips taken suffixes (got \(name))")
    check(DesktopCatalog.newSlot(for: "Plasma Mobile!", taken: [], random: { 0xabcd }) == "plasma-mobile--abcd",
          "slot names are filename safe")
}

// MARK: ioscd protocol

do {
    check(IOSCDProtocol.sessionLine(preset: "kde", display: .landscape, slot: "kde-3fa9")
          == "SESSION\tkde\t\t1440\t1080\t176\tkde-3fa9\n", "desktop start line")
    check(IOSCDProtocol.sessionLine(preset: "stop", slot: "kde-3fa9") == "SESSION\tstop\t\t\t\t\tkde-3fa9\n",
          "stop carries the slot and no size")
    check(IOSCDProtocol.sessionLine(preset: "stop") == "SESSION\tstop\t\t\t\t\t\n", "unqualified stop")
    check(IOSCDProtocol.sessionLine(preset: "app", app: "org.kde.kate", display: .landscape, slot: "s")
          == "SESSION\tapp\torg.kde.kate\t\t\t\ts\n", "app never carries a size")
    check(IOSCDProtocol.SessionReply(.success("SESSION_STARTED\n")) == .started, "started")
    check(IOSCDProtocol.SessionReply(.success("SESSION_ACTIVE\n")) == .started, "active")
    check(IOSCDProtocol.SessionReply(.success("ERR nope\n")) == .failed("ERR nope"), "error text")
    check(IOSCDProtocol.SessionReply(.failure(.timedOut)) == .failed("ioscd timed out"), "timeout")
    check(IOSCDProtocol.SessionReply(.success(" \n")) == .failed("ioscd sent no reply"), "blank reply")
    // Issue #11: a missing daemon must not read as a slow one.
    check(IOSCDProtocol.Failure(connectErrno: ENOENT) == .notRunning, "no socket = not running")
    check(IOSCDProtocol.Failure(connectErrno: ECONNREFUSED) == .notRunning, "stale socket = not running")
    check(IOSCDProtocol.Failure(connectErrno: EACCES) == .unreachable(EACCES), "other errno kept")
    check(IOSCDProtocol.SessionReply(.failure(.notRunning))
          == .failed("ioscd is not running (is xios-launcher-tools installed?)"), "not running text")
    let list = IOSCDProtocol.parseAppsList([
        "b.app\tBeta\tbeta --x\ticon\t/var/jb/Applications/b.app\tenabled",
        "a.app\tAlpha\talpha\ticon\t/var/jb/Applications/a.app\tdisabled",
        "APPS_END\t0",
    ])
    check(list.apps.map(\.name) == ["Alpha", "Beta"] && list.apps[0].enabled == false && list.error == nil,
          "apps list sorted, disabled flag parsed")
    check(IOSCDProtocol.parseAppsList(["ERR no launcher"]).error == "ERR no launcher", "ERR line")
    check(IOSCDProtocol.isValidDesktopFileID("org.gnome.Calculator"), "valid id")
    check(!IOSCDProtocol.isValidDesktopFileID("a/b") && !IOSCDProtocol.isValidDesktopFileID("..x")
          && !IOSCDProtocol.isValidDesktopFileID("-x") && !IOSCDProtocol.isValidDesktopFileID("a\tb")
          && !IOSCDProtocol.isValidDesktopFileID(""), "invalid ids refused")
}

// MARK: start failures (preflight refusals land in a status file, not on the socket)

do {
    // Slot start, nothing running in the slot: an error status for the preset.
    let refused: [String: Any] = ["preset": "gnome", "state": "error",
                                  "message": "GNOME is not installed: install xios-gnome", "slot": "gnome-1a2b"]
    check(SessionParsing.startFailure(status: refused, preset: "gnome")
          == "GNOME is not installed: install xios-gnome", "refusal text is passed through verbatim")
    check(SessionParsing.startFailure(status: refused, preset: "kde") == nil, "another preset's error is not ours")
    // A desktop keeps running: the refusal rides along as request/request_state.
    let beside: [String: Any] = ["preset": "kde", "state": "up", "request": "gnome", "request_state": "error",
                                 "message": "GNOME is not installed: install xios-gnome"]
    check(SessionParsing.startFailure(status: beside, preset: "gnome")
          == "GNOME is not installed: install xios-gnome", "refusal beside a running desktop")
    check(SessionParsing.startFailure(status: beside, preset: "kde") == nil, "the running desktop did not fail")
    check(SessionParsing.startFailure(status: ["preset": "kde", "state": "starting"], preset: "kde") == nil,
          "a start in progress is not a failure")
    // Resize sends the `resize` verb with the slot (a running slot refuses its own preset).
    check(IOSCDProtocol.sessionLine(preset: "resize", display: .portrait, slot: "kde-3fa9")
          == "SESSION\tresize\t\t1080\t1440\t176\tkde-3fa9\n", "resize carries the size and the slot")
}

// MARK: installed presets

do {
    check(PresetProbe.parseIOSCD(["iosc", "kde", "kde-desktop", "PRESETS_END\t0"]) == ["iosc", "kde", "kde-desktop"],
          "PRESETS reply")
    check(PresetProbe.parseIOSCD(["xios-session: some warning", "gnome", "APPS_END\t0"]) == ["gnome"],
          "stderr noise is ignored; run_and_stream's APPS_END ends it too")
    check(PresetProbe.parseIOSCD(["ERR malformed"]) == nil, "an ioscd without PRESETS falls back")
    check(PresetProbe.parseIOSCD(["iosc", "APPS_END\t1"]) == nil, "a failed run falls back")
    check(PresetProbe.parseIOSCD(["iosc"]) == nil, "no end marker falls back")
    check(PresetProbe.parseIOSCD(["PRESETS_END\t0"]) == nil, "an empty list is not believed")
    check(PresetProbe.parseIOSCD(["iosc", "PRESETS_END\t3"]) == nil, "PRESETS_END with a failed status falls back")
    check(PresetProbe.parseIOSCD(["ERR xios-session is not installed"]) == nil, "an ERR reply falls back")
    check(PresetProbe.requestLine == "PRESETS\n", "the request is the bare verb")
    check(PresetAvailability.unknown.isInstalled("gnome"), "unknown offers everything")
    check(!PresetAvailability(installed: ["iosc"], source: .ioscd).isInstalled("gnome"), "known list filters")
    check(PresetProbe.installHint(for: "gnome") == "Install xios-gnome"
          && PresetProbe.installHint(for: "kde") == "Install xios-kde", "install hints name the package")

    // The file probe against xios-session's own xs_preset_check, on fake roots.
    let root = NSTemporaryDirectory() + "xios-presets-\(getpid())"
    let fm = FileManager.default
    func reset() {
        try? fm.removeItem(atPath: root)
        try! fm.createDirectory(atPath: root + "/tmp", withIntermediateDirectories: true)
    }
    func touch(_ rel: String, exec: Bool) {
        let path = root + "/" + rel
        try! fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                withIntermediateDirectories: true)
        fm.createFile(atPath: path, contents: Data("#!/bin/sh\n".utf8),
                      attributes: [.posixPermissions: exec ? 0o755 : 0o644])
    }
    func shellPresets() -> Set<String>? {
        guard let lib = ProcessInfo.processInfo.environment["XIOS_TEST_SESSION_LIB"],
              fm.fileExists(atPath: lib) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", ". \"$LIB\" && xs_installed_presets"]
        p.environment = [
            "LIB": lib, "XS_JB": root, "XS_TMP": root + "/tmp",
            "PATH": ["/usr/local/bin", "/usr/bin", "/usr/sbin", "/bin", "/sbin"].map { root + $0 }
                .joined(separator: ":") + ":/usr/bin:/bin",
        ]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return Set(text.split(separator: "\n").map(String.init))
    }
    let fixtures: [(name: String, files: [(String, Bool)])] = [
        ("core only", [("usr/local/bin/iosc", true), ("libexec/xios-session/run-shell.sh", false)]),
        ("core + kde", [("usr/local/bin/iosc", true), ("libexec/xios-session/run-shell.sh", false),
                        ("libexec/xios-session/run-kde-plasma.sh", false),
                        ("Applications/KDE/kwin_wayland.app/kwin_wayland", true),
                        ("Applications/KDE/plasmashell.app/plasmashell", true),
                        ("usr/libexec/xios-setsid", true)]),
        ("kde without setsid", [("usr/local/bin/iosc", true), ("usr/bin/run-kde-plasma.sh", false),
                                ("Applications/KDE/kwin_wayland.app/kwin_wayland", true),
                                ("Applications/KDE/plasmashell.app/plasmashell", true)]),
        ("kde, plasmashell not executable", [("usr/local/bin/iosc", true), ("usr/bin/run-kde-plasma.sh", false),
                                             ("Applications/KDE/kwin_wayland.app/kwin_wayland", true),
                                             ("Applications/KDE/plasmashell.app/plasmashell", false),
                                             ("usr/libexec/xios-setsid", true)]),
        ("core + gnome", [("usr/local/bin/iosc", true), ("usr/local/bin/run-shell.sh", false),
                          ("libexec/xios-session/launch-gnome-session.sh", false),
                          ("usr/bin/gnome-shell", true), ("usr/bin/gnome-session", true),
                          ("usr/libexec/xios-setsid", true)]),
        ("gnome-session only on PATH", [("usr/local/bin/iosc", true), ("usr/bin/launch-gnome-session.sh", false),
                                        ("usr/bin/gnome-shell", true), ("bin/gnome-session", true),
                                        ("usr/libexec/xios-setsid", true)]),
        ("gnome without its script", [("usr/local/bin/iosc", true), ("usr/bin/gnome-shell", true),
                                      ("usr/bin/gnome-session", true), ("usr/libexec/xios-setsid", true)]),
        ("mutter", [("usr/local/bin/iosc", true), ("usr/bin/run-mutter.sh", false), ("usr/bin/mutter", true)]),
    ]
    var compared = 0
    for fixture in fixtures {
        reset()
        for (rel, exec) in fixture.files { touch(rel, exec: exec) }
        let swift = PresetProbe.installed(jb: root)
        guard let shell = shellPresets() else { break }
        compared += 1
        check(swift == shell, "\(fixture.name): app probe \(swift.map { $0.sorted() } ?? []) "
              + "!= xs_installed_presets \(shell.sorted())")
    }
    check(compared == fixtures.count, "xs_preset_check parity ran (XIOS_TEST_SESSION_LIB set by run.sh)")
    reset()
    check(PresetProbe.installed(jb: root) == nil, "an invisible iosc means the probe cannot see: unknown")
    try? fm.removeItem(atPath: root)
}

// MARK: registry (real files, real kqueue)

do {
    let dir = NSTemporaryDirectory() + "xios-registry-\(getpid())"
    try! FileManager.default.createDirectory(atPath: dir + "/xios-displays.d", withIntermediateDirectories: true)
    setenv("XIOS_RUNTIME_TMP", dir, 1)
    func write(_ name: String, _ text: String) {
        try! text.write(toFile: "\(dir)/\(name)", atomically: false, encoding: .utf8)
    }
    let ddx = "\(dir)/ddx.sock"
    FileManager.default.createFile(atPath: ddx, contents: Data())
    write("xios.json", """
    {"width":2880,"height":2160,"ddx":"iosurface","socket":"\(ddx)","input_socket":"\(dir)/in","clipboard_socket":"\(dir)/clip"}
    """)
    write("xios-session-status.json", #"{"preset":"iosc","state":"up","message":"","at":"T0"}"#)
    write("xios-gnome-1.json", """
    {"width":1920,"height":1080,"ddx":"iosurface","socket":"\(dir)/gnome.sock","input_socket":"\(dir)/gin","clipboard_socket":"\(dir)/gclip"}
    """)
    write("xios-displays.d/gnome-1.json", """
    {"slot":"gnome-1","preset":"gnome","state":"up","message":"","at":"T1","json":"\(dir)/xios-gnome-1.json"}
    """)
    // A second entry that merely names the global config is "main", not a desktop.
    write("xios-displays.d/dup.json", """
    {"slot":"dup","preset":"iosc","state":"up","json":"\(dir)/xios.json"}
    """)

    let registry = SessionRegistry()
    let lock = NSCondition()
    var latest: [SessionInfo] = []
    var deliveries = 0
    registry.onChange = { infos in
        lock.lock(); latest = infos; deliveries += 1; lock.broadcast(); lock.unlock()
    }
    func wait(_ what: String, timeout: TimeInterval = 4, until: ([SessionInfo]) -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        lock.lock()
        while !until(latest) && lock.wait(until: deadline) {}
        let ok = until(latest)
        lock.unlock()
        check(ok, "registry: \(what)")
    }
    // Deliveries land on the main queue: spin the run loop from a worker.
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        registry.start()
        wait("main + gnome slot discovered") { $0.map(\.slot) == ["main", "gnome-1"] }
        lock.lock()
        let main = latest.first { $0.slot == "main" }
        let gnome = latest.first { $0.slot == "gnome-1" }
        lock.unlock()
        check(main?.preset == "iosc" && main?.state == .running, "main from global files")
        check(gnome?.endpoints.input == "\(dir)/gin", "slot endpoints come from its own config")

        // kqueue: change a state file and expect a publish well before the 2 s poll.
        let started = Date()
        write("xios-displays.d/gnome-1.json", """
        {"slot":"gnome-1","preset":"gnome","state":"error","message":"shell crashed","at":"T2","json":"\(dir)/xios-gnome-1.json"}
        """)
        wait("state change seen", timeout: 1.5) { $0.first { $0.slot == "gnome-1" }?.state == .failed }
        check(Date().timeIntervalSince(started) < 1.5, "state change arrives via kqueue, not the slow poll")

        // A torn write is never "the session is gone".
        write("xios-displays.d/gnome-1.json", #"{"slot":"gnome-1","pre"#)
        Thread.sleep(forTimeInterval: 0.5)
        lock.lock(); let kept = latest.contains { $0.slot == "gnome-1" }; lock.unlock()
        check(kept, "a torn read keeps the last good session")
        write("xios-displays.d/gnome-1.json", """
        {"slot":"gnome-1","preset":"gnome","state":"up","message":"","at":"T3","json":"\(dir)/xios-gnome-1.json"}
        """)
        wait("recovered after the torn write", timeout: 2) { $0.first { $0.slot == "gnome-1" }?.state == .running }

        // A running desktop whose display socket vanished is `killed` after a few seconds.
        try? FileManager.default.removeItem(atPath: ddx)
        wait("killed detection", timeout: SessionRegistry.killedAfter + 3) {
            $0.first { $0.slot == "main" }?.state == .killed
        }

        // A clean stop (entry deleted) removes the card; state stopped hides it too.
        try? FileManager.default.removeItem(atPath: "\(dir)/xios-displays.d/gnome-1.json")
        wait("removed slot disappears", timeout: 2) { $0.map(\.slot) == ["main"] }

        // A slot start xios-session refused: no registry entry, only the slot's
        // status file. An error left by an earlier attempt is not reported again.
        let slotStatus = "\(dir)/xios-session-kde-77aa.json"
        write("xios-session-kde-77aa.json", #"{"preset":"kde","state":"error","message":"old failure"}"#)
        let old = Date().addingTimeInterval(-30)
        try? FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: slotStatus)
        let failures = NSCondition()
        var reported: [(String, String, String)] = []
        registry.onStartFailed = { slot, preset, why in
            failures.lock(); reported.append((slot, preset, why)); failures.broadcast(); failures.unlock()
        }
        registry.watchStart(slot: "kde-77aa", statusPath: slotStatus, preset: "kde")
        Thread.sleep(forTimeInterval: 0.8)
        failures.lock(); let early = reported.count; failures.unlock()
        check(early == 0, "a stale failure from an earlier attempt is ignored")
        write("xios-session-kde-77aa.json",
              #"{"preset":"kde","state":"error","message":"KDE Plasma is not installed: install xios-kde"}"#)
        let deadline = Date().addingTimeInterval(4)
        failures.lock()
        while reported.isEmpty && failures.wait(until: deadline) {}
        let got = reported
        failures.unlock()
        check(got.count == 1 && got.first?.0 == "kde-77aa" && got.first?.1 == "kde"
              && got.first?.2 == "KDE Plasma is not installed: install xios-kde",
              "refused slot start reported once, verbatim (got \(got))")
        registry.stop()
        done.signal()
    }
    // Pump the main queue so onChange fires.
    while done.wait(timeout: .now() + 0.02) == .timedOut {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
    try? FileManager.default.removeItem(atPath: dir)
}

print(failures == 0 ? "all checks passed" : "\(failures) check(s) failed")
exit(Int32(failures))

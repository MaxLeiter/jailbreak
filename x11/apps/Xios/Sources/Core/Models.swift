import Foundation

// Pure value types shared by the registry, the session layer and the UI. No
// UIKit here: Tests/ compiles this file on the host.

// MARK: session state

/// Lifecycle of one desktop as the launcher UI shows it. The launcher scripts
/// speak their own vocabulary (`up`, `waiting`, `relaunching`, ...); `init(launcher:)`
/// is the one place that is translated.
enum SessionState: String, Equatable {
    case starting, running, stopping, stopped, failed, killed, unknown

    init(launcher raw: String) {
        switch raw.lowercased() {
        case "up", "running", "hidden", "compositor-only":
            self = .running
        case "starting", "waiting", "relaunching":
            self = .starting
        case "stopping":
            self = .stopping
        case "stopped":
            self = .stopped
        case "error", "failed":
            self = .failed
        case "killed":
            self = .killed
        default:
            self = .unknown
        }
    }

    /// A state a viewer should wait out rather than act on.
    var isTransient: Bool { self == .starting || self == .stopping }
    /// Nothing is serving this desktop and it will not come back by itself.
    var isTerminal: Bool { self == .stopped || self == .failed || self == .killed }

    var title: String {
        switch self {
        case .starting: return "Starting"
        case .running: return "Running"
        case .stopping: return "Stopping"
        case .stopped: return "Stopped"
        case .failed: return "Failed"
        case .killed: return "Stopped unexpectedly"
        case .unknown: return "Unknown"
        }
    }
}

// MARK: endpoints and config

/// What one session's xios-<slot>.json (or the global xios.json) advertises.
/// Endpoints come only from here, never inferred from another path (invariant 47).
struct SessionEndpoints: Equatable {
    var isIOSurface = false
    var ddx: String?
    var input: String?
    var clipboard: String?
    var sysint: String?
    var a11y: String?

    /// Why this session cannot be connected to yet, in words for the card.
    /// nil when every endpoint a live desktop needs is present.
    var configurationError: String? {
        guard isIOSurface else { return "waiting for the compositor's display config" }
        guard ddx != nil else { return "config is missing the display socket" }
        guard input != nil else {
            return "config is missing input_socket; restart/update the compositor"
        }
        guard clipboard != nil else {
            return "config is missing clipboard_socket; restart/update the compositor"
        }
        return nil
    }
}

/// The parsed fields of an xios json config.
struct SessionConfig: Equatable {
    var endpoints = SessionEndpoints()
    var width: Int?
    var height: Int?
    /// Present-side MetalFX hint forwarded from the compositor's IOSC_UPSCALE.
    var upscaleHint: String?
    var touchReplacesPointer: Bool?
    var display: String?

    /// `defaultSysint` / `defaultA11y` are the global helper sockets, used only
    /// when this config does not name its own (the per-slot helpers arrive with
    /// the M0 coexistence change).
    init(_ obj: [String: Any], defaultSysint: String? = nil, defaultA11y: String? = nil) {
        func string(_ key: String) -> String? {
            (obj[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        func positive(_ key: String) -> Int? {
            (obj[key] as? Int).flatMap { $0 > 0 ? $0 : nil }
        }
        endpoints.isIOSurface = (obj["ddx"] as? String) == "iosurface"
        endpoints.ddx = string("socket")
        endpoints.input = string("input_socket")
        endpoints.clipboard = string("clipboard_socket")
        endpoints.sysint = string("sysint_socket") ?? defaultSysint
        endpoints.a11y = string("a11y_socket") ?? defaultA11y
        width = positive("width")
        height = positive("height")
        upscaleHint = string("upscale")
        display = string("display")
        touchReplacesPointer = Self.touchPointerPolicy(obj)
    }

    init() {}

    static func touchPointerPolicy(_ obj: [String: Any]) -> Bool? {
        if let value = obj["touch_replaces_pointer"] as? Bool { return value }
        guard let raw = obj["touch_pointer_policy"] as? String else { return nil }
        switch raw.lowercased() {
        case "touch", "touch-only", "replace-pointer", "touch-replaces-pointer":
            return true
        case "additive", "pointer-fallback", "pointer":
            return false
        default:
            return nil
        }
    }
}

// MARK: session

/// One desktop as the launcher and the connection layer see it.
struct SessionInfo: Equatable {
    /// The legacy global session is the slot named `main`.
    static let mainSlot = "main"

    var slot: String
    /// True for the session described by the global xios.json: ioscd requests
    /// for it carry no slot, and "stop" means every desktop (invariant 58).
    var isLegacyMain: Bool
    var preset: String
    var state: SessionState
    /// The launcher's own state word, kept for diagnostics and for `compositor-only`.
    var rawState: String
    var message: String
    var configPath: String?
    var config = SessionConfig()
    /// Opaque change marker (the registry entry's `at`), used to remember a dismissal.
    var stamp: String = ""
    /// The logical size the desktop was last asked for (WxH) and its DPI, as the
    /// launcher recorded them. The config's own width/height are physical
    /// framebuffer pixels, which is a different number.
    var requestedLogical: String?
    var requestedDPI: Int?

    /// The size to restart this desktop at, when the launcher recorded one.
    var requestedProfile: DisplayProfile? {
        guard let raw = requestedLogical else { return nil }
        let parts = raw.split(separator: "x").compactMap { Int($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return nil }
        return DisplayProfile(name: "Current", width: parts[0], height: parts[1],
                              dpi: requestedDPI ?? 0)
    }

    var endpoints: SessionEndpoints { config.endpoints }

    /// What to put in the SESSION line's slot field.
    var ioscdSlot: String? { isLegacyMain ? nil : slot }

    var size: (width: Int, height: Int)? {
        guard let w = config.width, let h = config.height else { return nil }
        return (w, h)
    }

    var title: String {
        if isLegacyMain { return "Main" }
        return DesktopCatalog.label(for: preset)
    }

    var subtitle: String {
        isLegacyMain ? DesktopCatalog.label(for: preset) : slot
    }

    static func == (a: SessionInfo, b: SessionInfo) -> Bool {
        a.slot == b.slot && a.isLegacyMain == b.isLegacyMain && a.preset == b.preset &&
            a.state == b.state && a.rawState == b.rawState && a.message == b.message &&
            a.configPath == b.configPath && a.config == b.config && a.stamp == b.stamp &&
            a.requestedLogical == b.requestedLogical && a.requestedDPI == b.requestedDPI
    }
}

// MARK: catalog

struct DesktopPreset: Equatable {
    let preset: String
    let title: String
    let detail: String
    let symbol: String
    /// Measured footprint, or nil when nobody has measured it yet.
    let memory: String?
}

enum DesktopCatalog {
    /// The three desktops the New Desktop card offers.
    static let primary: [DesktopPreset] = [
        DesktopPreset(preset: "kde", title: "KDE Plasma",
                      detail: "KWin and the Plasma desktop shell",
                      symbol: "sparkles.rectangle.stack", memory: "about 600-650 MB"),
        DesktopPreset(preset: "gnome", title: "GNOME",
                      detail: "GNOME Shell session",
                      symbol: "circle.grid.cross", memory: nil),
        DesktopPreset(preset: "iosc", title: "Shell",
                      detail: "iosc shell, dock and wallpaper",
                      symbol: "rectangle.on.rectangle", memory: "about 190 MB"),
    ]

    /// Reachable only from Settings > Developer.
    static let developer: [DesktopPreset] = [
        DesktopPreset(preset: "mutter", title: "Mutter",
                      detail: "Raw compositor, no shell",
                      symbol: "display", memory: nil),
        DesktopPreset(preset: "kde-nano", title: "Plasma Nano",
                      detail: "KWin and the nano shell",
                      symbol: "rectangle.grid.1x2", memory: nil),
        DesktopPreset(preset: "kde-mobile", title: "Plasma Mobile",
                      detail: "KWin and the mobile shell",
                      symbol: "ipad", memory: nil),
    ]

    static var all: [DesktopPreset] { primary + developer }

    static func label(for preset: String) -> String {
        if let known = all.first(where: { $0.preset == preset }) { return known.title }
        return preset.isEmpty ? "Desktop" : preset
    }

    /// Pick a slot name for a brand new desktop: the preset plus a short random
    /// suffix, never one already in `taken`.
    static func newSlot(for preset: String, taken: Set<String>,
                        random: () -> UInt32 = { arc4random() }) -> String {
        let base = String(preset.lowercased().map {
            $0.isLetter || $0.isNumber ? $0 : "-"
        })
        for _ in 0..<64 {
            let suffix = String(format: "%04x", random() & 0xffff)
            let candidate = "\(base)-\(suffix)"
            if !taken.contains(candidate) { return candidate }
        }
        return "\(base)-\(String(format: "%08x", random()))"
    }
}

struct DisplayProfile: Equatable {
    let name: String
    let width: Int
    let height: Int
    let dpi: Int

    var detail: String { "\(width)\u{00d7}\(height)" }

    static let landscape = DisplayProfile(name: "Landscape", width: 1440, height: 1080, dpi: 176)
    static let portrait = DisplayProfile(name: "Portrait", width: 1080, height: 1440, dpi: 176)
    static let compact = DisplayProfile(name: "Compact", width: 810, height: 1080, dpi: 132)
    static let standard: [DisplayProfile] = [.landscape, .portrait, .compact]
}

// MARK: ioscd app catalog

/// One row of ioscd's APPS_LIST. That is the only app catalog the app has.
struct LauncherApp: Equatable {
    let id: String
    let name: String
    let exec: String
    let icon: String
    let bundlePath: String
    let enabled: Bool

    static func parse(line: String) -> LauncherApp? {
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard fields.count >= 6 else { return nil }
        return LauncherApp(
            id: String(fields[0]),
            name: String(fields[1]),
            exec: String(fields[2]),
            icon: String(fields[3]),
            bundlePath: String(fields[4]),
            enabled: String(fields[5]).lowercased() != "disabled")
    }
}

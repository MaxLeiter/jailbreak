import Darwin
import Foundation

/// Which desktop presets are installed, so the launcher offers only the flavors
/// that can start. Pure apart from the file probe, which takes its filesystem as
/// closures so Tests/ can run it against a fake root.
///
/// The authority is `xios-session presets` (its `xs_preset_check`). The app runs
/// as `mobile` and cannot run xios-session, so the answer comes from one of:
///   1. ioscd's PRESETS verb (xios-launcher-tools 0.1.14), which runs
///      `xios-session presets` as root. One copy of the knowledge, so this is the
///      preferred source. An older ioscd answers `ERR malformed`; no ioscd at all
///      is a connect failure. Both fall through to 2.
///   2. `PresetProbe.installed`, a mirror of `xs_preset_check` over the same
///      paths. Tests/ runs the real shell function against fake roots and fails
///      when the two disagree, so the copy cannot drift silently.
///   3. Neither usable: everything is offered, and xios-session's own preflight
///      refusal is shown word for word when a missing flavor is picked.
struct PresetAvailability: Equatable {
    enum Source: String { case ioscd, files, unknown }

    /// nil = not known: offer everything.
    let installed: Set<String>?
    let source: Source

    static let unknown = PresetAvailability(installed: nil, source: .unknown)

    func isInstalled(_ preset: String) -> Bool { installed?.contains(preset) ?? true }
}

enum PresetProbe {
    /// Every preset xs_preset_check knows (XS_PRESETS).
    static let allPresets = ["iosc", "mutter", "gnome", "kde", "kde-desktop", "kde-nano", "kde-mobile"]

    /// What to tell the user about a preset that is not installed. Same package
    /// names as xs_preset_check's refusal text.
    static func installHint(for preset: String) -> String {
        switch preset {
        case "iosc": return "Install xios-core"
        case "gnome": return "Install xios-gnome"
        case "kde", "kde-desktop", "kde-nano", "kde-mobile": return "Install xios-kde"
        case "mutter": return "Not installed: the mutter binary is missing"
        default: return "Not installed"
        }
    }

    // MARK: ioscd PRESETS

    /// PRESETS\n -> one preset per line, then PRESETS_END\t<exit status>\n (or
    /// ERR <msg>). APPS_END is accepted too: it is the end marker of ioscd's other
    /// streamed replies.
    static let requestLine = "PRESETS\n"

    /// nil when this ioscd cannot answer (no such verb, an error, a non-zero exit,
    /// no end marker, or an empty list): the caller falls back to the file probe.
    /// An empty list is not believed. com.max.xios depends on iosc, so a clean
    /// "nothing can start" means ioscd's environment could not see the install,
    /// the same reasoning as `installed(jb:)` below.
    static func parseIOSCD(_ lines: [String]) -> Set<String>? {
        var presets = Set<String>()
        for line in lines {
            if line.hasPrefix("ERR") { return nil }
            if line.hasPrefix("PRESETS_END") || line.hasPrefix("APPS_END") {
                let status = line.split(separator: "\t").dropFirst().first.map(String.init) ?? "0"
                return status == "0" && !presets.isEmpty ? presets : nil
            }
            // run_and_stream merges stderr: keep only lines that are preset names.
            if allPresets.contains(line) { presets.insert(line) }
        }
        return nil
    }

    // MARK: file probe (mirror of xs_preset_check)

    /// The filesystem the probe looks at. `executable` is `test -x`, `readable` is
    /// `test -r`.
    struct FileSystem {
        var readable: (String) -> Bool
        var executable: (String) -> Bool

        static let live = FileSystem(
            readable: { access($0, R_OK) == 0 },
            executable: { access($0, X_OK) == 0 })
    }

    /// The installed presets under jailbreak root `jb` ("" for rootful, "/var/jb"
    /// on this device), in xs_preset_check's order, or nil when the probe cannot
    /// see the filesystem at all. com.max.xios depends on iosc, so an invisible
    /// iosc binary means a sandbox or a wrong root, not a missing flavor; hiding
    /// every desktop on that evidence would be worse than offering them all.
    static func installed(jb: String, fs: FileSystem = .live) -> Set<String>? {
        let prefix = jb + "/usr"
        guard fs.executable(prefix + "/local/bin/iosc") else { return nil }
        return Set(allPresets.filter { check($0, jb: jb, fs: fs) })
    }

    /// One preset, the same tests in the same order as xs_preset_check with no
    /// environment overrides (FrontBoard gives the app none).
    static func check(_ preset: String, jb: String, fs: FileSystem) -> Bool {
        let prefix = jb + "/usr"
        let kdeApps = jb + "/Applications/KDE"
        // ioscd's PATH for xios-session (set_rootless_path with local dirs).
        let path = [prefix + "/local/bin", prefix + "/bin", prefix + "/sbin",
                    jb + "/bin", jb + "/sbin", "/usr/bin", "/bin"]
        func commandV(_ name: String) -> String? {
            path.map { $0 + "/" + name }.first(where: fs.executable)
        }
        // xs_find_bringup: the same three places in either order.
        func bringup(_ name: String) -> Bool {
            [prefix + "/local/bin/" + name, jb + "/usr/bin/" + name,
             jb + "/libexec/xios-session/" + name].contains(where: fs.readable)
        }
        let script: String
        var bins: [String]
        var needsSetsid = false
        switch preset {
        case "iosc":
            script = "run-shell.sh"
            bins = [prefix + "/local/bin/iosc"]
        case "mutter":
            script = "run-mutter.sh"
            bins = [prefix + "/bin/mutter"]
        case "gnome":
            script = "launch-gnome-session.sh"
            bins = [prefix + "/bin/gnome-shell",
                    commandV("gnome-session") ?? prefix + "/bin/gnome-session",
                    prefix + "/libexec/xios-setsid"]
        case "kde", "kde-desktop", "kde-nano", "kde-mobile":
            script = "run-kde-plasma.sh"
            bins = [prefix + "/local/bin/iosc",
                    kdeApps + "/kwin_wayland.app/kwin_wayland",
                    kdeApps + "/plasmashell.app/plasmashell"]
            needsSetsid = true
        default:
            return false
        }
        guard bringup(script), bins.allSatisfy(fs.executable) else { return false }
        if needsSetsid, !fs.executable(prefix + "/libexec/xios-setsid"), commandV("setsid") == nil {
            return false
        }
        return true
    }
}

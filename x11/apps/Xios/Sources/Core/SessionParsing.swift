import Foundation

/// Turns the launcher's JSON files into SessionInfo. Pure: no file access, so a
/// torn or missing file is the caller's problem and Tests/ can feed it fixtures.
enum SessionParsing {
    /// Global helper sockets, used when a session's own config does not name
    /// per-session ones.
    struct Defaults {
        var sysint: String?
        var a11y: String?
    }

    /// The legacy global session: xios.json plus xios-session-status.json.
    /// nil when neither file exists (no legacy desktop was ever started).
    static func main(config: [String: Any]?, status: [String: Any]?,
                     configPath: String, defaults: Defaults) -> SessionInfo? {
        guard config != nil || status != nil else { return nil }
        let cfg = config.map {
            SessionConfig($0, defaultSysint: defaults.sysint, defaultA11y: defaults.a11y)
        } ?? SessionConfig()
        let preset = (status?["preset"] as? String) ?? ""
        // A config with no launcher status is a compositor someone started by hand.
        let raw = (status?["state"] as? String) ?? (cfg.endpoints.isIOSurface ? "up" : "starting")
        return SessionInfo(
            slot: SessionInfo.mainSlot,
            isLegacyMain: true,
            preset: preset == "?" ? "" : preset,
            state: SessionState(launcher: raw),
            rawState: raw,
            message: (status?["message"] as? String) ?? "",
            configPath: config == nil ? nil : configPath,
            config: cfg,
            stamp: (status?["at"] as? String) ?? "",
            requestedLogical: status?["requested_logical"] as? String,
            requestedDPI: status?["requested_dpi"] as? Int)
    }

    /// Why a desktop start (or restart, or resize) of `preset` did not happen, read
    /// from the status file that request writes, worded exactly as xios-session
    /// wrote it. nil when the file reports no failure for that preset.
    ///
    /// ioscd answers SESSION_STARTED as soon as it has forked xios-session, so a
    /// refusal never comes back on the socket. xios-session's preflight
    /// (xs_report_preflight_failure) instead writes it to the request's status
    /// file: as `request`/`request_state` beside a desktop that keeps running, or
    /// as an `error` status when nothing was running. A slot refusal touches only
    /// that slot's xios-session-<slot>.json, never xios-displays.d, so without
    /// this the launcher never hears of it.
    static func startFailure(status: [String: Any], preset: String) -> String? {
        let message = (status["message"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        if (status["request_state"] as? String) == "error", (status["request"] as? String) == preset {
            return message ?? "\(DesktopCatalog.label(for: preset)) could not start"
        }
        if (status["state"] as? String) == "error", (status["preset"] as? String) == preset {
            return message ?? "\(DesktopCatalog.label(for: preset)) could not start"
        }
        return nil
    }

    /// One xios-displays.d entry plus the config it points at.
    static func slot(entry: [String: Any], fallbackName: String,
                     config: [String: Any]?, defaults: Defaults) -> SessionInfo? {
        let slot = (entry["slot"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fallbackName
        guard !slot.isEmpty else { return nil }
        func entryString(_ key: String) -> String? {
            (entry[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        let cfg = config.map {
            SessionConfig($0,
                          defaultSysint: entryString("sysint_socket") ?? defaults.sysint,
                          defaultA11y: entryString("a11y_socket") ?? defaults.a11y)
        } ?? SessionConfig()
        let raw = (entry["state"] as? String) ?? "unknown"
        return SessionInfo(
            slot: slot,
            isLegacyMain: false,
            preset: (entry["preset"] as? String) ?? "",
            state: SessionState(launcher: raw),
            rawState: raw,
            message: (entry["message"] as? String) ?? "",
            configPath: entryString("json"),
            config: cfg,
            stamp: (entry["at"] as? String) ?? "",
            requestedLogical: entry["requested_logical"] as? String,
            requestedDPI: entry["requested_dpi"] as? Int)
    }
}

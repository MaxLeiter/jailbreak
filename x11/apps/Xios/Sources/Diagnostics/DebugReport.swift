import Foundation

/// The text behind Settings > Diagnostics: what every desktop looks like to the
/// app right now. Written to xios-debug.txt only on demand (a stale copy reads like
/// current state, so trust xios-status.txt for the live view).
enum DebugReport {
    static func make(manager: SessionManager, renderer: Renderer?) -> String {
        var lines = ["Xios Debug", "generated=\(Date())"]
        lines.append("presented=\(manager.presented?.slot ?? "(home)")")
        lines.append("renderer=\(renderer == nil ? "none" : "metal") upscale=\(renderer?.lastUpscaleStatus ?? "-")")
        for c in manager.sessions {
            let i = c.info
            let e = i.endpoints
            lines.append("")
            lines.append("[\(c.slot)] preset=\(i.preset) state=\(i.rawState)->\(i.state.rawValue) phase=\(c.phase)")
            if !i.message.isEmpty { lines.append("  message=\(i.message)") }
            lines.append("  config=\(i.configPath ?? "(none)")")
            lines.append("  ddx=\(e.ddx ?? "(none)") iosurface=\(e.isIOSurface)")
            lines.append("  input=\(e.input ?? "(none)") clipboard=\(e.clipboard ?? "(none)")")
            lines.append("  sysint=\(e.sysint ?? "(none)") a11y=\(e.a11y ?? "(none)")")
            if let err = e.configurationError { lines.append("  configuration-error=\(err)") }
            if let s = c.surface {
                lines.append("  surface=\(s.fbWidth)x\(s.fbHeight) compositor=\(s.compositorID)")
            }
            lines.append("  input-open=\(c.openInput != nil)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// One line per desktop, for xios-app-sessions.txt.
    static func sessionsSummary(manager: SessionManager) -> String {
        manager.sessions.map { c in
            "\(c.slot) preset=\(c.info.preset) state=\(c.info.rawState) phase=\(c.phase)"
                + (c === manager.presented ? " presented" : "")
        }.joined(separator: "\n") + "\n"
    }
}

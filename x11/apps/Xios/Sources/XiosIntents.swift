import AppIntents
import Foundation

// App Intents / Shortcuts / Siri surface for the Linux desktop.
//
// WHY THESE ARE IN-PROCESS INTENTS AND NOT AN "App Intents Extension":
//
// ioscd gates destructive session switches on peer identity. peer_is_xios_app()
// (ioscd.c) resolves the connecting process with proc_pidpath and accepts it only
// if the path ends in "/Xios.app/Xios" (or comm is "Xios"). Root gets the same
// authority via the xios-session CLI; everybody else falls back to ENSURE
// semantics, which REFUSES to switch away from a healthy desktop.
//
// An App Intents Extension is a separate process at
// .../Xios.app/PlugIns/<Name>.appex/<Name>. That path does not match, so
// "Hey Siri, open the GNOME desktop" while KDE was healthy would come back
// "active session is healthy; switching needs the Xios picker or root" — the
// intent would appear to work and quietly do nothing. Compiling the intents into
// the app keeps the socket peer the app binary itself, which is precisely the
// identity ioscd already trusts to speak for the user.
//
// Everything here therefore goes through the EXISTING control paths: ioscd's
// documented socket verbs, and xios-session behind them. No new launch path, and
// no executable text ever crosses the socket — app launches are an app id that
// ioscd resolves against trusted root-owned desktop entries.

// MARK: - Desktop flavor

@available(iOS 16.0, *)
enum DesktopFlavor: String, AppEnum {
    case iosc
    case gnome
    case kde
    case mutter
    case native

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Desktop Flavor"

    static var caseDisplayRepresentations: [DesktopFlavor: DisplayRepresentation] = [
        .iosc: DisplayRepresentation(title: "iosc",
                                     subtitle: "The lightweight built-in compositor"),
        .gnome: DisplayRepresentation(title: "GNOME", subtitle: "Full GNOME Shell session"),
        .kde: DisplayRepresentation(title: "KDE Plasma", subtitle: "KWin and Plasma shell"),
        .mutter: DisplayRepresentation(title: "Mutter", subtitle: "Mutter compositor only"),
        .native: DisplayRepresentation(title: "Native",
                                       subtitle: "Each Linux app in its own iPadOS window"),
    ]

    /// The preset string `xios-session` and ioscd expect.
    var preset: String { rawValue }

    var label: String {
        switch self {
        case .iosc: return "iosc"
        case .gnome: return "GNOME"
        case .kde: return "KDE Plasma"
        case .mutter: return "Mutter"
        case .native: return "the native flavor"
        }
    }
}

// MARK: - Open Desktop

@available(iOS 16.0, *)
struct OpenDesktopIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Desktop"
    static var description = IntentDescription(
        "Bring up the Linux desktop on this iPad, optionally switching to a specific flavor.",
        categoryName: "Desktop")

    /// The display app has to be foreground for the compositor to present into
    /// its surface, so this always opens Xios rather than running headless.
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Flavor",
               description: "Which desktop to start. Leave unset to just show the desktop that's already running.")
    var flavor: DesktopFlavor?

    static var parameterSummary: some ParameterSummary {
        Summary("Open the \(\.$flavor) desktop")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        // No flavor named: "show me the desktop". If something healthy is already
        // up, foregrounding the app (openAppWhenRun) is the whole job — don't
        // tear a working session down just because the user said "open desktop".
        guard let flavor else {
            if let status = XiosControl.sessionStatus(),
               status.state == "up" || status.state == "compositor-only" {
                return .result(dialog: "\(status.preset) is already running.")
            }
            // Nothing up: start the default compositor, but with ENSURE semantics
            // so a session mid-bring-up isn't restarted underneath itself.
            do {
                let outcome = try XiosControl.startSession(preset: "iosc", ensure: true)
                return .result(dialog: outcome == .alreadyActive
                               ? "The desktop is already running."
                               : "Starting the desktop.")
            } catch {
                throw wrap(error)
            }
        }

        do {
            // Explicit flavor from the user = an explicit switch. Plain SESSION,
            // which ioscd honors from this app because of the peer-path check.
            let outcome = try XiosControl.startSession(preset: flavor.preset)
            return .result(dialog: outcome == .alreadyActive
                           ? "\(flavor.label) is already running."
                           : "Starting \(flavor.label).")
        } catch {
            throw wrap(error)
        }
    }
}

// MARK: - Open an app on the desktop

/// A launchable Linux app, sourced live from ioscd's APPS_LIST. The identifier is
/// the desktop-entry app id — the only thing that crosses the control socket.
@available(iOS 16.0, *)
struct DesktopAppEntity: AppEntity, Identifiable {
    let id: String
    let name: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Desktop App"
    static var defaultQuery = DesktopAppQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(id)")
    }
}

@available(iOS 16.0, *)
struct DesktopAppQuery: EntityStringQuery {
    /// Shortcuts hands back identifiers it captured earlier; the app may have
    /// been uninstalled since, so re-resolve against the live list.
    func entities(for identifiers: [String]) async throws -> [DesktopAppEntity] {
        let live = XiosControl.launchableApps()
        return identifiers.compactMap { id in
            live.first { $0.id == id }.map { DesktopAppEntity(id: $0.id, name: $0.name) }
        }
    }

    /// Lets the user say the app's display name instead of its id.
    func entities(matching string: String) async throws -> [DesktopAppEntity] {
        let needle = string.lowercased()
        return XiosControl.launchableApps()
            .filter { $0.name.lowercased().contains(needle) || $0.id.lowercased().contains(needle) }
            .map { DesktopAppEntity(id: $0.id, name: $0.name) }
    }

    func suggestedEntities() async throws -> [DesktopAppEntity] {
        XiosControl.launchableApps().map { DesktopAppEntity(id: $0.id, name: $0.name) }
    }
}

@available(iOS 16.0, *)
struct OpenAppOnDesktopIntent: AppIntent {
    static var title: LocalizedStringResource = "Open App on Desktop"
    static var description = IntentDescription(
        "Launch a Linux app on the desktop, or raise it if it's already open.",
        categoryName: "Desktop")

    static var openAppWhenRun: Bool = true

    @Parameter(title: "App", description: "The Linux app to open.")
    var app: DesktopAppEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$app) on the desktop")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        do {
            // ioscd brings the compositor up if it isn't running, foregrounds the
            // display app, and raises an existing window instead of duplicating
            // it — all already implemented behind this one verb.
            let outcome = try XiosControl.launchApp(app.id)
            return .result(dialog: outcome == "RAISED"
                           ? "Bringing \(app.name) to the front."
                           : "Opening \(app.name).")
        } catch {
            throw wrap(error)
        }
    }
}

// MARK: - Desktop Status

@available(iOS 16.0, *)
struct DesktopStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Desktop Status"
    static var description = IntentDescription(
        "Report which desktop flavor is running and how it's behaving.",
        categoryName: "Desktop")

    /// Pure query — answer it without stealing the screen.
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        // Distinguish "no desktop" from "no daemon": the first is a normal idle
        // iPad, the second means the jailbreak's LaunchDaemon isn't up and every
        // other intent here would fail too.
        guard XiosControl.daemonReachable() else {
            let msg = "The desktop daemon isn't running."
            return .result(value: msg, dialog: "\(msg)")
        }

        guard let status = XiosControl.sessionStatus() else {
            let msg = "No desktop session is running."
            return .result(value: msg, dialog: "\(msg)")
        }

        var sentence: String
        switch status.state {
        case "up", "compositor-only":
            sentence = "\(status.preset) is running"
            if let w = status.width, let h = status.height {
                sentence += " at \(w) by \(h)"
            }
            sentence += "."
        case "starting", "waiting", "relaunching":
            sentence = "\(status.preset) is still starting up."
        case "down", "stopped":
            sentence = "No desktop session is running."
        case "error":
            sentence = "\(status.preset) failed to start"
            sentence += status.message.isEmpty ? "." : ": \(status.message)"
        default:
            sentence = "\(status.preset) is \(status.state)."
        }

        // The behaviour table xios-status prints — pacing and upscale are the two
        // that actually explain "why does it feel slow", so surface them.
        let runtime = XiosControl.runtimeStatus()
        let detail = ["pacing", "upscale"].compactMap { key -> String? in
            guard let hit = runtime.first(where: { $0.key.hasPrefix(key) }) else { return nil }
            return "\(hit.key) \(hit.value)"
        }
        if !detail.isEmpty {
            sentence += " (" + detail.joined(separator: ", ") + ")"
        }

        return .result(value: sentence, dialog: "\(sentence)")
    }
}

// MARK: - Siri phrases

@available(iOS 16.0, *)
struct XiosShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenDesktopIntent(),
            phrases: [
                "Open the \(.applicationName) desktop",
                "Start my \(.applicationName) desktop",
                "Show the Linux desktop in \(.applicationName)",
            ],
            shortTitle: "Open Desktop",
            systemImageName: "display")

        AppShortcut(
            intent: OpenAppOnDesktopIntent(),
            phrases: [
                "Open an app on the \(.applicationName) desktop",
                "Launch a Linux app with \(.applicationName)",
            ],
            shortTitle: "Open App on Desktop",
            systemImageName: "square.grid.2x2")

        AppShortcut(
            intent: DesktopStatusIntent(),
            phrases: [
                "\(.applicationName) desktop status",
                "What's running on my \(.applicationName) desktop",
            ],
            shortTitle: "Desktop Status",
            systemImageName: "info.circle")
    }
}

// MARK: - Errors

/// Siri reads `localizedStringResource` verbatim, so map the control client's
/// errors onto sentences rather than letting a raw `ERR ...` line through.
@available(iOS 16.0, *)
private func wrap(_ error: Error) -> Error {
    guard let control = error as? XiosControl.ControlError else { return error }
    switch control {
    case .daemonUnreachable:
        return XiosIntentError.message("The desktop daemon isn't running on this iPad.")
    case .refused(let detail), .invalidArgument(let detail):
        return XiosIntentError.message(detail)
    }
}

@available(iOS 16.0, *)
enum XiosIntentError: Swift.Error, CustomLocalizedStringResourceConvertible {
    case message(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .message(let text): return "\(text)"
        }
    }
}

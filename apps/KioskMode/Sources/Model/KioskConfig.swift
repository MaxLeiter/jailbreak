import Foundation
import Observation

/// How the user leaves ("escapes") a locked kiosk. Volume-button patterns are
/// used rather than a touch gesture because SpringBoard can reliably see hardware
/// button presses even while another app is fullscreen.
enum EscapeMethod: String, CaseIterable, Identifiable {
    case off
    case volumeUpTriple
    case volumeDownTriple

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off:              return "No escape"
        case .volumeUpTriple:   return "Volume Up ×3"
        case .volumeDownTriple: return "Volume Down ×3"
        }
    }

    var subtitle: String {
        switch self {
        case .off:              return "Stays locked until you turn it off here."
        case .volumeUpTriple:   return "Press Volume Up three times quickly to pause the lock."
        case .volumeDownTriple: return "Press Volume Down three times quickly to pause the lock."
        }
    }

    var symbol: String {
        switch self {
        case .off:              return "lock.fill"
        case .volumeUpTriple:   return "speaker.wave.3.fill"
        case .volumeDownTriple: return "speaker.wave.1.fill"
        }
    }
}

/// The single source of truth shared with the SpringBoard tweak. Persisted as a
/// plain plist that both processes (both run as `mobile`) read and write.
@Observable
final class KioskConfig {
    /// Master switch — is the kiosk armed?
    var enabled: Bool = false
    /// Bundle id of the app to lock to.
    var targetBundleID: String = ""
    /// Display name of that app (cached so the UI needn't re-query LaunchServices).
    var targetName: String = ""
    /// Escape pattern.
    var escapeMethod: EscapeMethod = .volumeUpTriple
    /// Runtime pause. The tweak flips this when the escape gesture fires; the app
    /// mirrors and can toggle it too.
    var paused: Bool = false
    /// Set once the user finishes onboarding, so we don't show it again.
    var configured: Bool = false

    // The shared config is stored under a filename that is deliberately NOT the
    // app's own CFPreferences domain. The app's bundle id is `com.max.kioskmode`,
    // so `com.max.kioskmode.plist` in Preferences IS the app's standard
    // NSUserDefaults domain — and `cfprefsd` loads that whole file into its cache
    // when UIKit touches `UserDefaults.standard` at launch, then flushes its stale
    // cache back over our direct writes. That silently reverted "disarm" (a
    // safety bug: the lock stayed armed after being toggled off). Using a
    // non-domain filename keeps `cfprefsd` out entirely, so both this app and the
    // SpringBoard tweak own the file with plain, authoritative file I/O.
    static let path = "/var/mobile/Library/Preferences/com.max.kioskmode.shared.plist"
    private static let legacyPath = "/var/mobile/Library/Preferences/com.max.kioskmode.plist"

    init() {
        Self.migrateLegacyIfNeeded()
        reload()
#if DEBUG
        KioskScreenshotScenario.current?.apply(to: self)
#endif
    }

    /// One-time move from the old (cfprefsd-clobbered) domain path to the new
    /// shared path, so an already-configured install isn't silently reset on
    /// upgrade. Best-effort; the tweak is updated to the new path in lockstep.
    private static func migrateLegacyIfNeeded() {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: path), fm.fileExists(atPath: legacyPath),
              let dict = NSDictionary(contentsOfFile: legacyPath) else { return }
        (dict as? [String: Any]).map { try? PropertyListSerialization
            .data(fromPropertyList: $0, format: .xml, options: 0)
            .write(to: URL(fileURLWithPath: path), options: .atomic) }
        try? fm.removeItem(atPath: legacyPath)
    }

    /// A live snapshot for display: what state is the lock actually in?
    enum RunState { case off, locked, paused }
    var runState: RunState {
        if !enabled || targetBundleID.isEmpty { return .off }
        return paused ? .paused : .locked
    }

    // MARK: Persistence

    func reload() {
        guard let dict = NSDictionary(contentsOfFile: Self.path) as? [String: Any] else { return }
        enabled        = dict["enabled"] as? Bool ?? false
        targetBundleID = dict["targetBundleID"] as? String ?? ""
        targetName     = dict["targetName"] as? String ?? ""
        escapeMethod   = (dict["escapeMethod"] as? String).flatMap(EscapeMethod.init) ?? .volumeUpTriple
        paused         = dict["paused"] as? Bool ?? false
        configured     = dict["configured"] as? Bool ?? false
    }

    func save() {
        let dict: [String: Any] = [
            "enabled":        enabled,
            "targetBundleID": targetBundleID,
            "targetName":     targetName,
            "escapeMethod":   escapeMethod.rawValue,
            "paused":         paused,
            "configured":     configured,
        ]
        do {
            let data = try PropertyListSerialization.data(
                fromPropertyList: dict, format: .xml, options: 0)
            try data.write(to: URL(fileURLWithPath: Self.path), options: .atomic)
        } catch {
            NSLog("[KioskMode] config write failed: \(error)")
        }
    }
}

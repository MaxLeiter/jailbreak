#if DEBUG
import Foundation

enum KioskScreenshotScenario: String {
    case onboarding
    case locked
    case paused
    case escape

    static var current: KioskScreenshotScenario? {
        ProcessInfo.processInfo.arguments
            .first { $0.hasPrefix("--screenshot=") }
            .flatMap { KioskScreenshotScenario(rawValue: String($0.dropFirst("--screenshot=".count))) }
    }

    func apply(to config: KioskConfig) {
        switch self {
        case .onboarding, .escape:
            config.enabled = false
            config.targetBundleID = ""
            config.targetName = ""
            config.escapeMethod = .volumeUpTriple
            config.paused = false
            config.configured = false
        case .locked:
            config.enabled = true
            config.targetBundleID = "com.max.kitchenhub"
            config.targetName = "KitchenHub"
            config.escapeMethod = .volumeUpTriple
            config.paused = false
            config.configured = true
        case .paused:
            config.enabled = true
            config.targetBundleID = "com.max.kitchenhub"
            config.targetName = "KitchenHub"
            config.escapeMethod = .volumeDownTriple
            config.paused = true
            config.configured = true
        }
    }
}
#endif

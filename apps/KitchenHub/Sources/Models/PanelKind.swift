import Foundation

/// The kinds of panel that can live on the board. Add a case here, give it a
/// view in `PanelContent`, and it shows up in the "Add Panel" menu automatically.
enum PanelKind: String, Codable, CaseIterable, Identifiable {
    case clock
    case timer
    case weather
    case recipe

    var id: String { rawValue }

    var title: String {
        switch self {
        case .clock:   return "Clock"
        case .timer:   return "Timer"
        case .weather: return "Weather"
        case .recipe:  return "Recipe"
        }
    }

    var symbol: String {
        switch self {
        case .clock:   return "clock"
        case .timer:   return "timer"
        case .weather: return "cloud.sun"
        case .recipe:  return "fork.knife"
        }
    }

    /// Size (in grid cells) used when a fresh panel of this kind is added.
    var defaultSize: (cols: Int, rows: Int) {
        switch self {
        case .clock:   return (4, 3)
        case .timer:   return (4, 3)
        case .weather: return (4, 3)
        case .recipe:  return (8, 5)
        }
    }

    /// Whether the panel has a working implementation (vs. a placeholder).
    var isImplemented: Bool { true }

    /// Whether the panel exposes a settings sheet (gear button in edit mode).
    var hasSettings: Bool { self == .recipe }
}

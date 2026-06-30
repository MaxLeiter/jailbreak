import SwiftUI

/// Top-level app state: theme, lock, dashboard layout, and the current route
/// (dashboard ↔ a detail screen). Persists theme + layout to disk.
@MainActor
final class KHModel: ObservableObject {
    enum Layout: String, CaseIterable, Identifiable {
        case grid = "Grid", hero = "Hero", mosaic = "Mosaic"
        var id: String { rawValue }
    }
    enum Route: Equatable { case dashboard, timers, weather, music, recipe, appletv }

    @Published var isDark: Bool { didSet { persist() } }
    @Published var layout: Layout { didSet { persist() } }
    @Published var locked = true
    @Published var route: Route = .dashboard

    private let saveURL = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("kh-prefs.json")

    init() {
        let prefs = (try? Data(contentsOf: FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("kh-prefs.json")))
            .flatMap { try? JSONDecoder().decode(Prefs.self, from: $0) }
        isDark = prefs?.isDark ?? true
        layout = Layout(rawValue: prefs?.layout ?? "Grid") ?? .grid
    }

    func open(_ r: Route) { withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { route = r } }
    func backToDashboard() { withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { route = .dashboard } }
    func toggleTheme() { withAnimation { isDark.toggle() } }
    func lock() { withAnimation(.easeInOut) { locked = true; route = .dashboard } }
    func unlock() { withAnimation(.easeInOut) { locked = false } }

    private struct Prefs: Codable { var isDark: Bool; var layout: String }
    private func persist() {
        if let data = try? JSONEncoder().encode(Prefs(isDark: isDark, layout: layout.rawValue)) {
            try? data.write(to: saveURL, options: .atomic)
        }
    }
}

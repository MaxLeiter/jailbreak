import SwiftUI

/// Maps a panel's kind to its view. Add new panel types here.
struct PanelContent: View {
    let panel: PanelLayout

    var body: some View {
        switch panel.kind {
        case .clock:
            ClockPanel()
        case .timer:
            TimerPanel(panelID: panel.id,
                       initialSeconds: TimeInterval(Int(panel.config["seconds"] ?? "300") ?? 300))
        case .weather:
            WeatherPanel()
        case .recipe:
            RecipePanel(urlString: panel.config["url"] ?? RecipePanel.defaultURL)
        }
    }
}

import SwiftUI

/// Root of the redesigned app: owns the shared models, applies the theme, and
/// switches between the lock screen, the dashboard, and the detail screens.
struct AppRoot: View {
    @StateObject private var app = KHModel()
    @StateObject private var timers = TimersModel()
    @StateObject private var weather = WeatherModel()
    @StateObject private var recipe = RecipeModel()
    @StateObject private var sonos = SonosController()
    @StateObject private var atv = AppleTVController()

    var body: some View {
        ZStack {
            KHBackground()

            if app.locked {
                LockView()
                    .transition(.opacity)
            } else {
                routed
                    .id(app.route)
                    .transition(.asymmetric(insertion: .opacity, removal: .opacity))
            }
        }
        .environmentObject(app)
        .environmentObject(timers)
        .environmentObject(weather)
        .environmentObject(recipe)
        .environmentObject(sonos)
        .environmentObject(atv)
        .preferredColorScheme(app.isDark ? .dark : .light)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .task {
#if DEBUG
            if KitchenScreenshotScenario.current != nil {
                weather.applyScreenshotFixture()
                timers.applyScreenshotFixture()
                recipe.applyScreenshotFixture()
                sonos.applyScreenshotFixture()
                return
            }
#endif
            weather.start()
            sonos.start(manualIP: "")
        }
    }

    @ViewBuilder private var routed: some View {
        switch app.route {
        case .dashboard: DashboardView()
        case .timers:    TimersScreen()
        case .weather:   WeatherScreen()
        case .music:     MusicScreen()
        case .recipe:    RecipeScreen()
        case .appletv:   AppleTVScreen()
        }
    }
}

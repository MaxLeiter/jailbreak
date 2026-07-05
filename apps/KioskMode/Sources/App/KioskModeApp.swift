import SwiftUI

@main
struct KioskModeApp: App {
    @State private var config = KioskConfig()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(config)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}

/// Shows onboarding until the user has configured a target app, then the
/// dashboard. Re-reads the shared config on foreground so the paused state (which
/// the tweak can flip via the escape gesture) stays in sync.
struct RootView: View {
    @Environment(KioskConfig.self) private var config
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        content
        .animation(.smooth(duration: 0.35), value: config.configured)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { config.reload() }
        }
    }

    @ViewBuilder private var content: some View {
#if DEBUG
        if KioskScreenshotScenario.current == .escape {
            NavigationStack { EscapeSettingsView() }
        } else {
            normalContent
        }
#else
        normalContent
#endif
    }

    @ViewBuilder private var normalContent: some View {
        if config.configured {
            NavigationStack { DashboardView() }
        } else {
            OnboardingFlow()
        }
    }
}

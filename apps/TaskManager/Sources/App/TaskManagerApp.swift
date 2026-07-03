import SwiftUI

@main
struct TaskManagerApp: App {
    @StateObject private var engine = MonitorEngine()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(engine)
                .preferredColorScheme(.dark)
        }
    }
}

/// Runs the sampling loop only while the app is frontmost — a live foreground
/// monitor, not a background daemon.
struct RootView: View {
    @EnvironmentObject private var engine: MonitorEngine
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ProcessListView()
            .onChange(of: scenePhase) { phase in
                switch phase {
                case .active: engine.start()
                default: engine.stop()
                }
            }
    }
}

import SwiftUI
import Foundation

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
        Group {
#if DEBUG
            if TaskManagerScreenshotScenario.current == .detail {
                ProcessDetailView(pid: TaskManagerScreenshotScenario.detailPID)
            } else {
                ProcessListView()
            }
#else
            ProcessListView()
#endif
        }
        .task {
#if DEBUG
            if TaskManagerScreenshotScenario.current != nil {
                engine.installScreenshotFixtures()
            }
#endif
        }
            .onChange(of: scenePhase) { phase in
#if DEBUG
                if TaskManagerScreenshotScenario.current != nil { return }
#endif
                switch phase {
                case .active: engine.start()
                default: engine.stop()
                }
            }
    }
}

#if DEBUG
enum TaskManagerScreenshotScenario: String {
    case overview
    case detail

    static var current: TaskManagerScreenshotScenario? {
        ProcessInfo.processInfo.arguments
            .first { $0.hasPrefix("--screenshot=") }
            .flatMap { TaskManagerScreenshotScenario(rawValue: String($0.dropFirst("--screenshot=".count))) }
    }

    static let detailPID: pid_t = 4201
}
#endif

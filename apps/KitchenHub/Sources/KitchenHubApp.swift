import SwiftUI

@main
struct KitchenHubApp: App {
    @StateObject private var store = BoardStore()

    var body: some Scene {
        WindowGroup {
            BoardView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
                .statusBarHidden(true)
                .persistentSystemOverlays(.hidden)   // fade the home indicator (iOS 16+)
        }
    }
}

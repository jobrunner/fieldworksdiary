import SwiftUI

@main
struct FieldworksdiaryApp: App {
    @StateObject private var container = AppContainer()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(container)
                .environmentObject(container.config)
                .environmentObject(container.auth)
                .environmentObject(container.sync)
                .environmentObject(container.featureFlags)
                .task { await container.bootstrap() }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                container.pendingFixes.resumePending()
                Task { await container.hydrate() }
            }
        }
    }
}

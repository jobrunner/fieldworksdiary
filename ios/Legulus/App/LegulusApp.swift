import SwiftUI

@main
struct LegulusApp: App {
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
                container.resumePendingFixes()
                container.featureFlags.start(url: container.config.featureFlagsURL)
                Task { await container.hydrate() }
            }
        }
    }
}

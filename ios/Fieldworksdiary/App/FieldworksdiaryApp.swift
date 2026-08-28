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
                .task { await container.bootstrap() }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                Task { await container.hydrate() }
            }
        }
    }
}

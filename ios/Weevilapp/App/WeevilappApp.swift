import SwiftUI

@main
struct WeevilappApp: App {
    @StateObject private var container = AppContainer()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(container)
                .environmentObject(container.config)
                .environmentObject(container.auth)
                .environmentObject(container.sync)
                .task { await container.bootstrap() }
        }
    }
}

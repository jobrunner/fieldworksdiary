import SwiftUI

struct RootView: View {
    @EnvironmentObject var auth: AuthSession

    var body: some View {
        Group {
            if auth.isSignedIn {
                MainTabs()
            } else {
                WelcomeView()
            }
        }
    }
}

private struct MainTabs: View {
    var body: some View {
        TabView {
            AddSampleView()
                .tabItem { Label("Neu", systemImage: "plus.circle.fill") }
            ExcursionsListView()
                .tabItem { Label("Exkursionen", systemImage: "calendar") }
            LocalitiesListView()
                .tabItem { Label("Fundorte", systemImage: "mappin.and.ellipse") }
            HealthView()
                .tabItem { Label("Status", systemImage: "heart.text.square") }
            SettingsView()
                .tabItem { Label("Einstellungen", systemImage: "gearshape") }
        }
    }
}

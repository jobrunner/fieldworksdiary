import SwiftUI

/// Root scene: gates on auth, hands the signed-in user to the new
/// home dashboard (Phase 14). The legacy `MainTabs` is retained in
/// `MainTabs.swift` for now — it isn't referenced from here, and will
/// be removed once the dashboard has fully proven itself in the field.
struct RootView: View {
    @EnvironmentObject var auth: AuthSession

    var body: some View {
        Group {
            if auth.isSignedIn {
                HomeView()
            } else {
                WelcomeView()
            }
        }
    }
}

import SwiftUI

/// Landing view shown while no user is signed in. Hosts E-Mail /
/// Passwort plus a teaser for Sign in with Apple (the actual wire-up
/// follows once the backend's Apple-OAuth2 provider is configured).
struct WelcomeView: View {
    @EnvironmentObject var auth: AuthSession
    @EnvironmentObject var config: AppConfig
    @State private var presenting: Destination?
    @State private var appleError: String?

    enum Destination: String, Identifiable {
        case login, register, reset, settings
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "ant.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(.tint)
                    Text("Fieldworksdiary")
                        .font(.largeTitle.weight(.semibold))
                    Text("Felderfassung für entomologische Aufsammlungen")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                Spacer()

                if config.endpointURL.isEmpty {
                    GroupBox("Endpoint fehlt") {
                        Text("Bitte erst unter Einstellungen einen Backend-Endpoint setzen (z. B. `http://192.168.178.30:8090`).")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button("Einstellungen öffnen") {
                            presenting = .settings
                        }
                        .padding(.top, 6)
                    }
                } else {
                    VStack(spacing: 12) {
                        AppleSignInButton(onError: { appleError = $0 })
                            .frame(maxWidth: .infinity)

                        HStack {
                            Rectangle().fill(.quaternary).frame(height: 1)
                            Text("oder").font(.caption).foregroundStyle(.secondary)
                            Rectangle().fill(.quaternary).frame(height: 1)
                        }
                        .padding(.vertical, 4)

                        Button {
                            presenting = .login
                        } label: {
                            Text("Mit E-Mail anmelden")
                                .frame(maxWidth: .infinity, minHeight: 48)
                                .font(.headline)
                        }
                        .buttonStyle(.borderedProminent)

                        Button {
                            presenting = .register
                        } label: {
                            Text("Konto erstellen")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.bordered)

                        Button("Passwort vergessen?") {
                            presenting = .reset
                        }
                        .font(.footnote)
                        .padding(.top, 6)
                    }
                    .padding(.horizontal)
                }

                Spacer()

                if let err = appleError ?? auth.signInError {
                    Text(err)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                Text(config.endpointURL.isEmpty ? "Backend: —" : "Backend: \(config.endpointURL)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }
            .padding()
            .sheet(item: $presenting) { dest in
                switch dest {
                case .login:    LoginView()
                case .register: RegisterView()
                case .reset:    PasswordResetView()
                case .settings: SettingsView()
                }
            }
        }
    }
}

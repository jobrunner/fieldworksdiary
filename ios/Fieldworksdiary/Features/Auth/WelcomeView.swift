import SwiftUI

/// Landing view shown while no user is signed in. Hosts E-Mail /
/// Passwort plus a teaser for Sign in with Apple (the actual wire-up
/// follows once the backend's Apple-OAuth2 provider is configured).
struct WelcomeView: View {
    @EnvironmentObject var auth: AuthSession
    @EnvironmentObject var config: AppConfig
    /// Hero-Icon wächst mit Dynamic Type mit.
    @ScaledMetric(relativeTo: .largeTitle) private var heroIconSize: CGFloat = 56
    @State private var presenting: Destination?
    @State private var appleError: String?

    enum Destination: String, Identifiable {
        case login, register, reset, settings
        var id: String {
            rawValue
        }
    }

    var body: some View {
        NavigationStack {
            // ScrollView + minHeight: geo.size.height keeps the
            // legacy centred-when-it-fits look on big screens AND
            // lets the user scroll to the bottom Settings affordance
            // on small screens / with AX5 / with the soft-keyboard
            // up, where the layout would otherwise clip.
            GeometryReader { geo in
                ScrollView {
                    welcomeStack
                        .frame(minHeight: geo.size.height)
                }
            }
            .sheet(item: $presenting) { dest in
                switch dest {
                case .login: LoginView()
                case .register: RegisterView()
                case .reset: PasswordResetView()
                case .settings: SettingsView()
                }
            }
        }
    }

    private var welcomeStack: some View {
        VStack(spacing: AppSpacing.xl) {
            Spacer()
            VStack(spacing: AppSpacing.sm) {
                Image(systemName: "ant.fill")
                    .font(.system(size: heroIconSize))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                HStack(spacing: AppSpacing.sm) {
                    Text("Legulus")
                        .font(.largeTitle.weight(.semibold))
                    EnvBadge(environment: config.environment)
                }
                .accessibilityElement(children: .combine)
                Text("Felderfassung für entomologische Aufsammlungen")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Spacer()

            if config.endpointURL.isEmpty {
                GroupBox("Endpoint fehlt") {
                    Text("Bitte erst unter Einstellungen einen Backend-Endpoint setzen (z. B. `https://tabularius.legulus.app`).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("Einstellungen öffnen") {
                        presenting = .settings
                    }
                    .padding(.top, AppSpacing.xs)
                }
            } else {
                VStack(spacing: AppSpacing.md) {
                    AppleSignInButton { appleError = $0 }
                        .frame(maxWidth: .infinity)

                    HStack {
                        Rectangle().fill(.quaternary).frame(height: 1)
                        Text("oder").font(.caption).foregroundStyle(.secondary)
                        Rectangle().fill(.quaternary).frame(height: 1)
                    }
                    .padding(.vertical, AppSpacing.xs)

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

                    Button {
                        presenting = .reset
                    } label: {
                        Text("Passwort vergessen?")
                            .font(.footnote)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .padding(.top, AppSpacing.xs)
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

            // Footer doubles as the way into Settings BEFORE login —
            // the default endpoint (e.g. the LAN dev IP) won't be
            // right for every install, so we need a path to change
            // it without first signing in.
            Button {
                presenting = .settings
            } label: {
                VStack(spacing: AppSpacing.xxs) {
                    Text(config.endpointURL.isEmpty ? "Backend: —" : "Backend: \(config.endpointURL)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                    Text("Endpoint ändern")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Backend-Endpoint ändern")
            .accessibilityHint(
                config.endpointURL.isEmpty
                    ? "Aktuell ist kein Endpoint gesetzt."
                    : "Aktuell: \(config.endpointURL). Öffnet die Einstellungen."
            )
        }
        .padding()
    }
}

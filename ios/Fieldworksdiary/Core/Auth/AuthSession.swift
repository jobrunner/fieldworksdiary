import Combine
import Foundation

/// The single source of truth for the currently signed-in user.
/// Lives in `AppContainer`, published to the UI via `@EnvironmentObject`.
///
/// The session also owns the token persistence (Keychain) and exposes
/// a synchronous `currentToken` accessor that HTTP clients pull at
/// request time — that's how every PocketBase call picks up the
/// `Authorization` header without each client having to know about
/// auth.
@MainActor
final class AuthSession: ObservableObject {
    @Published private(set) var currentUser: AuthUser?
    @Published var signInError: String?

    private let keychain: KeychainStore
    private let endpointProvider: () -> String

    init(endpointProvider: @escaping () -> String,
         keychain: KeychainStore = .default)
    {
        self.endpointProvider = endpointProvider
        self.keychain = keychain
    }

    /// Token used for HTTP `Authorization` headers. Returns nil while
    /// signed out. `nonisolated` so HTTP clients can read it from any
    /// thread without hopping to the main actor — reads go through
    /// Security APIs, which are thread-safe.
    nonisolated var currentToken: String? {
        keychain.string(forKey: KeychainStore.Keys.token)
    }

    var isSignedIn: Bool {
        currentUser != nil && currentToken != nil
    }

    /// Called once at app launch. Tries to refresh whatever token is
    /// in the Keychain; failure → silently clear the session. The UI
    /// then lands on the WelcomeView.
    func restoreOnLaunch() async {
        guard let token = currentToken else { return }
        do {
            let resp = try await AuthClient(endpoint: endpointProvider())
                .refresh(token: token)
            persist(token: resp.token, user: resp.record)
        } catch {
            clearLocal()
        }
    }

    func signInWithPassword(email: String, password: String) async throws {
        let resp = try await AuthClient(endpoint: endpointProvider())
            .signInWithPassword(email: email, password: password)
        persist(token: resp.token, user: resp.record)
    }

    func register(
        email: String,
        password: String,
        displayName: String,
        abbreviation: String
    ) async throws {
        let client = AuthClient(endpoint: endpointProvider())
        _ = try await client.register(
            email: email,
            password: password,
            displayName: displayName,
            abbreviation: abbreviation
        )
        // PocketBase doesn't auto-login on register; we follow up
        // with a sign-in call so the user lands signed in.
        try await signInWithPassword(email: email, password: password)
    }

    func requestPasswordReset(email: String) async throws {
        try await AuthClient(endpoint: endpointProvider())
            .requestPasswordReset(email: email)
    }

    func signInWithApple(identityToken: String, code: String) async throws {
        let resp = try await AuthClient(endpoint: endpointProvider())
            .signInWithApple(identityToken: identityToken, code: code)
        persist(token: resp.token, user: resp.record)
    }

    func signOut() {
        clearLocal()
    }

    func deleteAccount() async throws {
        guard let user = currentUser, let token = currentToken else { return }
        try await AuthClient(endpoint: endpointProvider())
            .deleteAccount(userID: user.id, token: token)
        clearLocal()
    }

    // MARK: - private

    private func persist(token: String, user: AuthUser) {
        keychain.setString(token, forKey: KeychainStore.Keys.token)
        keychain.setString(user.id, forKey: KeychainStore.Keys.userId)
        keychain.setString(user.email, forKey: KeychainStore.Keys.email)
        currentUser = user
        signInError = nil
    }

    private func clearLocal() {
        keychain.clear()
        currentUser = nil
    }
}

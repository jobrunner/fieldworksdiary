import AuthenticationServices
import SwiftUI

/// SwiftUI wrapper around `SignInWithAppleButton` that hands the
/// `identityToken` and authorization `code` off to `AuthSession`.
///
/// PocketBase's OAuth2 endpoint expects the provider-issued code; for
/// native Apple-Sign-In the `code` field gets the `authorizationCode`
/// from the credential. The backend (Apple Service ID + private key
/// in the PocketBase Admin UI) does the actual token exchange and
/// hands us back a PB session token.
///
/// Note: requires the `Sign In with Apple` entitlement on the app
/// target. We add that in `project.yml`.
struct AppleSignInButton: View {
    @EnvironmentObject var auth: AuthSession
    @Environment(\.colorScheme) private var colorScheme

    var onError: (String) -> Void = { _ in }

    var body: some View {
        SignInWithAppleButton(.signIn) { request in
            request.requestedScopes = [.email, .fullName]
        } onCompletion: { result in
            switch result {
            case let .success(auth):
                handle(authorization: auth)
            case let .failure(err):
                // User-cancel comes through here too — surface only
                // the real-error message; the cancel case is a no-op.
                if (err as NSError).code == ASAuthorizationError.canceled.rawValue {
                    return
                }
                onError(err.localizedDescription)
            }
        }
        .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
        .frame(height: 48)
    }

    private func handle(authorization: ASAuthorization) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = credential.identityToken,
              let token = String(data: tokenData, encoding: .utf8),
              let codeData = credential.authorizationCode,
              let code = String(data: codeData, encoding: .utf8)
        else {
            onError("Apple-Anmeldung lieferte keine verwertbaren Daten.")
            return
        }
        Task {
            do {
                try await auth.signInWithApple(identityToken: token, code: code)
            } catch let err as SampleClientError {
                onError(err.errorDescription ?? "Anmeldung fehlgeschlagen.")
            } catch {
                onError(error.localizedDescription)
            }
        }
    }
}

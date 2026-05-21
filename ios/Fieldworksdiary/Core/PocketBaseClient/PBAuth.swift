import Foundation

/// Tiny `URLRequest` extension that stamps the PocketBase auth token
/// onto outgoing requests. Each HTTP client takes an optional
/// `AuthSession` reference and calls `request.authenticate(with:)`
/// right before `URLSession.shared.data(for:)`.
extension URLRequest {
    mutating func authenticate(with session: AuthSession?) {
        if let token = session?.currentToken, !token.isEmpty {
            setValue(token, forHTTPHeaderField: "Authorization")
        }
    }
}

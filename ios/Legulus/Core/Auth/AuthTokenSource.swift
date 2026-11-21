import Foundation

/// Where an HTTP client gets the token for its `Authorization` header,
/// read at request time. `AuthSession` is the app-wide source;
/// `AccountBoundAuth` narrows it to one account.
protocol AuthTokenSource: AnyObject {
    var currentToken: String? { get }
}

extension AuthSession: AuthTokenSource {}

/// The token of the session, but only while the session belongs to one
/// particular account.
///
/// The local data of every account lives in its own database with its
/// own services (sync, hydrators). Those services read the token at
/// request time, possibly long after they were created — also after
/// their user signed out and someone else signed in. Bound to their
/// account they then get no token at all, so data of account A can
/// never be pushed with, or pulled under, the token of account B.
final class AccountBoundAuth: AuthTokenSource {
    private let source: AuthTokenSource
    let accountID: String

    init(source: AuthTokenSource, accountID: String) {
        self.source = source
        self.accountID = accountID
    }

    var currentToken: String? {
        guard let token = source.currentToken, Self.userID(ofToken: token) == accountID else { return nil }
        return token
    }

    /// The `id` claim of a PocketBase auth token (a JWT); nil when the
    /// token cannot be read. The signature is not checked — the server
    /// does that; this only tells whose token it is.
    static func userID(ofToken token: String) -> String? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = claims["id"] as? String, !id.isEmpty
        else { return nil }
        return id
    }
}

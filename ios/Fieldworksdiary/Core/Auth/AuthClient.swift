import Foundation

/// HTTP wrapper for PocketBase's built-in `users` collection auth
/// endpoints. The wrapper stays stateless — `AuthSession` is the
/// thing that holds the token and decides when to refresh.
struct AuthClient {
    let endpoint: String

    func signInWithPassword(email: String, password: String) async throws -> AuthResponse {
        try await post("/api/collections/users/auth-with-password", body: [
            "identity": email,
            "password": password
        ])
    }

    func register(email: String, password: String, displayName: String, abbreviation: String) async throws -> AuthUser {
        try await postSingle("/api/collections/users/records", body: [
            "email": email,
            "password": password,
            "passwordConfirm": password,
            "display_name": displayName,
            "abbreviation": abbreviation
        ])
    }

    /// Refreshes the auth token. Returns the new token + user. Caller
    /// must pass the current token via the URLSession header
    /// (PocketBase's refresh endpoint requires authentication).
    func refresh(token: String) async throws -> AuthResponse {
        try await post("/api/collections/users/auth-refresh", body: [:], extraHeaders: [
            "Authorization": token
        ])
    }

    func requestPasswordReset(email: String) async throws {
        try await postIgnoringResponse("/api/collections/users/request-password-reset", body: [
            "email": email
        ])
    }

    // Native Sign in with Apple (Phase R8). We send only the
    // identityToken — a JWT signed by Apple, audience = the app's
    // bundle id — to our own `/api/auth/apple-native` route. The
    // backend verifies it against Apple's JWKS, links/creates a user
    // by the stable `sub` claim, and returns the standard PB auth
    // response (`{token, record}`). The `code` is unused by this
    // path; the parameter stays so the AppleSignInButton call-site
    // doesn't have to change shape.
    // periphery:ignore — `code` is captured by the credential and
    // kept on the API for forward-compat with a future server-side
    // exchange flow.
    func signInWithApple(identityToken: String, code _: String) async throws -> AuthResponse {
        try await post("/api/auth/apple-native", body: [
            "identity_token": identityToken
        ])
    }

    func deleteAccount(userID: String, token: String) async throws {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SampleClientError.noEndpoint }
        guard let url = URL(string: trimmed.appending("/api/collections/users/records/\(userID)")) else {
            throw SampleClientError.invalidEndpoint
        }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.timeoutInterval = 10
        req.setValue(token, forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200 ..< 300).contains(status) else {
            throw SampleClientError.http(status: status, body: String(data: data, encoding: .utf8) ?? "")
        }
    }

    /// Writes the sample-id settings to the user's own record and
    /// returns the updated record.
    func updateUserSettings(userID: String, token: String, body: [String: Any]) async throws -> AuthUser {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SampleClientError.noEndpoint }
        guard let url = URL(string: trimmed.appending("/api/collections/users/records/\(userID)")) else {
            throw SampleClientError.invalidEndpoint
        }
        var req = URLRequest(url: url)
        req.httpMethod = "PATCH"
        req.timeoutInterval = 10
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(token, forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200 ..< 300).contains(status) else {
            throw SampleClientError.http(status: status, body: String(data: data, encoding: .utf8) ?? "")
        }
        do {
            return try JSONDecoder.fieldworks.decode(AuthUser.self, from: data)
        } catch {
            throw SampleClientError.decoding(error.localizedDescription)
        }
    }

    // MARK: - HTTP plumbing

    private func post(_ path: String, body: [String: Any], extraHeaders: [String: String] = [:]) async throws -> AuthResponse {
        let data = try await rawPost(path, body: body, extraHeaders: extraHeaders)
        do {
            return try JSONDecoder.fieldworks.decode(AuthResponse.self, from: data)
        } catch {
            throw SampleClientError.decoding(error.localizedDescription)
        }
    }

    private func postSingle(_ path: String, body: [String: Any], extraHeaders: [String: String] = [:]) async throws -> AuthUser {
        let data = try await rawPost(path, body: body, extraHeaders: extraHeaders)
        do {
            return try JSONDecoder.fieldworks.decode(AuthUser.self, from: data)
        } catch {
            throw SampleClientError.decoding(error.localizedDescription)
        }
    }

    private func postIgnoringResponse(_ path: String, body: [String: Any], extraHeaders: [String: String] = [:]) async throws {
        _ = try await rawPost(path, body: body, extraHeaders: extraHeaders)
    }

    private func rawPost(_ path: String, body: [String: Any], extraHeaders: [String: String]) async throws -> Data {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SampleClientError.noEndpoint }
        guard let url = URL(string: trimmed.appending(path)) else {
            throw SampleClientError.invalidEndpoint
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in extraHeaders {
            req.setValue(v, forHTTPHeaderField: k)
        }
        if !body.isEmpty {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        } else {
            req.httpBody = Data("{}".utf8)
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200 ..< 300).contains(status) else {
            throw SampleClientError.http(status: status, body: String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }
}

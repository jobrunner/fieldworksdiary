import Foundation

/// HTTP wrapper for PocketBase's built-in `users` collection auth
/// endpoints. The wrapper stays stateless — `AuthSession` is the
/// thing that holds the token and decides when to refresh.
struct AuthClient {
    let endpoint: String

    func signInWithPassword(email: String, password: String) async throws -> AuthResponse {
        try await post("/api/collections/users/auth-with-password", body: [
            "identity": email,
            "password": password,
        ])
    }

    func register(email: String, password: String, displayName: String, abbreviation: String) async throws -> AuthUser {
        try await postSingle("/api/collections/users/records", body: [
            "email": email,
            "password": password,
            "passwordConfirm": password,
            "display_name": displayName,
            "abbreviation": abbreviation,
        ])
    }

    /// Refreshes the auth token. Returns the new token + user. Caller
    /// must pass the current token via the URLSession header
    /// (PocketBase's refresh endpoint requires authentication).
    func refresh(token: String) async throws -> AuthResponse {
        try await post("/api/collections/users/auth-refresh", body: [:], extraHeaders: [
            "Authorization": token,
        ])
    }

    func requestPasswordReset(email: String) async throws {
        try await postIgnoringResponse("/api/collections/users/request-password-reset", body: [
            "email": email,
        ])
    }

    func requestEmailVerification(email: String) async throws {
        try await postIgnoringResponse("/api/collections/users/request-verification", body: [
            "email": email,
        ])
    }

    func signInWithApple(identityToken: String, code: String) async throws -> AuthResponse {
        // PocketBase Apple OAuth2 expects an internal "code" produced
        // by its OAuth2 flow. For native Apple-Sign-In on iOS we send
        // identityToken via the OAuth2 endpoint. Whether the backend
        // honours this depends on the PB-Admin-UI provider config —
        // out of scope for the iOS code, but the call site is here so
        // the UI can wire to it.
        try await post("/api/collections/users/auth-with-oauth2", body: [
            "provider": "apple",
            "code": code,
            "codeVerifier": "",
            "redirectUrl": "",
            "createData": [:],
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
        guard (200..<300).contains(status) else {
            throw SampleClientError.http(status: status, body: String(data: data, encoding: .utf8) ?? "")
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
        for (k, v) in extraHeaders { req.setValue(v, forHTTPHeaderField: k) }
        if !body.isEmpty {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        } else {
            req.httpBody = Data("{}".utf8)
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            throw SampleClientError.http(status: status, body: String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }
}

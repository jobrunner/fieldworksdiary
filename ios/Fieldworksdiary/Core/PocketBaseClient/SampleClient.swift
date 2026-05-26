import Foundation

enum SampleClientError: LocalizedError {
    case noEndpoint
    case invalidEndpoint
    case http(status: Int, body: String)
    /// Server rejected a versioned write with `409 Conflict`. The
    /// payload carries the server's current `version` so the caller
    /// can pull the fresh row and retry with the correct counter.
    case conflict(currentVersion: Int, body: String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .noEndpoint: "Kein Backend-Endpoint gesetzt."
        case .invalidEndpoint: "Endpoint-URL ist ungültig."
        case let .http(status, body): "HTTP \(status): \(body)"
        case let .conflict(version, _):
            "Konflikt: serverseitige Version ist \(version). Bitte neu laden."
        case let .decoding(message): "Antwort konnte nicht gelesen werden: \(message)"
        }
    }
}

/// Inspects a PocketBase 409 body for the `current_version` field
/// our `enforceVersion` hook attaches. Returns 0 if the body isn't
/// parseable — defensive against shape drift.
func parseConflictVersion(from body: String) -> Int {
    guard let data = body.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return 0
    }
    // PocketBase wraps the hook's `data` map under `"data"` in its
    // ApiError JSON. Honor both shapes (top-level + nested).
    if let v = json["current_version"] as? Int { return v }
    if let inner = json["data"] as? [String: Any],
       let v = inner["current_version"] as? Int { return v }
    return 0
}

struct SampleClient {
    let endpoint: String
    let auth: AuthSession?

    init(endpoint: String, auth: AuthSession? = nil) {
        self.endpoint = endpoint
        self.auth = auth
    }

    func createSample(_ input: SampleCreateInput) async throws -> Sample {
        let url = try makeURL(path: "/api/collections/samples/records")

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var body: [String: Any] = [
            "latitude": input.lat,
            "longitude": input.lon,
            "begin_date": isoFormatter.string(from: input.collectedFrom),
            "location_source": LocationSource.locationService.wireValue,
            "time_zone": "Europe/Berlin",
            "version": 1
        ]
        if let accuracy = input.accuracy { body["horizontal_accuracy"] = accuracy }
        if let altitude = input.altitude { body["altitude"] = altitude }
        if let notes = input.notes, !notes.isEmpty { body["notes"] = notes }
        if input.marked { body["marked"] = true }
        if let code = input.code, !code.isEmpty { body["sample_id"] = code }
        if let clientUuid = input.clientUuid, !clientUuid.isEmpty { body["client_uuid"] = clientUuid }
        if let clientUpdatedAt = input.clientUpdatedAt {
            body["client_updated_at"] = isoFormatter.string(from: clientUpdatedAt)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        return try await send(request)
    }

    /// Toggles the `marked` flag on an existing sample. PATCH-only —
    /// the caller is responsible for not invoking this on a row that
    /// hasn't been pushed yet (no backend id).
    func setMarked(id: String, marked: Bool) async throws -> Sample {
        let url = try makeURL(path: "/api/collections/samples/records/\(id)")
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["marked": marked])
        return try await send(request)
    }

    func fetchSample(id: String) async throws -> Sample {
        let url = try makeURL(path: "/api/collections/samples/records/\(id)")
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        return try await send(request)
    }

    /// Lists the most recent samples for the authenticated user. The
    /// backend already filters by owner via the collection rule, so we
    /// don't need a filter clause here.
    func listRecent(limit: Int = 200) async throws -> [Sample] {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SampleClientError.noEndpoint }
        var components = URLComponents(string: trimmed.appending("/api/collections/samples/records"))
        components?.queryItems = [
            URLQueryItem(name: "perPage", value: String(limit)),
            URLQueryItem(name: "sort", value: "-begin_date")
        ]
        guard let url = components?.url else {
            throw SampleClientError.invalidEndpoint
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.authenticate(with: auth)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200 ..< 300).contains(status) else {
            throw SampleClientError.http(status: status, body: String(data: data, encoding: .utf8) ?? "")
        }
        do {
            return try JSONDecoder.fieldworks.decode(SampleListResponse.self, from: data).items
        } catch {
            throw SampleClientError.decoding(error.localizedDescription)
        }
    }

    private func send(_ request: URLRequest) async throws -> Sample {
        var request = request
        request.authenticate(with: auth)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200 ..< 300).contains(status) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            if status == 409 {
                throw SampleClientError.conflict(
                    currentVersion: parseConflictVersion(from: body),
                    body: body
                )
            }
            throw SampleClientError.http(status: status, body: body)
        }
        do {
            return try JSONDecoder.fieldworks.decode(Sample.self, from: data)
        } catch {
            throw SampleClientError.decoding(error.localizedDescription)
        }
    }

    private func makeURL(path: String) throws -> URL {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SampleClientError.noEndpoint }
        guard let url = URL(string: trimmed.appending(path)) else {
            throw SampleClientError.invalidEndpoint
        }
        return url
    }
}

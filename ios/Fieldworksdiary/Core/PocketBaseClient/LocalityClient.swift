import Foundation

/// Eingabe-Struktur für `create`/`update` einer Locality. Nutzt den
/// synthetisierten Memberwise-Init (keine eigene Argument-Liste →
/// kein SwiftLint `function_parameter_count`-Treffer); die Sync-
/// Felder haben Defaults, damit der manuelle Edit-Flow nur die fünf
/// Kernfelder setzen muss.
///
/// R8d-Fix: der Wire-Body folgt jetzt dem R3-Schema
/// (`latitude`/`longitude`/`radius_m`/`location_source`/`version`/
/// `client_uuid`/`client_updated_at`) statt der alten
/// `centroid_*`-Namen, die der Server seit R3 nicht mehr als
/// Schreib-Felder kennt.
struct LocalityInput {
    var name: String
    var latitude: Double
    var longitude: Double
    var radiusM: Double
    var notes: String
    var locationSource: LocationSource = .user
    var version: Int = 1
    var clientUuid: String? = nil
    var clientUpdatedAt: Date? = nil

    var asDictionary: [String: Any] {
        var dict: [String: Any] = [
            "name": name,
            "latitude": latitude,
            "longitude": longitude,
            "radius_m": radiusM,
            "notes": notes,
            "location_source": locationSource.wireValue,
            "version": version
        ]
        if let clientUuid, !clientUuid.isEmpty {
            dict["client_uuid"] = clientUuid
        }
        if let clientUpdatedAt {
            dict["client_updated_at"] = Self.iso8601.string(from: clientUpdatedAt)
        }
        return dict
    }

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

/// Push-Schnittstelle für Locality-`create`, gegen die der SyncRunner
/// (R8d) den `.locality/.create`-Outbox-Dispatch testet. Produktiv
/// konformt `LocalityClient`.
protocol LocalityPushClient {
    func create(_ input: LocalityInput) async throws -> Locality
    /// Deletes a locality on the server; 404 counts as done.
    func delete(id: String) async throws
}

struct LocalityClient: LocalityPushClient {
    let endpoint: String
    let auth: AuthSession?

    init(endpoint: String, auth: AuthSession? = nil) {
        self.endpoint = endpoint
        self.auth = auth
    }

    func listAll(limit: Int = 200) async throws -> [Locality] {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SampleClientError.noEndpoint }
        var components = URLComponents(string: trimmed.appending("/api/collections/localities/records"))
        components?.queryItems = [
            URLQueryItem(name: "perPage", value: String(limit)),
            URLQueryItem(name: "sort", value: "name")
        ]
        guard let url = components?.url else { throw SampleClientError.invalidEndpoint }
        return try await sendList(url: url)
    }

    func create(_ input: LocalityInput) async throws -> Locality {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SampleClientError.noEndpoint }
        guard let url = URL(string: trimmed.appending("/api/collections/localities/records")) else {
            throw SampleClientError.invalidEndpoint
        }
        return try await sendOne(url: url, method: "POST", body: input.asDictionary)
    }

    func delete(id: String) async throws {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SampleClientError.noEndpoint }
        guard let url = URL(string: trimmed.appending("/api/collections/localities/records/\(id)")) else {
            throw SampleClientError.invalidEndpoint
        }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 8
        request.authenticate(with: auth)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200 ..< 300).contains(status) || status == 404 else {
            throw SampleClientError.http(status: status, body: String(data: data, encoding: .utf8) ?? "")
        }
    }

    func update(id: String, input: LocalityInput) async throws -> Locality {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SampleClientError.noEndpoint }
        guard let url = URL(string: trimmed.appending("/api/collections/localities/records/\(id)")) else {
            throw SampleClientError.invalidEndpoint
        }
        return try await sendOne(url: url, method: "PATCH", body: input.asDictionary)
    }

    // MARK: - HTTP plumbing

    private func sendList(url: URL) async throws -> [Locality] {
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.authenticate(with: auth)
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.assertOK(data: data, response: response)
        do {
            return try JSONDecoder.fieldworks.decode(LocalityListResponse.self, from: data).items
        } catch {
            throw SampleClientError.decoding(error.localizedDescription)
        }
    }

    private func sendOne(url: URL, method: String, body: [String: Any]?) async throws -> Locality {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 8
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        request.authenticate(with: auth)
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.assertOK(data: data, response: response)
        do {
            return try JSONDecoder.fieldworks.decode(Locality.self, from: data)
        } catch {
            throw SampleClientError.decoding(error.localizedDescription)
        }
    }

    private static func assertOK(data: Data, response: URLResponse) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200 ..< 300).contains(status) else {
            throw SampleClientError.http(status: status, body: String(data: data, encoding: .utf8) ?? "")
        }
    }
}

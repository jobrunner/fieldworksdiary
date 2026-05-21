import Foundation

struct LocalityClient {
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
            URLQueryItem(name: "sort", value: "name"),
        ]
        guard let url = components?.url else { throw SampleClientError.invalidEndpoint }
        return try await sendList(url: url)
    }

    func fetch(id: String) async throws -> Locality {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SampleClientError.noEndpoint }
        guard let url = URL(string: trimmed.appending("/api/collections/localities/records/\(id)")) else {
            throw SampleClientError.invalidEndpoint
        }
        return try await sendOne(url: url, method: "GET", body: nil)
    }

    func create(name: String, centroidLat: Double, centroidLon: Double, radiusM: Double, notes: String) async throws -> Locality {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SampleClientError.noEndpoint }
        guard let url = URL(string: trimmed.appending("/api/collections/localities/records")) else {
            throw SampleClientError.invalidEndpoint
        }
        let body: [String: Any] = [
            "name": name,
            "centroid_lat": centroidLat,
            "centroid_lon": centroidLon,
            "radius_m": radiusM,
            "notes": notes,
        ]
        return try await sendOne(url: url, method: "POST", body: body)
    }

    func update(id: String, name: String, centroidLat: Double, centroidLon: Double, radiusM: Double, notes: String) async throws -> Locality {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SampleClientError.noEndpoint }
        guard let url = URL(string: trimmed.appending("/api/collections/localities/records/\(id)")) else {
            throw SampleClientError.invalidEndpoint
        }
        let body: [String: Any] = [
            "name": name,
            "centroid_lat": centroidLat,
            "centroid_lon": centroidLon,
            "radius_m": radiusM,
            "notes": notes,
        ]
        return try await sendOne(url: url, method: "PATCH", body: body)
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
        guard (200..<300).contains(status) else {
            throw SampleClientError.http(status: status, body: String(data: data, encoding: .utf8) ?? "")
        }
    }
}

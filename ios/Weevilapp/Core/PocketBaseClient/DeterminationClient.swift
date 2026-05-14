import Foundation

struct DeterminationClient {
    let endpoint: String
    let auth: AuthSession?

    init(endpoint: String, auth: AuthSession? = nil) {
        self.endpoint = endpoint
        self.auth = auth
    }

    func listBySample(_ sampleID: String) async throws -> [Determination] {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SampleClientError.noEndpoint }
        var c = URLComponents(string: trimmed.appending("/api/collections/determinations/records"))
        c?.queryItems = [
            URLQueryItem(name: "filter", value: "sample='\(sampleID)'"),
            URLQueryItem(name: "sort", value: "-determined_on,-created"),
            URLQueryItem(name: "perPage", value: "50"),
        ]
        guard let url = c?.url else { throw SampleClientError.invalidEndpoint }
        var req = URLRequest(url: url); req.timeoutInterval = 6
        req.authenticate(with: auth)
        let (data, response) = try await URLSession.shared.data(for: req)
        try Self.assertOK(data: data, response: response)
        do {
            return try JSONDecoder.fieldworks.decode(DeterminationListResponse.self, from: data).items
        } catch {
            throw SampleClientError.decoding(error.localizedDescription)
        }
    }

    func create(sample: String, speciesText: String, kind: DeterminationKind,
                person: String?, determinedOn: Date?, notes: String) async throws -> Determination {
        try await write(method: "POST", path: "/api/collections/determinations/records",
                        sample: sample, speciesText: speciesText, kind: kind,
                        person: person, determinedOn: determinedOn, notes: notes)
    }

    func update(id: String, speciesText: String, kind: DeterminationKind,
                person: String?, determinedOn: Date?, notes: String) async throws -> Determination {
        try await write(method: "PATCH", path: "/api/collections/determinations/records/\(id)",
                        sample: nil, speciesText: speciesText, kind: kind,
                        person: person, determinedOn: determinedOn, notes: notes)
    }

    func delete(id: String) async throws {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SampleClientError.noEndpoint }
        guard let url = URL(string: trimmed.appending("/api/collections/determinations/records/\(id)")) else {
            throw SampleClientError.invalidEndpoint
        }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.timeoutInterval = 6
        req.authenticate(with: auth)
        let (data, response) = try await URLSession.shared.data(for: req)
        try Self.assertOK(data: data, response: response)
    }

    private func write(method: String, path: String,
                       sample: String?, speciesText: String, kind: DeterminationKind,
                       person: String?, determinedOn: Date?, notes: String) async throws -> Determination {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SampleClientError.noEndpoint }
        guard let url = URL(string: trimmed.appending(path)) else {
            throw SampleClientError.invalidEndpoint
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 6
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "species_text": speciesText,
            "kind": kind.rawValue,
            "notes": notes,
        ]
        if let sample { body["sample"] = sample }
        body["person"] = person ?? ""
        if let determinedOn {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            body["determined_on"] = f.string(from: determinedOn)
        } else {
            body["determined_on"] = ""
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        req.authenticate(with: auth)
        let (data, response) = try await URLSession.shared.data(for: req)
        try Self.assertOK(data: data, response: response)
        do {
            return try JSONDecoder.fieldworks.decode(Determination.self, from: data)
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

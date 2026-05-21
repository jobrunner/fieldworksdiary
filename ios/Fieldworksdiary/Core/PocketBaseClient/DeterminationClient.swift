import Foundation

/// Eingabe-Struktur für `create`/`update` einer Determination. Bündelt
/// die sechs Felder, die sonst als lange Argument-Liste durch die
/// Aufrufe wandern (SwiftLint `function_parameter_count` ≤ 5).
struct DeterminationInput {
    let speciesText: String
    let kind: DeterminationKind
    let person: String?
    let determinedOn: Date?
    let notes: String
}

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
        var components = URLComponents(string: trimmed.appending("/api/collections/determinations/records"))
        components?.queryItems = [
            URLQueryItem(name: "filter", value: "sample='\(sampleID)'"),
            URLQueryItem(name: "sort", value: "-determined_on,-created"),
            URLQueryItem(name: "perPage", value: "50")
        ]
        guard let url = components?.url else { throw SampleClientError.invalidEndpoint }
        var req = URLRequest(url: url)
        req.timeoutInterval = 6
        req.authenticate(with: auth)
        let (data, response) = try await URLSession.shared.data(for: req)
        try Self.assertOK(data: data, response: response)
        do {
            return try JSONDecoder.fieldworks.decode(DeterminationListResponse.self, from: data).items
        } catch {
            throw SampleClientError.decoding(error.localizedDescription)
        }
    }

    func create(sample: String, input: DeterminationInput) async throws -> Determination {
        try await write(
            method: "POST",
            path: "/api/collections/determinations/records",
            sample: sample,
            input: input
        )
    }

    func update(id: String, input: DeterminationInput) async throws -> Determination {
        try await write(
            method: "PATCH",
            path: "/api/collections/determinations/records/\(id)",
            sample: nil,
            input: input
        )
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

    private func write(
        method: String,
        path: String,
        sample: String?,
        input: DeterminationInput
    ) async throws -> Determination {
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
            "species_text": input.speciesText,
            "kind": input.kind.rawValue,
            "notes": input.notes
        ]
        if let sample { body["sample"] = sample }
        body["person"] = input.person ?? ""
        if let determinedOn = input.determinedOn {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            body["determined_on"] = formatter.string(from: determinedOn)
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
        guard (200 ..< 300).contains(status) else {
            throw SampleClientError.http(status: status, body: String(data: data, encoding: .utf8) ?? "")
        }
    }
}

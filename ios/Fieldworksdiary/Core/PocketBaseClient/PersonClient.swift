import Foundation

struct PersonClient {
    let endpoint: String
    let auth: AuthSession?

    init(endpoint: String, auth: AuthSession? = nil) {
        self.endpoint = endpoint
        self.auth = auth
    }

    func listAll(limit: Int = 200) async throws -> [Person] {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SampleClientError.noEndpoint }
        var c = URLComponents(string: trimmed.appending("/api/collections/people/records"))
        c?.queryItems = [
            URLQueryItem(name: "perPage", value: String(limit)),
            URLQueryItem(name: "sort", value: "full_name")
        ]
        guard let url = c?.url else { throw SampleClientError.invalidEndpoint }
        var req = URLRequest(url: url)
        req.timeoutInterval = 6
        req.authenticate(with: auth)
        let (data, response) = try await URLSession.shared.data(for: req)
        try Self.assertOK(data: data, response: response)
        do {
            return try JSONDecoder.fieldworks.decode(PersonListResponse.self, from: data).items
        } catch {
            throw SampleClientError.decoding(error.localizedDescription)
        }
    }

    func create(fullName: String, abbreviation: String, email: String) async throws -> Person {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SampleClientError.noEndpoint }
        guard let url = URL(string: trimmed.appending("/api/collections/people/records")) else {
            throw SampleClientError.invalidEndpoint
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 6
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "full_name": fullName,
            "abbreviation": abbreviation,
            "email": email
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.authenticate(with: auth)
        let (data, response) = try await URLSession.shared.data(for: req)
        try Self.assertOK(data: data, response: response)
        do {
            return try JSONDecoder.fieldworks.decode(Person.self, from: data)
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

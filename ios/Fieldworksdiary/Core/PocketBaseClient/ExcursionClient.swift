import Foundation

struct ExcursionClient {
    let endpoint: String
    let auth: AuthSession?

    init(endpoint: String, auth: AuthSession? = nil) {
        self.endpoint = endpoint
        self.auth = auth
    }

    func listRecent(limit: Int = 30) async throws -> [Excursion] {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SampleClientError.noEndpoint }
        var components = URLComponents(string: trimmed.appending("/api/collections/excursions/records"))
        components?.queryItems = [
            URLQueryItem(name: "perPage", value: String(limit)),
            URLQueryItem(name: "sort", value: "-collecting_day,-started_at")
        ]
        guard let url = components?.url else {
            throw SampleClientError.invalidEndpoint
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8

        request.authenticate(with: auth)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200 ..< 300).contains(status) else {
            throw SampleClientError.http(status: status, body: String(data: data, encoding: .utf8) ?? "")
        }
        do {
            return try JSONDecoder.fieldworks.decode(ExcursionListResponse.self, from: data).items
        } catch {
            throw SampleClientError.decoding(error.localizedDescription)
        }
    }

    /// Patches just the permit_number (text) field — PDF stays
    /// untouched. Pass an empty string to clear.
    func setPermitNumber(id: String, number: String) async throws -> Excursion {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SampleClientError.noEndpoint }
        guard let url = URL(string: trimmed.appending("/api/collections/excursions/records/\(id)")) else {
            throw SampleClientError.invalidEndpoint
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.timeoutInterval = 6
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["permit_number": number])
        request.authenticate(with: auth)
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.assertOK(data: data, response: response)
        do {
            return try JSONDecoder.fieldworks.decode(Excursion.self, from: data)
        } catch {
            throw SampleClientError.decoding(error.localizedDescription)
        }
    }

    /// Uploads (or replaces) the permit PDF via multipart PATCH.
    /// Optionally also patches `permit_number` in the same request.
    func uploadPermitPDF(id: String, fileURL: URL, permitNumber: String?) async throws -> Excursion {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SampleClientError.noEndpoint }
        guard let url = URL(string: trimmed.appending("/api/collections/excursions/records/\(id)")) else {
            throw SampleClientError.invalidEndpoint
        }
        let data = try Data(contentsOf: fileURL)
        let filename = fileURL.lastPathComponent
        let boundary = "----Boundary\(UUID().uuidString)"

        var body = Data()
        if let permitNumber {
            body.appendField(boundary: boundary, name: "permit_number", value: permitNumber)
        }
        body.appendFile(
            boundary: boundary,
            name: "permit_pdf",
            filename: filename,
            mimeType: "application/pdf",
            data: data
        )
        body.append("--\(boundary)--\r\n")

        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.timeoutInterval = 30
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.authenticate(with: auth)
        let (respData, response) = try await URLSession.shared.data(for: request)
        try Self.assertOK(data: respData, response: response)
        do {
            return try JSONDecoder.fieldworks.decode(Excursion.self, from: respData)
        } catch {
            throw SampleClientError.decoding(error.localizedDescription)
        }
    }

    /// Removes the stored PDF (sets the file field to empty). The
    /// permit number is preserved unless `clearNumber` is true.
    func clearPermitPDF(id: String, clearNumber: Bool = false) async throws -> Excursion {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SampleClientError.noEndpoint }
        guard let url = URL(string: trimmed.appending("/api/collections/excursions/records/\(id)")) else {
            throw SampleClientError.invalidEndpoint
        }
        var body: [String: Any] = ["permit_pdf": nil as Any? as Any]
        // PocketBase deletes the file when the field is set to "" via JSON.
        body["permit_pdf"] = ""
        if clearNumber { body["permit_number"] = "" }

        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.timeoutInterval = 6
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.authenticate(with: auth)
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.assertOK(data: data, response: response)
        do {
            return try JSONDecoder.fieldworks.decode(Excursion.self, from: data)
        } catch {
            throw SampleClientError.decoding(error.localizedDescription)
        }
    }

    func setLocality(id: String, locality: String?) async throws -> Excursion {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SampleClientError.noEndpoint }
        guard let url = URL(string: trimmed.appending("/api/collections/excursions/records/\(id)")) else {
            throw SampleClientError.invalidEndpoint
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.timeoutInterval = 6
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["locality": locality ?? ""]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.authenticate(with: auth)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200 ..< 300).contains(status) else {
            throw SampleClientError.http(status: status, body: String(data: data, encoding: .utf8) ?? "")
        }
        do {
            return try JSONDecoder.fieldworks.decode(Excursion.self, from: data)
        } catch {
            throw SampleClientError.decoding(error.localizedDescription)
        }
    }

    func fetch(id: String) async throws -> Excursion {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SampleClientError.noEndpoint }
        guard let url = URL(string: trimmed.appending("/api/collections/excursions/records/\(id)")) else {
            throw SampleClientError.invalidEndpoint
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 5

        request.authenticate(with: auth)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200 ..< 300).contains(status) else {
            throw SampleClientError.http(status: status, body: String(data: data, encoding: .utf8) ?? "")
        }
        do {
            return try JSONDecoder.fieldworks.decode(Excursion.self, from: data)
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

// Multipart-helper extensions moved to MultipartHelpers.swift so the
// PhotoClient (Phase 14) can share them. The methods themselves are
// unchanged.

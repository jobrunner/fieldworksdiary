import Foundation

/// Wire response for a `sample_photos` record. We only consume the
/// id; the rest comes back automatically from the multipart upload.
struct SamplePhotoResponse: Decodable {
    let id: String
    let sample: String
    let photoFile: String?

    enum CodingKeys: String, CodingKey {
        case id, sample
        case photoFile = "photo_file"
    }
}

/// Payload of a `.samplePhoto/.delete` mutation without backend id: the
/// photo was deleted before its upload was confirmed. An upload may
/// still have arrived (lost answer), so the record is looked up by its
/// client uuid.
struct PhotoDeletePayload: Codable, Equatable {
    let clientUUID: String

    enum CodingKeys: String, CodingKey {
        case clientUUID = "client_uuid"
    }
}

/// What the `SyncRunner` needs from the photo endpoint; `PhotoClient`
/// in production, a fake in tests.
protocol PhotoSyncClient {
    /// Uploads the file at `fileURL` unchanged as a `sample_photos`
    /// record. Repeating the call with the same `clientUUID` returns
    /// the record that already exists.
    /// With `allowsCellularAccess` false the transfer itself refuses the
    /// cellular network („Fotos nur im WLAN hochladen“), also when the
    /// connection changes after the caller checked.
    func upload(
        sampleBackendID: String, clientUUID: String, clientUpdatedAt: Date, fileURL: URL, allowsCellularAccess: Bool
    ) async throws -> SamplePhotoResponse
    /// The backend id of the caller's photo with this client uuid, or
    /// nil when there is none.
    func findID(clientUUID: String) async throws -> String?
    /// Deletes the record. Implementations may throw on 404; the
    /// caller treats that as done.
    func delete(id: String) async throws
}

/// HTTP client for `sample_photos`. The collection accepts a single
/// file (JPEG / PNG / HEIC), a `sample` relation and a `client_uuid`
/// for idempotency.
struct PhotoClient: PhotoSyncClient {
    let endpoint: String
    let auth: AuthSession?

    /// Full-resolution photos over a weak connection take their time.
    private static let uploadTimeout: TimeInterval = 300

    init(endpoint: String, auth: AuthSession? = nil) {
        self.endpoint = endpoint
        self.auth = auth
    }

    private func recordsURL(_ suffix: String = "") throws -> URL {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SampleClientError.noEndpoint }
        guard let url = URL(string: trimmed.appending("/api/collections/sample_photos/records" + suffix)) else {
            throw SampleClientError.invalidEndpoint
        }
        return url
    }

    /// The multipart body is written to a temporary file and streamed
    /// from there, so a large photo is never held in memory twice.
    func upload(
        sampleBackendID: String, clientUUID: String, clientUpdatedAt: Date, fileURL: URL, allowsCellularAccess: Bool
    ) async throws -> SamplePhotoResponse {
        let url = try recordsURL()
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let boundary = "----Boundary\(UUID().uuidString)"
        var head = Data()
        head.appendField(boundary: boundary, name: "sample", value: sampleBackendID)
        head.appendField(boundary: boundary, name: "client_uuid", value: clientUUID)
        head.appendField(boundary: boundary, name: "client_updated_at", value: iso.string(from: clientUpdatedAt))
        head.append("--\(boundary)\r\n")
        head.append("Content-Disposition: form-data; name=\"photo_file\"; filename=\"photo.jpg\"\r\n")
        head.append("Content-Type: image/jpeg\r\n\r\n")
        var tail = Data()
        tail.append("\r\n--\(boundary)--\r\n")

        let bodyURL = FileManager.default.temporaryDirectory.appendingPathComponent("upload-\(UUID().uuidString).multipart")
        defer { try? FileManager.default.removeItem(at: bodyURL) }
        try Self.writeBody(to: bodyURL, head: head, file: fileURL, tail: tail)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.uploadTimeout
        request.allowsCellularAccess = allowsCellularAccess
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.authenticate(with: auth)

        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: bodyURL)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200 ..< 300).contains(status) else {
            throw SampleClientError.http(status: status, body: String(data: data, encoding: .utf8) ?? "")
        }
        do {
            return try JSONDecoder.legulus.decode(SamplePhotoResponse.self, from: data)
        } catch {
            throw SampleClientError.decoding(error.localizedDescription)
        }
    }

    func findID(clientUUID: String) async throws -> String? {
        guard var components = try URLComponents(url: recordsURL(), resolvingAgainstBaseURL: false) else {
            throw SampleClientError.invalidEndpoint
        }
        // The uuid is our own (a UUID string); quotes are stripped all
        // the same so it can never end the filter literal.
        let safe = clientUUID.replacingOccurrences(of: "'", with: "")
        components.queryItems = [
            URLQueryItem(name: "filter", value: "client_uuid='\(safe)'"),
            URLQueryItem(name: "perPage", value: "1"),
            URLQueryItem(name: "fields", value: "id")
        ]
        guard let url = components.url else { throw SampleClientError.invalidEndpoint }
        var request = URLRequest(url: url)
        request.authenticate(with: auth)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200 ..< 300).contains(status) else {
            throw SampleClientError.http(status: status, body: String(data: data, encoding: .utf8) ?? "")
        }
        struct Page: Decodable {
            struct Item: Decodable { let id: String }
            let items: [Item]
        }
        do {
            return try JSONDecoder().decode(Page.self, from: data).items.first?.id
        } catch {
            throw SampleClientError.decoding(error.localizedDescription)
        }
    }

    func delete(id: String) async throws {
        var request = try URLRequest(url: recordsURL("/" + id))
        request.httpMethod = "DELETE"
        request.authenticate(with: auth)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200 ..< 300).contains(status) else {
            throw SampleClientError.http(status: status, body: String(data: data, encoding: .utf8) ?? "")
        }
    }

    /// head + the file's bytes + tail, copied in chunks.
    private static func writeBody(to bodyURL: URL, head: Data, file: URL, tail: Data) throws {
        FileManager.default.createFile(atPath: bodyURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: bodyURL)
        defer { try? output.close() }
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        try output.write(contentsOf: head)
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
            try output.write(contentsOf: chunk)
        }
        try output.write(contentsOf: tail)
    }
}

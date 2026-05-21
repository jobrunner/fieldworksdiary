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

/// HTTP client for `sample_photos`. The collection accepts a single
/// file (JPEG / PNG / HEIC), a `sample` relation and a `client_uuid`
/// for idempotency.
struct PhotoClient {
    let endpoint: String
    let auth: AuthSession?

    init(endpoint: String, auth: AuthSession? = nil) {
        self.endpoint = endpoint
        self.auth = auth
    }

    /// Uploads `jpegData` as a `sample_photos` record. Returns the
    /// backend id on success.
    func upload(
        sampleBackendID: String,
        clientUUID: String,
        clientUpdatedAt: Date,
        jpegData: Data,
        filename: String = "photo.jpg"
    ) async throws -> SamplePhotoResponse {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SampleClientError.noEndpoint }
        guard let url = URL(string: trimmed.appending("/api/collections/sample_photos/records")) else {
            throw SampleClientError.invalidEndpoint
        }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let boundary = "----Boundary\(UUID().uuidString)"
        var body = Data()
        body.appendField(boundary: boundary, name: "sample", value: sampleBackendID)
        body.appendField(boundary: boundary, name: "client_uuid", value: clientUUID)
        body.appendField(boundary: boundary, name: "client_updated_at", value: iso.string(from: clientUpdatedAt))
        body.appendFile(
            boundary: boundary,
            name: "photo_file",
            filename: filename,
            mimeType: "image/jpeg",
            data: jpegData
        )
        body.append("--\(boundary)--\r\n")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.authenticate(with: auth)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200 ..< 300).contains(status) else {
            throw SampleClientError.http(status: status, body: String(data: data, encoding: .utf8) ?? "")
        }
        do {
            return try JSONDecoder.fieldworks.decode(SamplePhotoResponse.self, from: data)
        } catch {
            throw SampleClientError.decoding(error.localizedDescription)
        }
    }
}

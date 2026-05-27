import Foundation

/// Pull-and-override client for `placemarks`.
///
/// The collection is read-allowed for any authenticated user (Spec
/// §6.1 — Placemark is a reference table, not owner-scoped). Writes
/// go through the dedicated `/api/localities/:id/placemark`
/// endpoints, which carry their own authorisation (only the
/// locality's owner may set or clear an override).
struct PlacemarkClient {
    let endpoint: String
    let auth: AuthSession?

    init(endpoint: String, auth: AuthSession? = nil) {
        self.endpoint = endpoint
        self.auth = auth
    }

    /// GET a single placemark by id. Used by Locality detail views
    /// when the locally cached row is missing (first ever view of
    /// the locality on this device).
    func fetch(id: String) async throws -> Placemark {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SampleClientError.noEndpoint }
        guard let url = URL(string: trimmed.appending("/api/collections/placemarks/records/\(id)")) else {
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
            return try JSONDecoder.fieldworks.decode(Placemark.self, from: data)
        } catch {
            throw SampleClientError.decoding(error.localizedDescription)
        }
    }
}

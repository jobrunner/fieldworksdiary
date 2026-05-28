import Foundation

/// Pull-only client for the server-emitted `locality_remap_events`
/// stream (Spec §5.3 / R6.2). The collection is owner-scoped on
/// the server, so a plain unfiltered list returns only events for
/// the authenticated user.
struct RemapEventClient {
    let endpoint: String
    let auth: AuthSession?

    init(endpoint: String, auth: AuthSession? = nil) {
        self.endpoint = endpoint
        self.auth = auth
    }

    /// Fetch every event created strictly after `since`. Pass `nil`
    /// to pull the entire stream (first run on a new device).
    /// Pagination: we keep it simple by lifting the perPage cap to
    /// 200 — at the projected merge rate (a handful per session)
    /// that's many sessions worth of events in a single call.
    func listSince(_ since: Date?, limit: Int = 200) async throws -> [LocalityRemapEvent] {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SampleClientError.noEndpoint }
        var components = URLComponents(
            string: trimmed.appending("/api/collections/locality_remap_events/records")
        )
        var query = [
            URLQueryItem(name: "perPage", value: String(limit)),
            URLQueryItem(name: "sort", value: "created") // oldest first — apply in order
        ]
        if let since {
            // PocketBase filter syntax: `created > "ISO-instant"`.
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            query.append(URLQueryItem(name: "filter", value: "created > \"\(formatter.string(from: since))\""))
        }
        components?.queryItems = query
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
            return try JSONDecoder.fieldworks
                .decode(LocalityRemapEventListResponse.self, from: data)
                .items
        } catch {
            throw SampleClientError.decoding(error.localizedDescription)
        }
    }
}

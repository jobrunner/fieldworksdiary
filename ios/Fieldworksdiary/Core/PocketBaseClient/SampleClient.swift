import Foundation

enum SampleClientError: LocalizedError {
    case noEndpoint
    case invalidEndpoint
    case http(status: Int, body: String)
    /// Server rejected a versioned write with `409 Conflict`. The
    /// payload carries the server's current `version` so the caller
    /// can pull the fresh row and retry with the correct counter.
    case conflict(currentVersion: Int, body: String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .noEndpoint: "Kein Backend-Endpoint gesetzt."
        case .invalidEndpoint: "Endpoint-URL ist ungültig."
        case let .http(status, body): Self.formatPocketBaseError(status: status, body: body)
        case let .conflict(version, _):
            "Konflikt: serverseitige Version ist \(version). Bitte neu laden."
        case let .decoding(message): "Antwort konnte nicht gelesen werden: \(Self.userFacing(message))"
        }
    }

    /// PocketBase returns errors as
    /// `{"code":400,"message":"...","data":{"field":{"code":"...","message":"..."}}}`.
    /// Surface that as a readable sentence instead of the raw blob so
    /// the user can actually read what went wrong (this was the
    /// problem with the Apple-login 400 in the WelcomeView footnote).
    static func formatPocketBaseError(status: Int, body: String) -> String {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return "HTTP \(status): \(userFacing(body))"
        }
        var top = (json["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if top.range(of: "placemark", options: .caseInsensitive) != nil {
            top = "Ortsangaben ungültig."
        }
        var fields: [String] = []
        if let payload = json["data"] as? [String: Any] {
            for key in payload.keys.sorted() {
                if let entry = payload[key] as? [String: Any],
                   let msg = entry["message"] as? String, !msg.isEmpty
                {
                    let label = fieldLabels[key] ?? userFacing(key)
                    let text = fieldMessages[entry["code"] as? String ?? ""] ?? userFacing(msg)
                    fields.append("\(label): \(text)")
                }
            }
        }
        switch (top.isEmpty, fields.isEmpty) {
        case (true, true): return "HTTP \(status): \(userFacing(body))"
        case (false, true): return "HTTP \(status) — \(top)"
        case (true, false): return "HTTP \(status) — \(fields.joined(separator: " · "))"
        case (false, false): return "HTTP \(status) — \(top) (\(fields.joined(separator: " · ")))"
        }
    }
}

extension SampleClientError {
    /// Server field names shown with their UI term. "Placemark" is an
    /// internal word and must never be user-visible (spec §4.9).
    static let fieldLabels = [
        "placemark": "Ortsangaben",
        "placemark_suggestion": "Ortsvorschlag"
    ]

    /// Known server validation codes with a German message.
    static let fieldMessages = [
        "validation_invalid_placemark": "nicht zugänglich"
    ]

    /// Replaces internal place-data terms in free server text.
    static func userFacing(_ text: String) -> String {
        text
            .replacingOccurrences(of: "placemark_suggestion", with: "Ortsvorschlag",
                                  options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "placemarks?", with: "Ortsangaben",
                                  options: [.regularExpression, .caseInsensitive])
    }
}

/// Inspects a PocketBase 409 body for the `current_version` field
/// our `enforceVersion` hook attaches. Returns 0 if the body isn't
/// parseable — defensive against shape drift.
func parseConflictVersion(from body: String) -> Int {
    guard let data = body.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
        return 0
    }
    // PocketBase wraps the hook's `data` map under `"data"` in its
    // ApiError JSON. Honor both shapes (top-level + nested).
    if let v = json["current_version"] as? Int { return v }
    if let inner = json["data"] as? [String: Any],
       let v = inner["current_version"] as? Int { return v }
    return 0
}

/// List endpoint the `SamplesHydrator` pulls from. `SampleClient`
/// conforms; tests inject a mock.
protocol SampleListClient {
    /// One page of the owner's samples ordered by `updated,id`, always
    /// requested as page 1 (keyset paging: offset paging would skip rows
    /// when a row is rewritten mid-scan).
    ///
    /// - `after`: continue strictly behind this `(updated, id)` pair.
    ///   Takes precedence over `updatedSince`.
    /// - `updatedSince`: first request of an incremental run, inclusive
    ///   (`updated >= updatedSince`; duplicates are harmless).
    ///
    /// A page shorter than `perPage` is the last one.
    func listPage(updatedSince: Date?, after: (updated: Date, id: String)?, perPage: Int) async throws -> [Sample]
}

extension SampleClient: SampleListClient {}

struct SampleClient {
    let endpoint: String
    let auth: AuthSession?

    init(endpoint: String, auth: AuthSession? = nil) {
        self.endpoint = endpoint
        self.auth = auth
    }

    /// Wire body of `POST /samples/records`. Time fields: `timezone`,
    /// `timezone_source` and the client's `collecting_day` (the backend
    /// takes it when valid, else computes it).
    static func createBody(_ input: SampleCreateInput) -> [String: Any] {
        var body = input.location.wireBody
        body["begin_date"] = wireFormatter.string(from: input.collectedFrom)
        if let end = input.collectedTo { body["end_date"] = wireFormatter.string(from: end) }
        body["is_all_day"] = input.isAllDay
        body["timezone"] = input.timezone
        if let source = input.timezoneSource { body["timezone_source"] = source.rawValue }
        if let day = input.collectingDay, !day.isEmpty { body["collecting_day"] = day }
        body["version"] = 1
        if let notes = input.notes, !notes.isEmpty { body["notes"] = notes }
        if input.marked { body["marked"] = true }
        if let code = input.code, !code.isEmpty { body["sample_id"] = code }
        if let clientUuid = input.clientUuid, !clientUuid.isEmpty { body["client_uuid"] = clientUuid }
        if let clientUpdatedAt = input.clientUpdatedAt {
            body["client_updated_at"] = wireFormatter.string(from: clientUpdatedAt)
        }
        return body
    }

    /// Wire body of `PATCH /samples/records/{id}`.
    static func updateBody(_ input: SampleUpdateInput) -> [String: Any] {
        var body = input.location.wireBody
        body["sample_id"] = input.code
        body["original_code"] = input.originalCode
        body["timezone"] = input.timezone
        if let source = input.timezoneSource { body["timezone_source"] = source.rawValue }
        if let day = input.collectingDay, !day.isEmpty { body["collecting_day"] = day }
        if let begin = input.beginDate { body["begin_date"] = wireFormatter.string(from: begin) }
        if let end = input.endDate { body["end_date"] = wireFormatter.string(from: end) }
        if let allDay = input.isAllDay { body["is_all_day"] = allDay }
        body["version"] = input.version
        body["client_uuid"] = input.clientUuid
        body["client_updated_at"] = wireFormatter.string(from: input.clientUpdatedAt)
        // Empty notes are intentional clears, not omissions — send "".
        body["notes"] = input.notes ?? ""
        return body
    }

    private static var wireFormatter: ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }

    func createSample(_ input: SampleCreateInput) async throws -> Sample {
        let url = try makeURL(path: "/api/collections/samples/records")

        let body = Self.createBody(input)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        return try await send(request)
    }

    /// Toggles the `marked` flag on an existing sample. PATCH-only —
    /// the caller is responsible for not invoking this on a row that
    /// hasn't been pushed yet (no backend id).
    func setMarked(id: String, marked: Bool) async throws -> Sample {
        let url = try makeURL(path: "/api/collections/samples/records/\(id)")
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["marked": marked])
        return try await send(request)
    }

    /// Pushes the user-editable fields (code + notes) plus coordinate,
    /// height, place data and `location_status` for an already-synced
    /// sample. Idempotent over `client_uuid`/
    /// `client_updated_at`, and carries the optimistic-lock `version`
    /// so the backend's `enforceVersion` hook can reject stale
    /// writes with 409.
    func updateSample(id: String, input: SampleUpdateInput) async throws -> Sample {
        let url = try makeURL(path: "/api/collections/samples/records/\(id)")

        let body = Self.updateBody(input)

        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(request)
    }

    func fetchSample(id: String) async throws -> Sample {
        let url = try makeURL(path: "/api/collections/samples/records/\(id)")
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        return try await send(request)
    }

    /// Lists one keyset page of the authenticated user's samples sorted
    /// by `updated,id`. The collection rule already filters by owner.
    func listPage(updatedSince: Date?, after: (updated: Date, id: String)?, perPage: Int) async throws -> [Sample] {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SampleClientError.noEndpoint }
        var components = URLComponents(string: trimmed.appending("/api/collections/samples/records"))
        var items = [
            URLQueryItem(name: "page", value: "1"),
            URLQueryItem(name: "perPage", value: String(perPage)),
            URLQueryItem(name: "sort", value: "updated,id"),
            URLQueryItem(name: "skipTotal", value: "1")
        ]
        if let after {
            let u = Self.pocketBaseDate(after.updated)
            items.append(URLQueryItem(
                name: "filter",
                value: "(updated > \"\(u)\" || (updated = \"\(u)\" && id > \"\(after.id)\"))"
            ))
        } else if let updatedSince {
            items.append(URLQueryItem(name: "filter", value: "(updated >= \"\(Self.pocketBaseDate(updatedSince))\")"))
        }
        components?.queryItems = items
        guard let url = components?.url else {
            throw SampleClientError.invalidEndpoint
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.authenticate(with: auth)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200 ..< 300).contains(status) else {
            throw SampleClientError.http(status: status, body: String(data: data, encoding: .utf8) ?? "")
        }
        do {
            return try JSONDecoder.fieldworks.decode(SampleListResponse.self, from: data).items
        } catch {
            throw SampleClientError.decoding(error.localizedDescription)
        }
    }

    /// PocketBase datetime literal (`yyyy-MM-dd HH:mm:ss.SSSZ`, UTC).
    static func pocketBaseDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS'Z'"
        // Round to whole ms so a decoded value formats back to the same literal.
        return f.string(from: Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1000).rounded() / 1000))
    }

    private func send(_ request: URLRequest) async throws -> Sample {
        var request = request
        request.authenticate(with: auth)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200 ..< 300).contains(status) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            if status == 409 {
                throw SampleClientError.conflict(
                    currentVersion: parseConflictVersion(from: body),
                    body: body
                )
            }
            throw SampleClientError.http(status: status, body: body)
        }
        do {
            return try JSONDecoder.fieldworks.decode(Sample.self, from: data)
        } catch {
            throw SampleClientError.decoding(error.localizedDescription)
        }
    }

    private func makeURL(path: String) throws -> URL {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SampleClientError.noEndpoint }
        guard let url = URL(string: trimmed.appending(path)) else {
            throw SampleClientError.invalidEndpoint
        }
        return url
    }
}

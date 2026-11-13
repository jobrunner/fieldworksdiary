import FieldworksGeo
import Foundation

/// Point query against the Ortus geo service. Abstracted so the
/// `SampleLocationResolver` can be tested with a fake.
protocol OrtusQuerying: Sendable {
    func query(lat: Double, lon: Double) async throws -> OrtusResponse
    /// Converts a typed coordinate (any supported system) via Ortus.
    /// Throws `CoordinateInputError` or `OrtusQueryError`.
    func query(input: CoordinateInput) async throws -> OrtusResponse
}

/// Failure of `query(input:)`, with the user-facing message.
enum OrtusQueryError: Error, Equatable {
    case offline
    case server(message: String?)
    case noWGS84

    var userMessage: String {
        switch self {
        case .offline:
            "Keine Verbindung zu Ortus. Bitte später erneut versuchen."
        case let .server(message):
            if let message, !message.isEmpty {
                "Ortus konnte die Koordinate nicht umrechnen: \(message)"
            } else {
                "Ortus konnte die Koordinate nicht umrechnen."
            }
        case .noWGS84:
            "Ortus konnte die Koordinate nicht umrechnen."
        }
    }

    /// Message for any failure of a typed-coordinate query: unparsable
    /// input is caught locally, Ortus failures carry their own text.
    static func userMessage(for error: Error) -> String {
        switch error {
        case let ortusError as OrtusQueryError:
            ortusError.userMessage
        case is CoordinateInputError:
            "Bitte eine gültige Koordinate eingeben."
        default:
            OrtusQueryError.server(message: nil).userMessage
        }
    }

    /// The query was cancelled (dialog closed, view left) — no error to show.
    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }
}

enum OrtusClientError: LocalizedError {
    case invalidEndpoint
    case http(status: Int)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "Ortus-Endpoint-URL ist ungültig."
        case let .http(status): "Ortus antwortete mit HTTP \(status)."
        }
    }
}

/// Talks to `GET {endpoint}/api/v1/query?lat=…&lon=…` directly from
/// the device (Phase O2) — the same call the backend enricher makes
/// via `internal/services/ortus.go`, minus the cache. A short timeout
/// keeps the field flow snappy: if Ortus is slow, the sample keeps
/// its offline place and the backend enriches it after sync.
struct OrtusClient: OrtusQuerying {
    let endpoint: String
    let timeout: TimeInterval = 5
    var session: URLSession = .shared

    /// Returns nil for an empty endpoint — the caller then behaves as
    /// if the device were offline.
    static func make(endpoint: String) -> OrtusClient? {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return OrtusClient(endpoint: trimmed)
    }

    func query(input: CoordinateInput) async throws -> OrtusResponse {
        let items = try input.queryItems()
        let request = try makeRequest(items: items)
        let started = Date()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await fetch(request)
        } catch let error as URLError where Self.isOffline(error) {
            Log.network.warning("ortus input query offline")
            throw OrtusQueryError.offline
        }
        let durationMs = Int(Date().timeIntervalSince(started) * 1000)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(status) else {
            Log.network.warning(
                "ortus input query failed: HTTP \(status, privacy: .public), \(durationMs, privacy: .public) ms"
            )
            throw OrtusQueryError.server(message: Self.errorMessage(from: data))
        }
        guard !data.isEmpty,
              let decoded = try? JSONDecoder().decode(OrtusResponse.self, from: data),
              decoded.wgs84 != nil
        else {
            Log.network.warning("ortus input query without wgs84, \(durationMs, privacy: .public) ms")
            throw OrtusQueryError.noWGS84
        }
        Log.network.info("ortus input query ok: \(durationMs, privacy: .public) ms")
        return decoded
    }

    private static func isOffline(_ error: URLError) -> Bool {
        switch error.code {
        case .notConnectedToInternet, .timedOut, .networkConnectionLost, .cannotFindHost,
             .cannotConnectToHost, .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff:
            true
        default:
            false
        }
    }

    private static func errorMessage(from data: Data) -> String? {
        struct Body: Decodable { var message: String? }
        return (try? JSONDecoder().decode(Body.self, from: data))?.message
    }

    func query(lat: Double, lon: Double) async throws -> OrtusResponse {
        let request = try makeRequest(lat: lat, lon: lon)
        let started = Date()
        let (data, response) = try await fetch(request)
        let durationMs = Int(Date().timeIntervalSince(started) * 1000)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(status) else {
            Log.network.warning(
                "ortus query failed: HTTP \(status, privacy: .public), \(durationMs, privacy: .public) ms"
            )
            throw OrtusClientError.http(status: status)
        }
        Log.network.info("ortus query ok: \(durationMs, privacy: .public) ms")
        return try JSONDecoder().decode(OrtusResponse.self, from: data)
    }

    /// `URLRequest.timeoutInterval` is an idle timeout only; the race
    /// against a sleep caps the whole round trip at `timeout`.
    private func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let limit = timeout
        let session = session
        return try await withThrowingTaskGroup(of: (Data, URLResponse).self) { group in
            group.addTask { try await session.data(for: request) }
            group.addTask {
                try await Task.sleep(for: .seconds(limit))
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw URLError(.timedOut) }
            return first
        }
    }

    /// Builds the query URL with six decimals, like the backend client.
    func makeRequest(lat: Double, lon: Double) throws -> URLRequest {
        try makeRequest(items: [
            URLQueryItem(name: "lat", value: String(format: "%.6f", lat)),
            URLQueryItem(name: "lon", value: String(format: "%.6f", lon))
        ])
    }

    func makeRequest(items: [URLQueryItem]) throws -> URLRequest {
        let base = endpoint.hasSuffix("/") ? String(endpoint.dropLast()) : endpoint
        guard var components = URLComponents(string: base + "/api/v1/query") else {
            throw OrtusClientError.invalidEndpoint
        }
        components.queryItems = items
        guard let url = components.url, url.scheme != nil else {
            throw OrtusClientError.invalidEndpoint
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }
}

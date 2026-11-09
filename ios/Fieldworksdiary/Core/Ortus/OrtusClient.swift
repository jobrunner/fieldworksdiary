import FieldworksGeo
import Foundation

/// Point query against the Ortus geo service. Abstracted so the
/// `SampleLocationResolver` can be tested with a fake.
protocol OrtusQuerying: Sendable {
    func query(lat: Double, lon: Double) async throws -> OrtusResponse
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

    /// Returns nil for an empty endpoint — the caller then behaves as
    /// if the device were offline.
    static func make(endpoint: String) -> OrtusClient? {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return OrtusClient(endpoint: trimmed)
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
        return try await withThrowingTaskGroup(of: (Data, URLResponse).self) { group in
            group.addTask { try await URLSession.shared.data(for: request) }
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
        let base = endpoint.hasSuffix("/") ? String(endpoint.dropLast()) : endpoint
        guard var components = URLComponents(string: base + "/api/v1/query") else {
            throw OrtusClientError.invalidEndpoint
        }
        components.queryItems = [
            URLQueryItem(name: "lat", value: String(format: "%.6f", lat)),
            URLQueryItem(name: "lon", value: String(format: "%.6f", lon)),
        ]
        guard let url = components.url, url.scheme != nil else {
            throw OrtusClientError.invalidEndpoint
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }
}

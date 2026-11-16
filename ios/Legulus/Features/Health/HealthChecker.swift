import Foundation
import SwiftUI

@MainActor
final class HealthChecker: ObservableObject {
    enum Status {
        case unknown
        case checking
        case ok
        case failed

        var label: String {
            switch self {
            case .unknown: "Endpoint nicht gesetzt"
            case .checking: "Prüfe …"
            case .ok: "Verbunden"
            case .failed: "Nicht verbunden"
            }
        }

        var color: Color {
            switch self {
            case .unknown: .gray
            case .checking: .yellow
            case .ok: .green
            case .failed: .red
            }
        }
    }

    /// Shape of `GET /api/version` — see backend `internal/version.Info`.
    struct BackendVersion: Decodable {
        let version: String
        let commit: String
    }

    @Published private(set) var status: Status = .unknown
    @Published private(set) var detail: String = ""
    @Published private(set) var backendVersion: BackendVersion?

    /// Bumped on every `check()` call; a run only applies its results
    /// if it's still the most recent one when it finishes. Guards
    /// against HealthView firing check() from `.task`, `.onChange`,
    /// and the manual button in overlapping succession — without this,
    /// a slow older call for a stale endpoint could resolve after a
    /// newer one and overwrite its (correct) result.
    private var generation = 0

    func check(endpoint raw: String) async {
        generation += 1
        let myGeneration = generation

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed.appending("/api/health"))
        else {
            status = .unknown
            detail = "Endpoint in den Einstellungen setzen."
            backendVersion = nil
            return
        }

        status = .checking
        detail = url.absoluteString
        backendVersion = nil

        let request = makeRequest(url: url)

        // Beide Requests unabhängig parallel statt sequenziell — sonst
        // addieren sich die Timeouts (bis zu 10s statt 5s Worst-Case)
        // bei jedem Aufruf, nicht nur beim manuellen Retry.
        async let healthResult = URLSession.shared.data(for: request)
        async let versionResult = fetchBackendVersion(endpoint: trimmed)

        let backend = await versionResult
        guard generation == myGeneration else { return }

        do {
            let (_, response) = try await healthResult
            guard generation == myGeneration else { return }
            if let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) {
                status = .ok
                detail = url.absoluteString
                backendVersion = backend
            } else {
                status = .failed
                detail = "HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)"
            }
        } catch {
            guard generation == myGeneration else { return }
            status = .failed
            detail = error.localizedDescription
        }
    }

    /// Best-effort — a missing/failing `/api/version` (e.g. an older
    /// backend deploy without this route yet) just resolves nil, it
    /// doesn't flip the connection status.
    private func fetchBackendVersion(endpoint: String) async -> BackendVersion? {
        guard let url = URL(string: endpoint.appending("/api/version")) else { return nil }
        guard let (data, response) = try? await URLSession.shared.data(for: makeRequest(url: url)),
              let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode)
        else { return nil }
        return try? JSONDecoder().decode(BackendVersion.self, from: data)
    }

    /// `URLRequest` is a value type, but building it via `var` + mutation
    /// and then capturing that var inside `async let` (see `check(endpoint:)`)
    /// trips Swift's strict-concurrency Sendable check. Building it as an
    /// immutable expression sidesteps that without needing `@Sendable`.
    private nonisolated func makeRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        return request
    }
}

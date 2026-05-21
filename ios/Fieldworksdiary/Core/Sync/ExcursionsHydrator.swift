import Foundation

/// Pulls recent excursions from the backend and writes them into the
/// local store. Caller decides cadence (typically: on app foreground,
/// after a sample sync, pull-to-refresh).
@MainActor
final class ExcursionsHydrator: ObservableObject {
    let store: LocalExcursionStore
    let endpointProvider: () -> String
    let authProvider: () -> AuthSession?

    @Published private(set) var isLoading = false
    @Published private(set) var lastError: String?
    @Published private(set) var lastPulledAt: Date?

    init(store: LocalExcursionStore,
         endpointProvider: @escaping () -> String,
         authProvider: @escaping () -> AuthSession? = { nil }) {
        self.store = store
        self.endpointProvider = endpointProvider
        self.authProvider = authProvider
    }

    /// Pull the most recent N excursions and upsert them locally.
    func pull(limit: Int = 100) async {
        let endpoint = endpointProvider().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !endpoint.isEmpty else { return }
        if isLoading { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let client = ExcursionClient(endpoint: endpoint, auth: authProvider())
            let items = try await client.listRecent(limit: limit)
            try store.upsert(items)
            lastPulledAt = Date()
            lastError = nil
        } catch let err as SampleClientError {
            lastError = err.errorDescription
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Pull a single excursion by id and upsert it. Used after a
    /// sample sync to refresh that excursion's astro/enrichment.
    func pullOne(_ id: String) async {
        let endpoint = endpointProvider().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !endpoint.isEmpty else { return }
        do {
            let client = ExcursionClient(endpoint: endpoint, auth: authProvider())
            let item = try await client.fetch(id: id)
            try store.upsert([item])
            lastError = nil
        } catch let err as SampleClientError {
            lastError = err.errorDescription
        } catch {
            lastError = error.localizedDescription
        }
    }
}

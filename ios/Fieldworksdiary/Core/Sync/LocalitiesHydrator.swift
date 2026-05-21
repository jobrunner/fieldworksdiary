import Foundation

/// Pull-side hydrator for localities. Localities are low-volume and
/// rarely change, so a simple pull-on-launch + pull-to-refresh
/// strategy is enough. Writes go straight through HTTP (no offline
/// outbox) — typing a locality name in the field while offline is
/// rare and can be revisited later.
@MainActor
final class LocalitiesHydrator: ObservableObject {
    let store: LocalLocalityStore
    let endpointProvider: () -> String
    let authProvider: () -> AuthSession?

    @Published private(set) var isLoading = false
    @Published private(set) var lastError: String?
    @Published private(set) var lastPulledAt: Date?

    init(store: LocalLocalityStore,
         endpointProvider: @escaping () -> String,
         authProvider: @escaping () -> AuthSession? = { nil }) {
        self.store = store
        self.endpointProvider = endpointProvider
        self.authProvider = authProvider
    }

    func pull(limit: Int = 200) async {
        let endpoint = endpointProvider().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !endpoint.isEmpty else { return }
        if isLoading { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let client = LocalityClient(endpoint: endpoint, auth: authProvider())
            let items = try await client.listAll(limit: limit)
            try store.upsert(items)
            lastPulledAt = Date()
            lastError = nil
        } catch let err as SampleClientError {
            lastError = err.errorDescription
        } catch {
            lastError = error.localizedDescription
        }
    }
}

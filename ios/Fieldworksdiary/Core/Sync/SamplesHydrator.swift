import Foundation

/// Pull-side hydrator for samples. Mirrors the existing
/// `ExcursionsHydrator` and `LocalitiesHydrator` shape: the caller
/// decides cadence (e.g. on sign-in or app foreground) and we upsert
/// whatever the backend returns into the local store.
///
/// Push (offline-first sample creation) stays in `SyncRunner`; this
/// is purely the read-side that surfaces samples created on another
/// device when the user signs in here.
@MainActor
final class SamplesHydrator: ObservableObject {
    let store: LocalSampleStore
    let endpointProvider: () -> String
    let authProvider: () -> AuthSession?

    @Published private(set) var isLoading = false

    init(store: LocalSampleStore,
         endpointProvider: @escaping () -> String,
         authProvider: @escaping () -> AuthSession? = { nil })
    {
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
            let client = SampleClient(endpoint: endpoint, auth: authProvider())
            let items = try await client.listRecent(limit: limit)
            try store.upsert(items)
        } catch let err as SampleClientError {
            Log.sync.error("samples hydrate failed: \(err.errorDescription ?? "")")
        } catch {
            Log.sync.error("samples hydrate failed: \(error.localizedDescription)")
        }
    }
}

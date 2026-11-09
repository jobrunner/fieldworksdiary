import Foundation

/// Pull-side hydrator for samples. Mirrors the existing
/// `FieldtripsHydrator` and `LocalitiesHydrator` shape: the caller
/// decides cadence (e.g. on sign-in or app foreground) and we upsert
/// whatever the backend returns into the local store.
///
/// Push (offline-first sample creation) stays in `SyncRunner`; this
/// is purely the read-side that surfaces samples created on another
/// device when the user signs in here.
///
/// Phase O2: when the placemark and feature stores are wired, the
/// pull also fetches referenced placemarks and the features of
/// backend-enriched samples (see `SampleLocationHydration`).
@MainActor
final class SamplesHydrator: ObservableObject {
    let store: LocalSampleStore
    let endpointProvider: () -> String
    let authProvider: () -> AuthSession?
    let placemarks: LocalPlacemarkStore?
    let features: LocalSampleFeatureStore?
    let clientFactory: (_ endpoint: String, _ auth: AuthSession?) -> SampleListClient
    let placemarkClientFactory: (_ endpoint: String, _ auth: AuthSession?) -> PlacemarkSyncClient
    let featuresClientFactory: (_ endpoint: String, _ auth: AuthSession?) -> SampleFeaturesSyncClient

    @Published private(set) var isLoading = false

    init(store: LocalSampleStore,
         placemarks: LocalPlacemarkStore? = nil,
         features: LocalSampleFeatureStore? = nil,
         endpointProvider: @escaping () -> String,
         authProvider: @escaping () -> AuthSession? = { nil },
         clientFactory: @escaping (_ endpoint: String, _ auth: AuthSession?) -> SampleListClient = {
             SampleClient(endpoint: $0, auth: $1)
         },
         placemarkClientFactory: @escaping (_ endpoint: String, _ auth: AuthSession?) -> PlacemarkSyncClient = {
             PlacemarkClient(endpoint: $0, auth: $1)
         },
         featuresClientFactory: @escaping (_ endpoint: String, _ auth: AuthSession?) -> SampleFeaturesSyncClient = {
             SampleFeaturesClient(endpoint: $0, auth: $1)
         })
    {
        self.store = store
        self.placemarks = placemarks
        self.features = features
        self.endpointProvider = endpointProvider
        self.authProvider = authProvider
        self.clientFactory = clientFactory
        self.placemarkClientFactory = placemarkClientFactory
        self.featuresClientFactory = featuresClientFactory
    }

    func pull(limit: Int = 200) async {
        let endpoint = endpointProvider().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !endpoint.isEmpty else { return }
        if isLoading { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let auth = authProvider()
            let client = clientFactory(endpoint, auth)
            let items = try await client.listRecent(limit: limit)
            try store.upsert(items)
            if let placemarks, let features {
                await SampleLocationHydration(
                    samples: store,
                    placemarks: placemarks,
                    features: features,
                    placemarkClient: placemarkClientFactory(endpoint, auth),
                    featuresClient: featuresClientFactory(endpoint, auth)
                ).hydrate(items)
            }
        } catch let err as SampleClientError {
            Log.sync.error("samples hydrate failed: \(err.errorDescription ?? "")")
        } catch {
            Log.sync.error("samples hydrate failed: \(error.localizedDescription)")
        }
    }
}

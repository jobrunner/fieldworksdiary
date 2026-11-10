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
/// Incremental: the first run per user and endpoint pages through every
/// sample; later runs only fetch `updated >= cursor`. The cursor (largest
/// `updated` seen) is persisted in `UserDefaults` only after a complete
/// run, so an aborted run is repeated from the old cursor.
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

    let userIDProvider: () -> String
    let defaults: UserDefaults
    let perPage: Int
    let maxPages: Int

    private static let cursorKeyPrefix = "SamplesHydrator.cursor."

    @Published private(set) var isLoading = false

    init(store: LocalSampleStore,
         placemarks: LocalPlacemarkStore? = nil,
         features: LocalSampleFeatureStore? = nil,
         endpointProvider: @escaping () -> String,
         authProvider: @escaping () -> AuthSession? = { nil },
         userIDProvider: @escaping () -> String = { "" },
         defaults: UserDefaults = .standard,
         perPage: Int = 200,
         maxPages: Int = 100,
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
        self.userIDProvider = userIDProvider
        self.defaults = defaults
        self.perPage = perPage
        self.maxPages = maxPages
        self.clientFactory = clientFactory
        self.placemarkClientFactory = placemarkClientFactory
        self.featuresClientFactory = featuresClientFactory
    }

    /// Drops every persisted cursor (all users and endpoints). Called
    /// together with `LocalSampleStore.reset()` so the next run is a
    /// full scan again.
    func resetCursor() {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(Self.cursorKeyPrefix) {
            defaults.removeObject(forKey: key)
        }
    }

    /// The persisted cursor for the current user and endpoint.
    func currentCursor() -> Date? {
        let endpoint = endpointProvider().trimmingCharacters(in: .whitespacesAndNewlines)
        return cursor(forKey: cursorKey(endpoint: endpoint))
    }

    func pull() async {
        let endpoint = endpointProvider().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !endpoint.isEmpty else { return }
        if isLoading { return }
        isLoading = true
        defer { isLoading = false }

        let key = cursorKey(endpoint: endpoint)
        let since = cursor(forKey: key)
        do {
            let auth = authProvider()
            let client = clientFactory(endpoint, auth)
            let locationHydration: SampleLocationHydration? = {
                guard let placemarks, let features else { return nil }
                return SampleLocationHydration(
                    samples: store,
                    placemarks: placemarks,
                    features: features,
                    placemarkClient: placemarkClientFactory(endpoint, auth),
                    featuresClient: featuresClientFactory(endpoint, auth)
                )
            }()

            var newCursor = since
            var page = 1
            var processed = 0
            while true {
                let result = try await client.listPage(updatedSince: since, page: page, perPage: perPage)
                try store.upsert(result.items)
                await locationHydration?.hydrate(result.items)
                processed += result.items.count
                if let maxUpdated = result.items.compactMap(\.updated).max(),
                   newCursor.map({ maxUpdated > $0 }) ?? true
                {
                    newCursor = maxUpdated
                }
                if page >= result.totalPages || result.items.isEmpty { break }
                if page >= maxPages {
                    // Pages arrive in `updated` order — the next run
                    // continues from the cursor reached here.
                    Log.sync.warning(
                        "samples hydrate hit page cap \(self.maxPages, privacy: .public) of \(result.totalPages, privacy: .public)"
                    )
                    break
                }
                page += 1
            }
            if let newCursor, newCursor != since {
                defaults.set(newCursor.timeIntervalSince1970, forKey: key)
            }
            Log.sync.info(
                "samples hydrated: \(processed, privacy: .public) items, \(page, privacy: .public) pages, incremental \(since != nil, privacy: .public)"
            )
        } catch let err as SampleClientError {
            Log.sync.error("samples hydrate failed: \(err.errorDescription ?? "")")
        } catch {
            Log.sync.error("samples hydrate failed: \(error.localizedDescription)")
        }
    }

    // MARK: - cursor persistence

    private func cursorKey(endpoint: String) -> String {
        "\(Self.cursorKeyPrefix)\(endpoint).\(userIDProvider())"
    }

    private func cursor(forKey key: String) -> Date? {
        guard let value = defaults.object(forKey: key) as? Double else { return nil }
        return Date(timeIntervalSince1970: value)
    }
}

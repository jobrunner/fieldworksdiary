import Foundation

/// Everything that works on the local data of one account: its
/// database, the stores on top of it, and the services that sync them.
///
/// `AppContainer` holds exactly one graph, the one of the signed-in
/// account, and replaces it when the account changes. Nothing in a
/// graph is shared with another one: its database is the account's own
/// file (`AccountStorage`), and its services get the session token only
/// while the session belongs to this account (`AccountBoundAuth`). A
/// graph that is still finishing work after its user signed out can
/// therefore neither read nor write another account's data.
///
/// Without an account (signed out, previews) the graph runs on an empty
/// in-memory database and has no token.
@MainActor
final class AccountGraph {
    let accountID: String?
    // Hält den `DatabaseWriter` lebendig, solange der Graph lebt.
    // periphery:ignore
    let database: Database
    let store: LocalSampleStore
    let fieldtrips: LocalFieldtripStore
    let hydrator: FieldtripsHydrator
    let localitiesStore: LocalLocalityStore
    let localitiesHydrator: LocalitiesHydrator
    let samplesHydrator: SamplesHydrator
    let remapPuller: RemapEventsPuller
    let placemarksStore: LocalPlacemarkStore
    let sampleFeatures: LocalSampleFeatureStore
    let photos: LocalPhotoStore
    let mutations: PendingMutationsStore
    let sync: SyncRunner
    /// Fills in coordinates of instantly created samples (Phase E).
    let pendingFixes: PendingFixService

    init(accountID: String?, database: Database, config: AppConfig, session: AuthTokenSource, networkStatus: NetworkStatusProviding) {
        self.accountID = accountID
        // The services ask for the token at request time, possibly after
        // their user signed out; bound to the account they then get none.
        let tokens: AuthTokenSource? = accountID.map { AccountBoundAuth(source: session, accountID: $0) }

        let store = LocalSampleStore(database: database)
        let fieldtrips = LocalFieldtripStore(database: database)
        let hydrator = FieldtripsHydrator(
            store: fieldtrips,
            endpointProvider: { config.endpointURL },
            authProvider: { tokens }
        )
        let localitiesStore = LocalLocalityStore(database: database)
        let localitiesHydrator = LocalitiesHydrator(
            store: localitiesStore,
            endpointProvider: { config.endpointURL },
            authProvider: { tokens }
        )
        let placemarksStore = LocalPlacemarkStore(database: database)
        let sampleFeatures = LocalSampleFeatureStore(database: database)
        let samplesHydrator = SamplesHydrator(
            store: store,
            placemarks: placemarksStore,
            features: sampleFeatures,
            endpointProvider: { config.endpointURL },
            authProvider: { tokens },
            userIDProvider: { accountID ?? "" },
            sessionActive: { tokens?.currentToken != nil }
        )
        let remapPuller = RemapEventsPuller(
            localitiesStore: localitiesStore,
            endpointProvider: { config.endpointURL },
            authProvider: { tokens },
            userIDProvider: { accountID ?? "" }
        )
        let photos = LocalPhotoStore(database: database)
        let mutations = PendingMutationsStore(database: database)
        let sync = SyncRunner(
            store: store,
            mutationsStore: mutations,
            photoStore: photos,
            localitiesStore: localitiesStore,
            placemarkStore: placemarksStore,
            featureStore: sampleFeatures,
            endpointProvider: { config.endpointURL },
            authProvider: { tokens },
            photoUploadAllowed: { [networkStatus] in
                PhotoUploadPolicy.mayUpload(wifiOnly: config.photosWiFiOnly, onWiFi: networkStatus.isOnWiFi)
            },
            photoWiFiOnly: { config.photosWiFiOnly },
            onSampleSynced: { fieldtripID in
                Task { await hydrator.pullOne(fieldtripID) }
            },
            onLocalityChanged: {
                Task { await localitiesHydrator.pull() }
            }
        )

        let pendingFixes = PendingFixService(
            store: store,
            mutations: mutations,
            source: BackgroundFixSource(),
            onCoordinateSet: { sampleID in
                // Same pipeline as a sample created with a fix: fusion,
                // place (online, else inherited), sync.
                Task { @MainActor in
                    let resolver = SampleLocationResolver(
                        ortus: OrtusClient.make(endpoint: config.ortusEndpointURL),
                        samples: store,
                        placemarks: placemarksStore,
                        features: sampleFeatures,
                        mutations: mutations
                    )
                    SampleCreation.completeLateFix(
                        sampleID: sampleID,
                        store: store,
                        localitiesStore: localitiesStore,
                        mutationsStore: mutations,
                        resolver: resolver,
                        sync: sync
                    )
                }
            }
        )
        if let accountID {
            store.userId = accountID
        }
        self.database = database
        self.store = store
        self.fieldtrips = fieldtrips
        self.hydrator = hydrator
        self.localitiesStore = localitiesStore
        self.localitiesHydrator = localitiesHydrator
        self.samplesHydrator = samplesHydrator
        self.remapPuller = remapPuller
        self.placemarksStore = placemarksStore
        self.sampleFeatures = sampleFeatures
        self.photos = photos
        self.mutations = mutations
        self.sync = sync
        self.pendingFixes = pendingFixes
    }

    /// Ends the graph's background work when its account is left: no
    /// further sync passes, no waiting GPS fixes. Data stays on disk.
    func shutdown() {
        sync.shutdown()
        // The registrations are kept per device, not per account: when a
        // real account is left they must not be resumed for the next
        // one. The signed-out placeholder owns none and leaves them
        // alone — at app start it is replaced by the restored account,
        // which resumes them.
        if accountID != nil {
            pendingFixes.reset()
        }
    }

    /// Pulls the account's data from the server.
    func hydrateAll() async {
        // Fire every pull concurrently. Each hydrator is internally
        // single-flight, so a tab .task that also kicks pull() while
        // this is running just no-ops.
        async let samplesPull: Void = samplesHydrator.pull()
        async let fieldtripsPull: Void = hydrator.pull()
        async let localitiesPull: Void = localitiesHydrator.pull()
        async let remapPull: Void = remapPuller.pull()
        _ = await(samplesPull, fieldtripsPull, localitiesPull, remapPull)
    }
}

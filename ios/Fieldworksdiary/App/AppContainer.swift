import Combine
import Foundation

/// Single launch-time container. Owns the database, the auth session
/// and all long-lived services so views can pull them out of the
/// environment instead of constructing them piecemeal. Initialised
/// once at app launch and held by `@StateObject` on the root scene.
@MainActor
final class AppContainer: ObservableObject {
    let config: AppConfig
    let auth: AuthSession
    // Hält den `DatabaseWriter` lebendig, solange der Container lebt.
    // Wird nirgendwo direkt gelesen — die Stores haben eigene Refs —
    // aber ohne dieses Property würde ARC die `Database`-Instanz frei-
    // geben, sobald die Stores ihre eigenen Schwachreferenzen halten.
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
    /// Feature flags from Flipt (Phase E); `false` until loaded.
    let featureFlags: FeatureFlags

    /// Tracks which user id the local stores currently hold data for,
    /// so we can detect "different user just signed in" vs. "session
    /// restored / same user" and only wipe when needed.
    private var lastSeenUserID: String?
    private var authObservation: AnyCancellable?
    private var settingsObservation: AnyCancellable?

    init() {
        let config = AppConfig()
        let database: Database
        do {
            // Xcode Canvas setzt diese Env-Var für jeden #Preview-Render.
            // Ohne die Weiche würde jede Preview-Iteration den echten
            // Produktions-Datenstand unter applicationSupportDirectory
            // öffnen (WAL-Locking, Migrations-Re-Runs) — reiner Nebeneffekt
            // des Canvas-Renderns, den Tests genau deshalb schon über
            // `Database(inMemory:)` umgehen.
            if ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" {
                database = try Database(inMemory: ())
            } else {
                database = try Database()
            }
        } catch {
            fatalError("Database open failed: \(error)")
        }
        // The closure-capture chain below makes the AuthSession
        // discoverable from every service without each one holding
        // a direct reference — we just hand them a `() -> AuthSession?`.
        // That keeps the wiring shallow and avoids retain cycles.
        let auth = AuthSession { config.endpointURL }

        let store = LocalSampleStore(database: database)
        let fieldtrips = LocalFieldtripStore(database: database)
        let hydrator = FieldtripsHydrator(
            store: fieldtrips,
            endpointProvider: { config.endpointURL },
            authProvider: { [weak auth] in auth }
        )
        let localitiesStore = LocalLocalityStore(database: database)
        let localitiesHydrator = LocalitiesHydrator(
            store: localitiesStore,
            endpointProvider: { config.endpointURL },
            authProvider: { [weak auth] in auth }
        )
        let placemarksStore = LocalPlacemarkStore(database: database)
        let sampleFeatures = LocalSampleFeatureStore(database: database)
        let samplesHydrator = SamplesHydrator(
            store: store,
            placemarks: placemarksStore,
            features: sampleFeatures,
            endpointProvider: { config.endpointURL },
            authProvider: { [weak auth] in auth },
            userIDProvider: { [weak auth] in auth?.currentUser?.id ?? "" }
        )
        let remapPuller = RemapEventsPuller(
            localitiesStore: localitiesStore,
            endpointProvider: { config.endpointURL },
            authProvider: { [weak auth] in auth },
            userIDProvider: { [weak auth] in auth?.currentUser?.id ?? "" }
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
            authProvider: { [weak auth] in auth },
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
                let resolver = SampleLocationResolver(
                    ortus: OrtusClient.make(endpoint: config.ortusEndpointURL),
                    samples: store,
                    placemarks: placemarksStore,
                    features: sampleFeatures,
                    mutations: mutations
                )
                Task { @MainActor in
                    _ = await resolver.resolveOnline(sampleID: sampleID)
                    sync.kick()
                }
            }
        )

        self.featureFlags = FeatureFlags(entityIDProvider: { [weak auth] in auth?.currentUser?.id })
        self.config = config
        self.auth = auth
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

    /// Resolver for on-device place data. Reads the Ortus endpoint
    /// from `config` at call time, so a changed setting applies to the
    /// next editor; an empty endpoint yields a resolver without client
    /// (behaves as offline).
    func makeLocationResolver() -> SampleLocationResolver {
        SampleLocationResolver(
            ortus: OrtusClient.make(endpoint: config.ortusEndpointURL),
            samples: store,
            placemarks: placemarksStore,
            features: sampleFeatures,
            mutations: mutations
        )
    }

    /// Run once at app start: restore the auth session if there's a
    /// Keychain-stored token, then react to login/logout. The
    /// Combine subscription stays alive for the lifetime of the
    /// container — it's our hook for "user changed → wipe + re-hydrate".
    func bootstrap() async {
        MetricsReporter.shared.register()
        featureFlags.start(url: config.featureFlagsURL)
        startObservingAuth()
        startObservingUserSettings()
        await auth.restoreOnLaunch()
    }

    // MARK: - private

    private func startObservingAuth() {
        // `removeDuplicates` collapses the no-op republishes that
        // happen while we set `signInError` etc. — we only care about
        // user id transitions here.
        authObservation = auth.$currentUser
            .map { $0?.id }
            .removeDuplicates()
            .sink { [weak self] newID in
                guard let self else { return }
                Task { await self.handleAuthChange(to: newID) }
            }
    }

    /// Mirrors the sample-id settings of every login / token refresh
    /// (and of the cached user after an offline start) into `config`.
    private func startObservingUserSettings() {
        settingsObservation = auth.userRefreshed
            .sink { [weak self] user in
                self?.config.apply(user: user)
            }
    }

    private func handleAuthChange(to newID: String?) async {
        defer { lastSeenUserID = newID }

        // Different user (or signed out) — wipe local rows so two
        // identities never share the same store. We treat a fresh
        // launch with an existing keychain token (lastSeenUserID == nil,
        // newID == X) as "not a switch" — the local DB belongs to
        // that user already.
        if let previous = lastSeenUserID, previous != newID {
            wipeLocalStores()
        }

        guard let newID else { return }
        store.userId = newID
        await hydrateAll()
    }

    private func wipeLocalStores() {
        do {
            try store.reset()
            try fieldtrips.reset()
            try localitiesStore.reset()
            try placemarksStore.reset()
            try photos.reset()
            try mutations.reset()
            remapPuller.resetCursor()
            samplesHydrator.resetCursor()
        } catch {
            // Wipe failures are non-fatal — der neue User sieht
            // maximal Stale-Rows, die der Rule-Filter ohnehin
            // ausgeblendet hätte.
            Log.persistence.error("local-store wipe failed: \(error.localizedDescription)")
        }
    }

    /// Public entry point for foreground re-hydration (scene phase,
    /// pull-to-refresh). No-ops when signed out or no endpoint is set.
    func hydrate() async {
        guard auth.isSignedIn else { return }
        await hydrateAll()
    }

    private func hydrateAll() async {
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

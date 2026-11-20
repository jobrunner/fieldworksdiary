import Combine
import Foundation

/// Single launch-time container. Owns the auth session and the services
/// of the signed-in account so views can pull them out of the
/// environment instead of constructing them piecemeal. Initialised
/// once at app launch and held by `@StateObject` on the root scene.
///
/// The local data belongs to an account, not to the device: every
/// account has its own `AccountGraph` (database, stores, sync). The
/// container holds the graph of the current account and replaces it
/// when someone else signs in. Signing out deletes nothing — the data
/// stays in the account's database and is there again when its user
/// comes back.
@MainActor
final class AppContainer: ObservableObject {
    let config: AppConfig
    let auth: AuthSession
    /// Feature flags from Flipt (Phase E); `false` until loaded.
    let featureFlags: FeatureFlags

    /// The services of the current account; without one (signed out)
    /// an empty in-memory graph. Views must not keep it across an
    /// account change — `RootView` rebuilds the UI then.
    private(set) var graph: AccountGraph

    var store: LocalSampleStore {
        graph.store
    }

    var fieldtrips: LocalFieldtripStore {
        graph.fieldtrips
    }

    var hydrator: FieldtripsHydrator {
        graph.hydrator
    }

    var localitiesStore: LocalLocalityStore {
        graph.localitiesStore
    }

    var localitiesHydrator: LocalitiesHydrator {
        graph.localitiesHydrator
    }

    var samplesHydrator: SamplesHydrator {
        graph.samplesHydrator
    }

    var remapPuller: RemapEventsPuller {
        graph.remapPuller
    }

    var placemarksStore: LocalPlacemarkStore {
        graph.placemarksStore
    }

    var sampleFeatures: LocalSampleFeatureStore {
        graph.sampleFeatures
    }

    var photos: LocalPhotoStore {
        graph.photos
    }

    var mutations: PendingMutationsStore {
        graph.mutations
    }

    var sync: SyncRunner {
        graph.sync
    }

    var pendingFixes: PendingFixService {
        graph.pendingFixes
    }

    /// Account whose data the current graph holds; nil when signed out.
    var accountID: String? {
        graph.accountID
    }

    private let networkStatus = NetworkStatus()
    /// Application Support (tests pass a temporary folder). Nil keeps
    /// everything in memory: Xcode previews must not open real data.
    private let storageRoot: URL?
    private var authObservation: AnyCancellable?
    private var settingsObservation: AnyCancellable?

    convenience init() {
        // Xcode Canvas setzt diese Env-Var für jeden #Preview-Render.
        // Ohne die Weiche würde jede Preview-Iteration den echten
        // Datenstand unter applicationSupportDirectory öffnen
        // (WAL-Locking, Migrations-Re-Runs).
        if ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" {
            self.init(storageRoot: nil)
            return
        }
        let root = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        if let root {
            // Rename from the Fieldworksdiary days, before anything else
            // looks at the file.
            Database.adoptLegacyFile(in: root)
        }
        self.init(storageRoot: root)
    }

    init(storageRoot: URL?) {
        let config = AppConfig()
        let auth = AuthSession { config.endpointURL }
        self.config = config
        self.auth = auth
        self.storageRoot = storageRoot
        featureFlags = FeatureFlags(entityIDProvider: { [weak auth] in auth?.currentUser?.id })
        graph = Self.makeGraph(
            accountID: nil, storageRoot: storageRoot, config: config, session: auth, networkStatus: networkStatus
        )
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
    /// container — it's our hook for "account changed → other graph".
    func bootstrap() async {
        MetricsReporter.shared.register()
        featureFlags.start(url: config.featureFlagsURL)
        startObservingAuth()
        startObservingUserSettings()
        await auth.restoreOnLaunch()
    }

    /// Public entry point for foreground re-hydration (scene phase,
    /// pull-to-refresh). No-ops when signed out or no endpoint is set.
    func hydrate() async {
        guard auth.isSignedIn else { return }
        await graph.hydrateAll()
    }

    /// Resumes waiting GPS fixes when the app comes to the foreground.
    /// Nothing happens while signed out: the empty placeholder graph
    /// knows none of the samples and would drop their registrations.
    func resumePendingFixes() {
        guard graph.accountID != nil else { return }
        graph.pendingFixes.resumePending()
    }

    /// Makes `accountID` the current account: its own database and
    /// services replace the ones of the previous account, whose
    /// background work is stopped. Nothing is deleted and nothing is
    /// carried over. Synchronous, so the UI never renders with the
    /// graph of another account. No-op for the account that is already
    /// current.
    func switchAccount(to accountID: String?) {
        guard accountID != graph.accountID else { return }
        graph.shutdown()
        objectWillChange.send()
        graph = Self.makeGraph(
            accountID: accountID, storageRoot: storageRoot, config: config, session: auth, networkStatus: networkStatus
        )
        Log.app.notice("account graph switched, signed in: \(accountID != nil, privacy: .public)")
    }

    // MARK: - private

    /// The graph of an account on its own database. Without an account
    /// (signed out) or without storage (previews, some tests) it runs in
    /// memory. A database file that cannot be opened ends the app, as it
    /// always did: carrying on in memory would take samples that look
    /// saved and are gone with the process.
    private static func makeGraph(
        accountID: String?, storageRoot: URL?, config: AppConfig, session: AuthSession, networkStatus: NetworkStatus
    ) -> AccountGraph {
        let database: Database
        var isNewDatabase = false
        do {
            if let accountID, let storageRoot {
                // The single database of earlier versions goes to the
                // accounts its samples belong to — not necessarily this one.
                AccountStorage.adoptLegacyDatabase(signedInAccountID: accountID, in: storageRoot)
                let url = AccountStorage.databaseURL(accountID: accountID, in: storageRoot)
                isNewDatabase = !FileManager.default.fileExists(atPath: url.path)
                database = try Database(accountID: accountID, in: storageRoot)
            } else {
                database = try Database(inMemory: ())
            }
        } catch {
            fatalError("Database open failed: \(error)")
        }
        let graph = AccountGraph(
            accountID: accountID, database: database, config: config, session: session, networkStatus: networkStatus
        )
        if isNewDatabase {
            // The pull cursors live in UserDefaults, per user. A cursor
            // from the time this account shared the old database would
            // make the empty one skip everything older than it.
            graph.samplesHydrator.resetCursor()
            graph.remapPuller.resetCursor()
        }
        return graph
    }

    private func startObservingAuth() {
        // `removeDuplicates` collapses the no-op republishes that
        // happen while we set `signInError` etc. — we only care about
        // user id transitions here. `@Published` emits before the new
        // value is visible to views, and the switch runs synchronously
        // in the sink: no view ever sees the new user with the old
        // user's graph.
        authObservation = auth.$currentUser
            .map { $0?.id }
            .removeDuplicates()
            .sink { [weak self] newID in
                guard let self else { return }
                self.switchAccount(to: newID)
                guard newID != nil else { return }
                let graph = self.graph
                // Samples that were waiting for a GPS fix when the app
                // went away belong to this account's database.
                graph.pendingFixes.resumePending()
                Task { await graph.hydrateAll() }
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
}

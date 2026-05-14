import Foundation
import Combine

/// Single launch-time container. Owns the database, the auth session
/// and all long-lived services so views can pull them out of the
/// environment instead of constructing them piecemeal. Initialised
/// once at app launch and held by `@StateObject` on the root scene.
@MainActor
final class AppContainer: ObservableObject {
    let config: AppConfig
    let auth: AuthSession
    let database: Database
    let store: LocalSampleStore
    let excursions: LocalExcursionStore
    let hydrator: ExcursionsHydrator
    let localitiesStore: LocalLocalityStore
    let localitiesHydrator: LocalitiesHydrator
    let samplesHydrator: SamplesHydrator
    let sync: SyncRunner

    /// Tracks which user id the local stores currently hold data for,
    /// so we can detect "different user just signed in" vs. "session
    /// restored / same user" and only wipe when needed.
    private var lastSeenUserID: String?
    private var authObservation: AnyCancellable?

    init() {
        let config = AppConfig()
        let database: Database
        do {
            database = try Database()
        } catch {
            fatalError("Database open failed: \(error)")
        }
        // The closure-capture chain below makes the AuthSession
        // discoverable from every service without each one holding
        // a direct reference — we just hand them a `() -> AuthSession?`.
        // That keeps the wiring shallow and avoids retain cycles.
        let auth = AuthSession(endpointProvider: { config.endpointURL })

        let store = LocalSampleStore(database: database)
        let excursions = LocalExcursionStore(database: database)
        let hydrator = ExcursionsHydrator(
            store: excursions,
            endpointProvider: { config.endpointURL },
            authProvider: { [weak auth] in auth }
        )
        let localitiesStore = LocalLocalityStore(database: database)
        let localitiesHydrator = LocalitiesHydrator(
            store: localitiesStore,
            endpointProvider: { config.endpointURL },
            authProvider: { [weak auth] in auth }
        )
        let samplesHydrator = SamplesHydrator(
            store: store,
            endpointProvider: { config.endpointURL },
            authProvider: { [weak auth] in auth }
        )
        let sync = SyncRunner(
            store: store,
            endpointProvider: { config.endpointURL },
            authProvider: { [weak auth] in auth },
            onSampleSynced: { excursionID in
                Task { await hydrator.pullOne(excursionID) }
            }
        )

        self.config = config
        self.auth = auth
        self.database = database
        self.store = store
        self.excursions = excursions
        self.hydrator = hydrator
        self.localitiesStore = localitiesStore
        self.localitiesHydrator = localitiesHydrator
        self.samplesHydrator = samplesHydrator
        self.sync = sync
    }

    /// Run once at app start: restore the auth session if there's a
    /// Keychain-stored token, then react to login/logout. The
    /// Combine subscription stays alive for the lifetime of the
    /// container — it's our hook for "user changed → wipe + re-hydrate".
    func bootstrap() async {
        startObservingAuth()
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
            try excursions.reset()
            try localitiesStore.reset()
        } catch {
            // Wipe failures are non-fatal — the worst case is the new
            // user sees stale rows the rule filter wouldn't have
            // returned anyway. Logging would land here once we add a
            // unified logger.
        }
    }

    private func hydrateAll() async {
        // Fire all three pulls concurrently. Each hydrator is internally
        // single-flight, so a tab .task that also kicks pull() while
        // this is running just no-ops.
        async let s: Void = samplesHydrator.pull()
        async let e: Void = hydrator.pull()
        async let l: Void = localitiesHydrator.pull()
        _ = await (s, e, l)
    }
}

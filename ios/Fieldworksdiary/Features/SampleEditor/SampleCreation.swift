import FieldworksGeo
import Foundation

/// Steps after inserting a field sample, shared by the instant creation
/// on the home screen (Phase E) and the editor's create path: offline
/// locality fusion and place resolution.
@MainActor
enum SampleCreation {
    /// Runs the trivial offline fusion (R6.3) against the local
    /// localities. A hit re-uses that locality; a miss creates a new
    /// local one and enqueues its `.locality/.create` mutation so the
    /// SyncRunner pushes it (dispatched before the sample). Either way
    /// the sample is re-pointed at the resulting locality id.
    static func attachFusedLocality(
        sampleID: String,
        latitude: Double,
        longitude: Double,
        store: LocalSampleStore,
        localitiesStore: LocalLocalityStore,
        mutationsStore: PendingMutationsStore
    ) throws {
        let candidates: [LocalityFusion.Candidate] = ((try? localitiesStore.fetchAll()) ?? [])
            .compactMap { loc in
                guard let lat = loc.latitude ?? loc.centroidLat,
                      let lon = loc.longitude ?? loc.centroidLon else { return nil }
                return LocalityFusion.Candidate(id: loc.id, latitude: lat, longitude: lon)
            }

        let localityID: String
        if let match = LocalityFusion.offlineFuseLocality(
            sampleLatitude: latitude,
            sampleLongitude: longitude,
            candidates: candidates
        ) {
            localityID = match.id
        } else {
            let newLocal = try localitiesStore.createLocal(
                latitude: latitude,
                longitude: longitude,
                locationSource: .locationService
            )
            _ = try mutationsStore.enqueue(
                entityType: .locality,
                entityId: newLocal.id,
                op: .create,
                payload: Data()
            )
            localityID = newLocal.id
        }

        guard var working = try store.fetchById(sampleID) else { return }
        working.locality = localityID
        try store.update(working)
    }

    /// Runs after the sample is persisted, so Ortus can never block or
    /// fail the save. Online → Ortus fills place/features/MTB right
    /// away; otherwise the place is inherited from the previous sample
    /// of the collecting day. The sync is kicked afterwards; a sample
    /// that is already pushed gets the place data as an update. The
    /// task doesn't depend on any view: it finishes even if the editor
    /// is dismissed meanwhile.
    static func resolvePlaceThenSync(
        sampleID: String,
        resolver: SampleLocationResolver?,
        sync: SyncRunner,
        completion: (@MainActor () -> Void)? = nil
    ) {
        guard let resolver else {
            sync.kick()
            completion?()
            return
        }
        Task { @MainActor in
            let resolved = await resolver.resolveOnline(sampleID: sampleID)
            if !resolved {
                do {
                    try resolver.inheritOffline(sampleID: sampleID)
                } catch {
                    Log.persistence.error("offline place inheritance failed: \(error.localizedDescription)")
                }
            }
            sync.kick()
            completion?()
        }
    }
}

extension SampleCreation {
    /// A late fix from `PendingFixService` landed on an instantly
    /// created sample: same pipeline as a sample created with a fix —
    /// offline locality fusion, then place resolution (online, else
    /// inherited offline) and a sync kick.
    static func completeLateFix(
        sampleID: String,
        store: LocalSampleStore,
        localitiesStore: LocalLocalityStore,
        mutationsStore: PendingMutationsStore,
        resolver: SampleLocationResolver?,
        sync: SyncRunner,
        completion: (@MainActor () -> Void)? = nil
    ) {
        if let sample = try? store.fetchById(sampleID),
           let lat = sample.latitude, let lon = sample.longitude,
           (sample.locality ?? "").isEmpty
        {
            do {
                try attachFusedLocality(
                    sampleID: sampleID, latitude: lat, longitude: lon,
                    store: store, localitiesStore: localitiesStore, mutationsStore: mutationsStore
                )
            } catch {
                Log.persistence.error("locality fusion after late fix failed: \(error.localizedDescription)")
            }
        }
        resolvePlaceThenSync(sampleID: sampleID, resolver: resolver, sync: sync, completion: completion)
    }
}

/// „Sample anlegen“ in field mode (Phase E): inserts the sample right
/// away — before the editor opens — with the Phase Z id suggestion,
/// time window, zone and collecting day, queues its create and kicks
/// the sync. A fix CoreLocation already holds is used; otherwise the
/// sample starts without coordinate and `PendingFixService` fills it.
@MainActor
struct InstantSampleCreator {
    struct Created: Hashable, Identifiable {
        /// Local sample id.
        let id: String
        /// Running number of the suggested id, if the format has `<n>`.
        /// The counter is advanced only when the editor saves the
        /// suggestion unchanged.
        let suggestedRunning: Int?
    }

    let store: LocalSampleStore
    let localitiesStore: LocalLocalityStore
    let mutationsStore: PendingMutationsStore
    let sync: SyncRunner
    /// nil in tests that don't care about the background fix.
    let pendingFixes: PendingFixService?
    /// nil skips place resolution (tests).
    let locationResolver: SampleLocationResolver?
    /// A usable fix already available at tap time, or nil.
    let currentFix: @MainActor () -> LocationProvider.Fix?

    func create(now: Date = Date()) throws -> Created {
        let suggestion = store.peekSuggestion(for: now)
        let fix = currentFix()
        // The suggestion is stored verbatim so the running counter stays
        // untouched until the user kept it (see `Created.suggestedRunning`).
        let sample = try store.createLocal(
            lat: fix?.latitude,
            lon: fix?.longitude,
            accuracy: fix?.horizontalAccuracy,
            verticalAccuracy: fix?.verticalAccuracy,
            elevation: fix?.elevation,
            collectedFrom: now,
            overrideCode: suggestion.id,
            locationSource: .locationService
        )
        if let fix {
            do {
                try SampleCreation.attachFusedLocality(
                    sampleID: sample.id,
                    latitude: fix.latitude,
                    longitude: fix.longitude,
                    store: store,
                    localitiesStore: localitiesStore,
                    mutationsStore: mutationsStore
                )
            } catch {
                Log.persistence.error("locality fusion failed: \(error.localizedDescription)")
            }
        }
        do {
            _ = try mutationsStore.enqueue(
                entityType: .sample,
                entityId: sample.id,
                op: .create,
                payload: Data()
            )
        } catch {
            // The row is pending; the SyncRunner's legacy reconcile
            // queues its create on the next pass.
            Log.sync.error("create enqueue failed: \(error.localizedDescription)")
        }
        // Push as early as possible; place data follows as an update.
        sync.kick()
        if fix != nil {
            SampleCreation.resolvePlaceThenSync(sampleID: sample.id, resolver: locationResolver, sync: sync)
        } else {
            pendingFixes?.register(sampleID: sample.id, createdAt: sample.createdAt)
        }
        Log.persistence.info("sample \(sample.id, privacy: .public) created instantly, fix: \(fix != nil, privacy: .public)")
        return Created(id: sample.id, suggestedRunning: suggestion.running)
    }
}

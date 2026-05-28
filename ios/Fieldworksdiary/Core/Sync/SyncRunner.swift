import Foundation

/// Payload-Bundle für `SamplePushClient.createSample`. Spiegelt die
/// Felder des PocketBase-Sample-Records, die der Client beim Push
/// schickt — `client_uuid` und `client_updated_at` sind Teil des
/// Idempotenz-Vertrags (siehe Konfliktauflösung in CLAUDE.md).
struct SampleCreateInput {
    var lat: Double
    var lon: Double
    var accuracy: Double?
    var altitude: Double?
    var collectedFrom: Date
    var notes: String?
    var marked: Bool
    var code: String?
    var clientUuid: String?
    var clientUpdatedAt: Date?
}

/// Schnittstelle, gegen die `SyncRunner` testet. Produktiv konformt
/// `SampleClient`; in Tests reicht ein Mock, der nur diese zwei
/// Methoden implementiert (siehe `SyncRunnerTests`).
protocol SamplePushClient {
    func createSample(_ input: SampleCreateInput) async throws -> Sample
    func fetchSample(id: String) async throws -> Sample
}

extension SampleClient: SamplePushClient {}

/// Pushes pending local samples up to PocketBase, driven by the
/// `pending_mutations` outbox (R5b).
///
/// Push contract (Phase 3b, R3, R5):
///   - Wire body uses Spec-aligned names (sample_id, latitude,
///     longitude, begin_date, version, …).
///   - Server honors `sample_id` if it doesn't collide. On
///     collision the server reassigns and stores our value in
///     `original_code` — the user-readable id on the tube remains
///     authoritative.
///   - On any push success we set `syncStatus = .synced` on the
///     local row, copy backend_id / fieldtrip / locality /
///     enrichment, dequeue the outbox row, and (best-effort) push
///     photos + poll enrichment.
///
/// Retry: every 30 s a background tick re-runs the pass if anything
/// is still in the outbox. `kick()` also runs a pass on demand
/// (e.g. after a new local insert).
@MainActor
final class SyncRunner: ObservableObject {
    let store: LocalSampleStore
    let mutationsStore: PendingMutationsStore
    let photoStore: LocalPhotoStore?
    /// Optional — only wired when the app supports client-created
    /// localities (R8d offline-fusion). Nil in the sample-only tests.
    let localitiesStore: LocalLocalityStore?
    let endpointProvider: () -> String
    let authProvider: () -> AuthSession?
    let onSampleSynced: (String) -> Void
    /// Called after a `.locality/.create` mutation reconciled a
    /// client locality to its backend id, so the container can
    /// re-hydrate the survivor's server-side fields.
    let onLocalityChanged: () -> Void
    /// Factory für den HTTP-Client. Produktiv konstruiert das jedes
    /// Mal ein frisches `SampleClient` mit dem aktuellen Endpoint;
    /// Tests injizieren einen Mock.
    let clientFactory: (_ endpoint: String, _ auth: AuthSession?) -> SamplePushClient
    /// Factory für den Locality-Push-Client (R8d). Analog zu
    /// `clientFactory`; Tests injizieren einen Mock.
    let localityClientFactory: (_ endpoint: String, _ auth: AuthSession?) -> LocalityPushClient

    @Published private(set) var inFlight = 0

    private var passTask: Task<Void, Never>?
    private var retryTimer: Task<Void, Never>?

    /// Time between automatic retry passes when the outbox isn't
    /// empty. Bumped to 5 s in tests.
    private let retryInterval: Duration
    /// Wartezeit zwischen Enrichment-Polls. 1.5 s in Prod, in Tests
    /// auf 0 setzbar, damit `pollEnrichment` nicht künstlich blockt.
    private let enrichmentPollInterval: Duration

    init(store: LocalSampleStore,
         mutationsStore: PendingMutationsStore,
         photoStore: LocalPhotoStore? = nil,
         localitiesStore: LocalLocalityStore? = nil,
         endpointProvider: @escaping () -> String,
         authProvider: @escaping () -> AuthSession? = { nil },
         retryInterval: Duration = .seconds(30),
         enrichmentPollInterval: Duration = .seconds(1.5),
         clientFactory: @escaping (_ endpoint: String, _ auth: AuthSession?) -> SamplePushClient = { SampleClient(endpoint: $0, auth: $1) },
         localityClientFactory: @escaping (_ endpoint: String, _ auth: AuthSession?) -> LocalityPushClient = { LocalityClient(
             endpoint: $0,
             auth: $1
         ) },
         onSampleSynced: @escaping (String) -> Void = { _ in },
         onLocalityChanged: @escaping () -> Void = {})
    {
        self.store = store
        self.mutationsStore = mutationsStore
        self.photoStore = photoStore
        self.localitiesStore = localitiesStore
        self.endpointProvider = endpointProvider
        self.authProvider = authProvider
        self.retryInterval = retryInterval
        self.enrichmentPollInterval = enrichmentPollInterval
        self.clientFactory = clientFactory
        self.localityClientFactory = localityClientFactory
        self.onSampleSynced = onSampleSynced
        self.onLocalityChanged = onLocalityChanged
        startRetryLoop()
    }

    deinit { retryTimer?.cancel() }

    /// Schedule a push pass. Coalesces if one is already running.
    func kick() {
        if passTask != nil { return }
        passTask = Task { [weak self] in
            await self?.runPass()
            await MainActor.run { self?.passTask = nil }
        }
    }

    private func startRetryLoop() {
        retryTimer?.cancel()
        retryTimer = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                try? await Task.sleep(for: self.retryInterval)
                if Task.isCancelled { return }
                if let count = try? self.mutationsStore.count(), count > 0 {
                    self.kick()
                }
            }
        }
    }

    private func runPass() async {
        let endpoint = endpointProvider().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !endpoint.isEmpty else { return }

        // Bring any legacy `.pending`/`.failed` rows into the outbox
        // before we read from it. Idempotent — re-adoption skips rows
        // that are already represented.
        reconcileLegacyPending()

        let mutations: [PendingMutation]
        do {
            mutations = try mutationsStore.fetchAllOrdered()
        } catch {
            Log.sync.error("outbox fetch failed: \(error.localizedDescription)")
            return
        }
        if mutations.isEmpty { return }

        let client = clientFactory(endpoint, authProvider())
        for mutation in mutations {
            await execute(mutation, via: client)
        }
    }

    /// Dispatch by (entityType, op). Today only Sample-Create is
    /// wired; other ops still flow through their direct-from-UI
    /// PATCH clients and won't show up in the outbox.
    private func execute(_ mutation: PendingMutation, via client: SamplePushClient) async {
        switch (mutation.entityType, mutation.op) {
        case (.sample, .create):
            await executeSampleCreate(mutation, via: client)
        case (.locality, .create):
            await executeLocalityCreate(mutation)
        default:
            // Unsupported op — record once so the row isn't silently
            // stuck forever, but don't burn the queue on it.
            let err = "unsupported mutation: \(mutation.entityType.rawValue)/\(mutation.op.rawValue)"
            Log.sync.error("\(err)")
            try? mutationsStore.recordFailure(mutation.id, error: err)
        }
    }

    private func executeSampleCreate(_ mutation: PendingMutation, via client: SamplePushClient) async {
        // For create-mutations we store the LocalSample uuid as
        // `entity_id` (see LocalSampleStore.createLocal). If the
        // local row has vanished (manual reset, account switch),
        // the mutation is garbage — dequeue silently.
        guard let localId = mutation.entityId,
              let sample = try? store.fetchById(localId)
        else {
            try? mutationsStore.dequeue(mutation.id)
            return
        }

        var working = sample
        working.syncStatus = .syncing
        working.syncError = nil
        try? store.update(working)

        do {
            inFlight += 1
            defer { inFlight -= 1 }

            let created = try await client.createSample(SampleCreateInput(
                lat: sample.latitude ?? 0,
                lon: sample.longitude ?? 0,
                accuracy: sample.horizontalAccuracy,
                altitude: sample.altitude,
                collectedFrom: sample.beginDate,
                notes: sample.notes.isEmpty ? nil : sample.notes,
                marked: sample.marked,
                code: sample.sampleID,
                clientUuid: sample.id,
                clientUpdatedAt: sample.updatedAt
            ))

            working.backendId = created.id
            working.fieldtrip = created.fieldtrip
            working.locality = created.locality
            working.version = created.version
            working.adminUnitsLocality = created.adminUnits?.locality
            working.adminUnitsCountry = created.adminUnits?.country
            working.mtbSheetNumber = created.mtb?.sheetNumber
            working.mtbSheetName = created.mtb?.sheetName

            if created.sampleID != sample.sampleID {
                // Server reassigned on conflict. The original is what
                // the user wrote on the tube; the server's reassigned
                // id is the authoritative database value.
                working.backendCode = created.sampleID
                working.originalCode = created.originalCode ?? sample.sampleID
            } else {
                working.backendCode = nil
                // Server honored — but it might still return
                // original_code from a prior conflict round. Keep
                // whatever the server has.
                working.originalCode = created.originalCode
            }

            working.syncStatus = .synced
            try store.update(working)

            // Persisted on the server — remove from outbox.
            try? mutationsStore.dequeue(mutation.id)

            // Hand off the parent fieldtrip id to the container so
            // the fieldtrip-side hydration runs in parallel.
            onSampleSynced(created.fieldtrip)

            // Push any photos that were captured for this sample
            // before the sync round-trip. We have the backend id now,
            // so each photo gets its own multipart POST.
            await pushPhotos(for: working, backendSampleID: created.id, endpoint: endpointProvider())

            await pollEnrichment(id: created.id, sample: working, via: client)
        } catch {
            working.syncStatus = .failed
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            working.syncError = message
            try? store.update(working)
            try? mutationsStore.recordFailure(mutation.id, error: message)
            Log.sync.error("sample push failed: \(message)")
        }
    }

    /// Pushes a client-created locality (R8d offline-fusion). The
    /// local row carries a UUID id; on success we insert the backend
    /// row, re-point every local sample from the UUID onto the
    /// backend id (reusing `applyRemap`), and drop the UUID row. The
    /// server-side fusion hook (R6.1) may merge this locality into an
    /// existing one afterwards — that's reconciled later via the
    /// remap-event stream.
    private func executeLocalityCreate(_ mutation: PendingMutation) async {
        guard let localitiesStore,
              let localId = mutation.entityId,
              let local = try? localitiesStore.fetchById(localId)
        else {
            // No store wired or the local row vanished — the mutation
            // is garbage, drop it.
            try? mutationsStore.dequeue(mutation.id)
            return
        }

        let endpoint = endpointProvider().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !endpoint.isEmpty else { return }
        let client = localityClientFactory(endpoint, authProvider())

        do {
            inFlight += 1
            defer { inFlight -= 1 }

            let created = try await client.create(LocalityInput(
                name: local.name,
                latitude: local.latitude ?? local.centroidLat ?? 0,
                longitude: local.longitude ?? local.centroidLon ?? 0,
                radiusM: local.radiusM ?? LocalityFusion.defaultRadiusM,
                notes: local.notes,
                locationSource: LocationSource(rawValue: local.locationSource) ?? .locationService,
                version: local.version,
                clientUuid: local.clientUuid ?? local.id,
                clientUpdatedAt: local.clientUpdatedAt
            ))

            // Reconcile UUID → backend id: insert the backend row,
            // re-point samples, delete the UUID row.
            try localitiesStore.upsertOne(created)
            try localitiesStore.applyRemap(oldID: local.id, newID: created.id)
            try? mutationsStore.dequeue(mutation.id)
            onLocalityChanged()
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            try? mutationsStore.recordFailure(mutation.id, error: message)
            Log.sync.error("locality push failed: \(message)")
        }
    }

    /// Adopts any `local_samples` rows that still sit with
    /// `syncStatus == .pending` or `.failed` but don't yet have a
    /// matching outbox entry. Runs at the start of every pass —
    /// it's a SELECT plus a small Set diff, the cost is negligible
    /// against the network round-trip that follows.
    private func reconcileLegacyPending() {
        let pending: [LocalSample]
        do {
            pending = try store.fetchPending()
        } catch {
            Log.sync.error("legacy fetchPending failed: \(error.localizedDescription)")
            return
        }
        if pending.isEmpty { return }
        let outboxed: Set<String>
        do {
            outboxed = try Set(mutationsStore.fetch(entityType: .sample)
                .filter { $0.op == .create }
                .compactMap(\.entityId))
        } catch {
            Log.sync.error("outbox scan failed: \(error.localizedDescription)")
            return
        }
        for sample in pending where !outboxed.contains(sample.id) {
            do {
                _ = try mutationsStore.enqueue(
                    entityType: .sample,
                    entityId: sample.id,
                    op: .create,
                    payload: Data()
                )
            } catch {
                Log.sync.error("legacy enqueue failed: \(error.localizedDescription)")
            }
        }
    }

    /// Uploads every pending photo for `sample` to the backend. Each
    /// photo is its own multipart POST; we mark them `.synced`
    /// individually so a partial network failure leaves the rest as
    /// `.failed` for the retry loop. Idempotency is via the per-photo
    /// `client_uuid` — re-uploading the same photo doesn't duplicate.
    private func pushPhotos(for sample: LocalSample, backendSampleID: String, endpoint: String) async {
        guard let photoStore else { return }
        let pending: [LocalPhoto]
        do {
            pending = try photoStore.fetchBySample(sample.id)
                .filter { $0.syncStatus == .pending || $0.syncStatus == .failed }
        } catch {
            Log.sync.error("photo fetch failed: \(error.localizedDescription)")
            return
        }
        if pending.isEmpty { return }

        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let client = PhotoClient(endpoint: trimmed, auth: authProvider())

        for photo in pending {
            await pushOnePhoto(photo, backendSampleID: backendSampleID, via: client)
        }
    }

    private func pushOnePhoto(_ photo: LocalPhoto, backendSampleID: String, via client: PhotoClient) async {
        guard let photoStore else { return }
        var working = photo
        working.syncStatus = .syncing
        working.syncError = nil
        try? photoStore.update(working)

        do {
            let data = try PhotoStorage.readData(relativePath: photo.localPath)
            let resp = try await client.upload(
                sampleBackendID: backendSampleID,
                clientUUID: photo.clientUuid,
                clientUpdatedAt: photo.clientUpdatedAt,
                jpegData: data
            )
            working.backendId = resp.id
            working.syncStatus = .synced
            try photoStore.update(working)
        } catch {
            working.syncStatus = .failed
            working.syncError = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            try? photoStore.update(working)
            Log.sync.error("photo push failed: \(working.syncError ?? "")")
        }
    }

    private func pollEnrichment(id: String, sample: LocalSample, via client: SamplePushClient) async {
        var working = sample
        for _ in 0 ..< 6 {
            try? await Task.sleep(for: enrichmentPollInterval)
            if let s = try? await client.fetchSample(id: id) {
                let locality = s.adminUnits?.locality
                let mtbSheet = s.mtb?.sheetNumber
                if locality != nil || mtbSheet != nil {
                    working.adminUnitsLocality = locality
                    working.adminUnitsCountry = s.adminUnits?.country
                    working.mtbSheetNumber = mtbSheet
                    working.mtbSheetName = s.mtb?.sheetName
                    try? store.update(working)
                    return
                }
            }
        }
    }
}

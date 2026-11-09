import Foundation

/// Coordinate, height and place data of a sample as pushed to the
/// server (Phase O2). Shared by create and update so both send the
/// same set. `nil` means "not sent" — the client never blanks a server
/// value it does not know better.
///
/// `placemark` / `placemarkSuggestion` / `locality` are backend ids;
/// the SyncRunner resolves local placemark UUIDs before building this.
struct SampleLocationFields: Codable, Equatable {
    var latitude: Double?
    var longitude: Double?
    var horizontalAccuracy: Double?
    var verticalAccuracy: Double?
    var elevation: Double?
    var elevationSource: ElevationSource?
    var locationSource: LocationSource
    var locationStatus: LocationStatus
    var placemark: String?
    var placemarkSuggestion: String?
    var locality: String?
    var mtbSheetNumber: String?
    var mtbSheetName: String?
    var mtbQuadrant: Int?
    var elevationDEM: Double?
    var elevationDEMAccuracy: Double?
    var slopeDeg: Double?
    var aspectDeg: Double?
    var aspectCompass: String?
    var terrainFlat: Bool = false
    var bearingLabel: String?
    var bearingReference: String?
    var bearingDistanceKm: Double?
    var bearingCompass: String?
    var bearingInside: Bool = false

    /// Wire keys of the PocketBase `samples` record (migration
    /// 1700000024). `elevation_source` always accompanies an
    /// elevation (a height without stored source counts as GPS, as
    /// the backend's create hook does); `location_status` and
    /// `location_source` are always sent.
    var wireBody: [String: Any] {
        var body: [String: Any] = [
            "location_source": locationSource.wireValue,
            "location_status": locationStatus.rawValue
        ]
        if let latitude { body["latitude"] = latitude }
        if let longitude { body["longitude"] = longitude }
        if let horizontalAccuracy { body["horizontal_accuracy"] = horizontalAccuracy }
        if let verticalAccuracy { body["vertical_accuracy"] = verticalAccuracy }
        if let elevation {
            body["elevation"] = elevation
            body["elevation_source"] = (elevationSource ?? .locationService).rawValue
        }
        if let placemark, !placemark.isEmpty { body["placemark"] = placemark }
        if let placemarkSuggestion, !placemarkSuggestion.isEmpty {
            body["placemark_suggestion"] = placemarkSuggestion
        }
        if let locality, !locality.isEmpty { body["locality"] = locality }
        if let mtbSheetNumber { body["mtb_sheet_number"] = mtbSheetNumber }
        if let mtbSheetName { body["mtb_sheet_name"] = mtbSheetName }
        if let mtbQuadrant { body["mtb_quadrant"] = mtbQuadrant }
        if let elevationDEM { body["elevation_dem"] = elevationDEM }
        if let elevationDEMAccuracy { body["elevation_dem_accuracy"] = elevationDEMAccuracy }
        if let slopeDeg { body["slope_deg"] = slopeDeg }
        if let aspectDeg { body["aspect_deg"] = aspectDeg }
        if let aspectCompass { body["aspect_compass"] = aspectCompass }
        if let bearingLabel { body["bearing_label"] = bearingLabel }
        if let bearingReference { body["bearing_reference"] = bearingReference }
        if let bearingDistanceKm { body["bearing_distance_km"] = bearingDistanceKm }
        if let bearingCompass { body["bearing_compass"] = bearingCompass }
        // Booleans only travel with the geo set they belong to, so a
        // never-enriched sample doesn't push `false` over server data.
        if aspectCompass != nil || slopeDeg != nil || elevationDEM != nil || terrainFlat {
            body["terrain_flat"] = terrainFlat
        }
        if bearingLabel != nil || bearingInside {
            body["bearing_inside"] = bearingInside
        }
        return body
    }
}

extension SampleLocationFields {
    /// Location fields of a local row, with placemark references
    /// already translated to backend ids by the caller.
    init(_ s: LocalSample, placemark: String?, placemarkSuggestion: String?, locality: String?) {
        latitude = s.latitude
        longitude = s.longitude
        horizontalAccuracy = s.horizontalAccuracy
        verticalAccuracy = s.verticalAccuracy
        elevation = s.elevation
        elevationSource = s.elevation == nil ? nil : (s.elevationSource ?? .locationService)
        locationSource = LocationSource(rawValue: s.locationSource) ?? .user
        locationStatus = s.locationStatus
        self.placemark = placemark
        self.placemarkSuggestion = placemarkSuggestion
        self.locality = locality
        mtbSheetNumber = s.mtbSheetNumber
        mtbSheetName = s.mtbSheetName
        mtbQuadrant = s.mtbQuadrant
        elevationDEM = s.elevationDEM
        elevationDEMAccuracy = s.elevationDEMAccuracy
        slopeDeg = s.slopeDeg
        aspectDeg = s.aspectDeg
        aspectCompass = s.aspectCompass
        terrainFlat = s.terrainFlat
        bearingLabel = s.bearingLabel
        bearingReference = s.bearingReference
        bearingDistanceKm = s.bearingDistanceKm
        bearingCompass = s.bearingCompass
        bearingInside = s.bearingInside
    }
}

/// Payload-Bundle für `SamplePushClient.createSample`. Spiegelt die
/// Felder des PocketBase-Sample-Records, die der Client beim Push
/// schickt — `client_uuid` und `client_updated_at` sind Teil des
/// Idempotenz-Vertrags (siehe Konfliktauflösung in CLAUDE.md).
struct SampleCreateInput: Equatable {
    var location: SampleLocationFields
    var collectedFrom: Date
    var notes: String?
    var marked: Bool
    var code: String?
    var clientUuid: String?
    var clientUpdatedAt: Date?
}

/// Payload-Bundle für `SamplePushClient.updateSample`: user-editierbare
/// Felder (Code, Notiz), Koordinate/Höhe/Ortsdaten/Status (Phase O2)
/// plus Idempotenz/Versions-Trio.
///
/// `Codable`, damit der Snapshot bei Bedarf als JSON persistiert
/// werden kann.
struct SampleUpdateInput: Codable, Equatable {
    var code: String
    var notes: String?
    var clientUuid: String
    var clientUpdatedAt: Date
    var version: Int
    var location: SampleLocationFields
}

/// Payload of a `.sample/.update` outbox row. Older rows carry an
/// empty payload, which decodes to the defaults.
struct SampleUpdatePayload: Codable, Equatable {
    /// The local feature set changed (on-device resolver) or a previous
    /// features PUT failed: replace the server's set after the PATCH.
    var pushFeatures = false

    static func decode(_ data: Data) -> SampleUpdatePayload {
        (try? JSONDecoder().decode(SampleUpdatePayload.self, from: data)) ?? SampleUpdatePayload()
    }

    var encoded: Data {
        (try? JSONEncoder().encode(self)) ?? Data()
    }
}

/// Schnittstelle, gegen die `SyncRunner` testet. Produktiv konformt
/// `SampleClient`; in Tests reicht ein Mock, der nur diese drei
/// Methoden implementiert (siehe `SyncRunnerTests`).
protocol SamplePushClient {
    func createSample(_ input: SampleCreateInput) async throws -> Sample
    func updateSample(id: String, input: SampleUpdateInput) async throws -> Sample
    func fetchSample(id: String) async throws -> Sample
}

extension SampleClient: SamplePushClient {}

/// Pushes pending local samples up to PocketBase, driven by the
/// `pending_mutations` outbox (R5b).
///
/// Push contract (Phase 3b, R3, R5, O2):
///   - Wire body uses Spec-aligned names (sample_id, latitude,
///     longitude, begin_date, elevation, location_status, …).
///   - Server honors `sample_id` if it doesn't collide. On
///     collision the server reassigns and stores our value in
///     `original_code` — the user-readable id on the tube remains
///     authoritative.
///   - Order per sample (create and update): placemark → sample →
///     features. A locally created placemark (UUID id) is first looked
///     up or created on the server via `POST /api/placemarks/resolve`
///     and only its backend id is ever sent as `placemark`.
///   - The SyncRunner never writes a row copy read before a network
///     call back over the whole row: after every call it re-reads the
///     row and merges only server-derived fields (backend id, version,
///     fieldtrip, codes, enrichment where local has nothing better —
///     see `LocalSample.mergeServerLocation`). Local edits made during
///     the call win; if they missed the create POST, an update is
///     queued.
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
    /// Optional (Phase O2): placemark rows referenced by samples. Nil
    /// in sample-only tests; then only plain backend ids are sent.
    let placemarkStore: LocalPlacemarkStore?
    /// Optional (Phase O2): Ortus features per sample. Nil ⇒ no
    /// features push / hydration.
    let featureStore: LocalSampleFeatureStore?
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
    /// Phase O2: placemark resolve/fetch and features replace/fetch.
    let placemarkClientFactory: (_ endpoint: String, _ auth: AuthSession?) -> PlacemarkSyncClient
    let featuresClientFactory: (_ endpoint: String, _ auth: AuthSession?) -> SampleFeaturesSyncClient

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
         placemarkStore: LocalPlacemarkStore? = nil,
         featureStore: LocalSampleFeatureStore? = nil,
         endpointProvider: @escaping () -> String,
         authProvider: @escaping () -> AuthSession? = { nil },
         retryInterval: Duration = .seconds(30),
         enrichmentPollInterval: Duration = .seconds(1.5),
         clientFactory: @escaping (_ endpoint: String, _ auth: AuthSession?) -> SamplePushClient = { SampleClient(endpoint: $0, auth: $1) },
         localityClientFactory: @escaping (_ endpoint: String, _ auth: AuthSession?) -> LocalityPushClient = { LocalityClient(
             endpoint: $0,
             auth: $1
         ) },
         placemarkClientFactory: @escaping (_ endpoint: String, _ auth: AuthSession?) -> PlacemarkSyncClient = {
             PlacemarkClient(endpoint: $0, auth: $1)
         },
         featuresClientFactory: @escaping (_ endpoint: String, _ auth: AuthSession?) -> SampleFeaturesSyncClient = {
             SampleFeaturesClient(endpoint: $0, auth: $1)
         },
         onSampleSynced: @escaping (String) -> Void = { _ in },
         onLocalityChanged: @escaping () -> Void = {})
    {
        self.store = store
        self.mutationsStore = mutationsStore
        self.photoStore = photoStore
        self.localitiesStore = localitiesStore
        self.placemarkStore = placemarkStore
        self.featureStore = featureStore
        self.endpointProvider = endpointProvider
        self.authProvider = authProvider
        self.retryInterval = retryInterval
        self.enrichmentPollInterval = enrichmentPollInterval
        self.clientFactory = clientFactory
        self.localityClientFactory = localityClientFactory
        self.placemarkClientFactory = placemarkClientFactory
        self.featuresClientFactory = featuresClientFactory
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

    /// Dispatch by (entityType, op). Sample create/update + locality
    /// create are wired through the outbox; star-toggles still flow
    /// through their direct-from-UI PATCH client (setMarked) and don't
    /// show up here.
    private func execute(_ mutation: PendingMutation, via client: SamplePushClient) async {
        switch (mutation.entityType, mutation.op) {
        case (.sample, .create):
            await executeSampleCreate(mutation, via: client)
        case (.sample, .update):
            await executeSampleUpdate(mutation, via: client)
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

        if let existing = sample.backendId, !existing.isEmpty {
            // Already on the server (e.g. a failed update row adopted
            // by `reconcileLegacyPending`): a second POST would
            // duplicate it — push the row as an update instead.
            _ = try? mutationsStore.enqueue(
                entityType: .sample, entityId: localId, op: .update,
                payload: SampleUpdatePayload(pushFeatures: true).encoded
            )
            try? mutationsStore.dequeue(mutation.id)
            return
        }

        try? store.setSyncState(id: localId, status: .syncing, error: nil)

        do {
            inFlight += 1
            defer { inFlight -= 1 }

            // 1. Placemarks first (backend ids), then the input is
            //    built from the row as it is *after* those calls.
            guard let pushed = try await pushLocation(forLocalID: localId) else {
                try? mutationsStore.dequeue(mutation.id)
                return
            }
            let (current, location) = pushed
            let input = Self.createInput(current, location: location)

            // 2. The sample itself.
            let created = try await client.createSample(input)

            // 3. Merge server-derived fields onto the row as it is now.
            guard var fresh = try store.fetchById(localId) else {
                try? mutationsStore.dequeue(mutation.id)
                return
            }
            fresh.backendId = created.id
            fresh.fieldtrip = created.fieldtrip
            // An empty server locality must not wipe a local one.
            fresh.locality = created.locality ?? fresh.locality
            fresh.version = created.version
            Self.applyCodes(created, sentCode: input.code ?? fresh.sampleID, to: &fresh)
            fresh.mergeServerLocation(created, localPlacemarkID: localPlacemarkID)
            fresh.syncStatus = .synced
            fresh.syncError = nil
            try store.update(fresh)

            // Persisted on the server — remove from outbox.
            try? mutationsStore.dequeue(mutation.id)

            // Edits that landed while the POST was in flight (user, or
            // the on-device resolver — it couldn't queue an update yet
            // because the row had no backend id) are not on the
            // server: push them as an update.
            if Self.createInput(fresh, location: syncLocation(fresh)) != input {
                _ = try? mutationsStore.enqueue(
                    entityType: .sample, entityId: localId, op: .update,
                    payload: SampleUpdatePayload(pushFeatures: true).encoded
                )
            }

            // Hand off the parent fieldtrip id to the container so
            // the fieldtrip-side hydration runs in parallel.
            onSampleSynced(created.fieldtrip)

            // 4. Features (only when the device has some).
            if let featureStore, ((try? featureStore.count(sampleID: localId)) ?? 0) > 0 {
                if !(await pushFeatures(localID: localId, backendID: created.id)) {
                    _ = try? mutationsStore.enqueue(
                        entityType: .sample, entityId: localId, op: .update,
                        payload: SampleUpdatePayload(pushFeatures: true).encoded
                    )
                }
            }

            // Push any photos that were captured for this sample
            // before the sync round-trip. We have the backend id now,
            // so each photo gets its own multipart POST.
            await pushPhotos(for: fresh, backendSampleID: created.id, endpoint: endpointProvider())

            if location.locationStatus != .backendService {
                await pollEnrichment(backendID: created.id, localID: localId,
                                     baseVersion: created.version, via: client)
            }
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            try? store.setSyncState(id: localId, status: .failed, error: message)
            try? mutationsStore.recordFailure(mutation.id, error: message)
            Log.sync.error("sample push failed: \(message)")
        }
    }

    /// Pushes a user edit (code/notes) or a place-data change on a
    /// previously-synced sample.
    ///
    /// The outbox row carries the *local* sample id as `entityId`
    /// (same shape as `.sample/.create`) and a `SampleUpdatePayload`
    /// (empty for plain edits). The body is built fresh from the
    /// current local row right before the PATCH, so any edits that
    /// landed in the row between enqueue and execute are pushed
    /// automatically — no coalescing race. After the response we
    /// re-read the row again to avoid clobbering edits that landed
    /// during the network hop.
    ///
    /// Order: placemark resolve → PATCH → features PUT (when the
    /// payload asks for it).
    ///
    /// OCC: the backend's `enforceVersion` hook (versionedCollections
    /// in version_conflict.go) rejects `incoming <= current` with 409.
    /// We send `current + 1`; on 409 we surface the conflict as a
    /// `.failed` status with a localised error rather than silently
    /// dropping the user's edit.
    private func executeSampleUpdate(_ mutation: PendingMutation, via client: SamplePushClient) async {
        guard let localID = mutation.entityId, !localID.isEmpty else {
            try? mutationsStore.dequeue(mutation.id)
            return
        }

        let preLocal: LocalSample
        do {
            guard let row = try store.fetchById(localID) else {
                // Sample row vanished (reset / account switch) — mutation is moot.
                try? mutationsStore.dequeue(mutation.id)
                return
            }
            preLocal = row
        } catch {
            // Transient DB read error — keep the mutation in the
            // outbox and surface the failure so the next pass retries.
            let message = "local row read failed: \(error.localizedDescription)"
            Log.sync.error("\(message)")
            try? mutationsStore.recordFailure(mutation.id, error: message)
            return
        }

        guard let backendID = preLocal.backendId, !backendID.isEmpty else {
            // Create push hasn't landed yet — leave the mutation
            // queued; we'll come back next pass once create assigns a
            // backend id.
            return
        }

        let payload = SampleUpdatePayload.decode(mutation.payloadJson)
        try? store.setSyncState(id: localID, status: .syncing, error: nil)

        do {
            inFlight += 1
            defer { inFlight -= 1 }

            guard let pushed = try await pushLocation(forLocalID: localID) else {
                try? mutationsStore.dequeue(mutation.id)
                return
            }
            let (current, location) = pushed
            let input = SampleUpdateInput(
                code: current.sampleID,
                notes: current.notes,
                clientUuid: current.id,
                clientUpdatedAt: current.updatedAt,
                version: current.version + 1,
                location: location
            )

            let updated = try await client.updateSample(id: backendID, input: input)

            // Re-read after the network hop: the user may have saved
            // further edits during the await. Preserve user-owned
            // fields (notes, sampleID) and merge only the server-
            // derived ones in.
            var fresh = (try? store.fetchById(localID)) ?? current
            fresh.version = updated.version
            fresh.locality = updated.locality ?? fresh.locality
            Self.applyCodes(updated, sentCode: input.code, to: &fresh)
            fresh.mergeServerLocation(updated, localPlacemarkID: localPlacemarkID)
            fresh.syncStatus = .synced
            fresh.syncError = nil
            try store.update(fresh)

            if payload.pushFeatures, featureStore != nil,
               !(await pushFeatures(localID: localID, backendID: backendID))
            {
                // Sample is on the server; only the feature set is
                // missing. Keep the row queued — the retry re-PATCHes
                // (with the merged version) and re-PUTs.
                try? mutationsStore.recordFailure(mutation.id, error: "features push failed")
                return
            }
            try? mutationsStore.dequeue(mutation.id)

            // Pick up any photos that the edit added on top of an
            // already-synced sample (same best-effort semantics as
            // the create path).
            await pushPhotos(for: fresh, backendSampleID: backendID, endpoint: endpointProvider())
        } catch let SampleClientError.conflict(serverVersion, _) {
            // Another writer beat us to the row. We intentionally do
            // NOT overwrite local with the server's values — the
            // user's typed code/notes stay put so they can review,
            // retry, or discard. Just flip the row to .failed with
            // a localised error so listing/badge UI surfaces the
            // conflict instead of silently swallowing it.
            Log.sync.warning(
                "sample update 409 (server version \(serverVersion, privacy: .public))"
            )
            try? store.setSyncState(
                id: localID, status: .failed,
                error: "Konflikt: Probe wurde auf einem anderen Gerät geändert. Bitte neu laden."
            )
            try? mutationsStore.dequeue(mutation.id)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            try? store.setSyncState(id: localID, status: .failed, error: message)
            try? mutationsStore.recordFailure(mutation.id, error: message)
            Log.sync.error("sample update push failed: \(message)")
        }
    }

    // MARK: - Phase O2 place data

    /// Outcome of mapping a local placemark reference to the server.
    private enum PlacemarkRef: Equatable {
        case none
        case backend(String)
        /// Cannot be referenced on the server (no local row for a
        /// UUID, incomplete place, or the server rejected it).
        case unresolvable

        var backendID: String? {
            if case let .backend(id) = self { return id }
            return nil
        }
    }

    /// Resolves the row's placemark references to backend ids (network
    /// for locally created placemarks), then re-reads the row and
    /// builds the location fields from that fresh row. Retries when a
    /// reference changed during the calls. Nil when the row vanished.
    private func pushLocation(forLocalID id: String) async throws -> (LocalSample, SampleLocationFields)? {
        for _ in 0 ..< 3 {
            guard let row = try store.fetchById(id) else { return nil }
            let placemark = try await backendPlacemark(row.placemark)
            let suggestion = try await backendPlacemark(row.placemarkSuggestion)
            guard let fresh = try store.fetchById(id) else { return nil }
            if fresh.placemark == row.placemark, fresh.placemarkSuggestion == row.placemarkSuggestion {
                return (fresh, location(fresh, placemark: placemark, suggestion: suggestion))
            }
        }
        // References keep changing under us: send what is already
        // resolvable without the network; the editor's change queues
        // its own update.
        guard let fresh = try store.fetchById(id) else { return nil }
        return (fresh, syncLocation(fresh))
    }

    /// Location fields with placemark refs mapped without network
    /// calls (unknown ⇒ unresolvable). Used to detect edits that
    /// landed during a create POST.
    private func syncLocation(_ s: LocalSample) -> SampleLocationFields {
        location(s, placemark: knownBackendPlacemark(s.placemark),
                 suggestion: knownBackendPlacemark(s.placemarkSuggestion))
    }

    private func location(_ s: LocalSample, placemark: PlacemarkRef, suggestion: PlacemarkRef) -> SampleLocationFields {
        var fields = SampleLocationFields(
            s,
            placemark: placemark.backendID,
            placemarkSuggestion: suggestion.backendID,
            locality: pushableLocality(s.locality)
        )
        if placemark == .unresolvable, fields.locationStatus != .pending {
            // Without its placemark the status would lie; `pending`
            // lets the backend enrich the sample itself.
            fields.locationStatus = .pending
        }
        return fields
    }

    /// A locality id may only be sent once it is a backend id (a
    /// client-created locality's UUID is swapped by the locality
    /// push, which then queues a sample update).
    private func pushableLocality(_ id: String?) -> String? {
        guard let id, PlacemarkClient.isRecordID(id) else { return nil }
        return id
    }

    private func knownBackendPlacemark(_ localID: String?) -> PlacemarkRef {
        guard let localID, !localID.isEmpty else { return .none }
        guard let placemarkStore, let row = try? placemarkStore.fetchById(localID) else {
            return PlacemarkClient.isRecordID(localID) ? .backend(localID) : .unresolvable
        }
        if let backendID = row.backendId, !backendID.isEmpty { return .backend(backendID) }
        return .unresolvable
    }

    /// Backend id for a local placemark reference. A locally created
    /// row without `backend_id` is looked up or created on the server
    /// (`backend_service` rows shared, `manual` rows owned by the
    /// user) and the id is remembered on the row. Network/auth/5xx
    /// errors throw (the push retries); a 4xx rejection of the place
    /// itself yields `.unresolvable`, so the sample is not blocked.
    private func backendPlacemark(_ localID: String?) async throws -> PlacemarkRef {
        guard let localID, !localID.isEmpty else { return .none }
        guard let placemarkStore, let row = try placemarkStore.fetchById(localID) else {
            if PlacemarkClient.isRecordID(localID) { return .backend(localID) }
            Log.sync.warning("placemark \(localID, privacy: .public) unknown locally, not sent")
            return .unresolvable
        }
        if let backendID = row.backendId, !backendID.isEmpty { return .backend(backendID) }
        guard row.countryISO.count == 2 else {
            Log.sync.warning("placemark \(localID, privacy: .public) has no country, not sent")
            return .unresolvable
        }
        let endpoint = endpointProvider().trimmingCharacters(in: .whitespacesAndNewlines)
        let client = placemarkClientFactory(endpoint, authProvider())
        let source = Placemark.GeocodingSource(wire: row.geocodingSource)
        do {
            let remote = try await client.resolve(place: row.place, source: source)
            try placemarkStore.setBackend(localID: localID, backendID: remote.id, owner: remote.owner)
            Log.sync.info("placemark \(localID, privacy: .public) resolved to \(remote.id, privacy: .public)")
            return .backend(remote.id)
        } catch let SampleClientError.http(status, _) where status == 400 || status == 422 {
            Log.sync.warning("placemark \(localID, privacy: .public) rejected (\(status, privacy: .public)), not sent")
            return .unresolvable
        }
    }

    private func localPlacemarkID(_ backendID: String) -> String {
        ((try? placemarkStore?.localID(forBackendID: backendID)) ?? nil) ?? backendID
    }

    /// PUTs the complete local feature set of the sample. Returns
    /// false on any failure (logged).
    private func pushFeatures(localID: String, backendID: String) async -> Bool {
        guard let featureStore else { return true }
        let endpoint = endpointProvider().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !endpoint.isEmpty else { return false }
        let client = featuresClientFactory(endpoint, authProvider())
        do {
            let rows = try featureStore.all(sampleID: localID)
            try await client.replaceFeatures(sampleBackendID: backendID, features: rows)
            Log.sync.info("pushed \(rows.count, privacy: .public) features for sample \(backendID, privacy: .public)")
            return true
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            Log.sync.warning("features push failed for sample \(backendID, privacy: .public): \(message)")
            return false
        }
    }

    private func makeLocationHydration() -> SampleLocationHydration? {
        guard let placemarkStore, let featureStore else { return nil }
        let endpoint = endpointProvider().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !endpoint.isEmpty else { return nil }
        let auth = authProvider()
        return SampleLocationHydration(
            samples: store,
            placemarks: placemarkStore,
            features: featureStore,
            placemarkClient: placemarkClientFactory(endpoint, auth),
            featuresClient: featuresClientFactory(endpoint, auth)
        )
    }

    private func hasQueuedMutation(_ localID: String) -> Bool {
        ((try? mutationsStore.fetch(entityType: .sample)) ?? []).contains { $0.entityId == localID }
    }

    private static func createInput(_ s: LocalSample, location: SampleLocationFields) -> SampleCreateInput {
        SampleCreateInput(
            location: location,
            collectedFrom: s.beginDate,
            notes: s.notes.isEmpty ? nil : s.notes,
            marked: s.marked,
            code: s.sampleID,
            clientUuid: s.id,
            clientUpdatedAt: s.updatedAt
        )
    }

    /// Server reassigned on conflict → keep the tube label as
    /// `originalCode` and the server's id as `backendCode`.
    private static func applyCodes(_ remote: Sample, sentCode: String, to row: inout LocalSample) {
        if remote.sampleID != sentCode {
            row.backendCode = remote.sampleID
            row.originalCode = remote.originalCode ?? sentCode
        } else {
            row.backendCode = nil
            // Server honored — but it might still return
            // original_code from a prior conflict round.
            row.originalCode = remote.originalCode
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
            // re-point samples, delete the UUID row. Samples that were
            // already pushed went out without this locality (a local
            // UUID can't be referenced) — queue an update for them.
            let pushedSamples = ((try? store.fetchByLocality(local.id)) ?? [])
                .filter { !($0.backendId ?? "").isEmpty }
            try localitiesStore.upsertOne(created)
            try localitiesStore.applyRemap(oldID: local.id, newID: created.id)
            for sample in pushedSamples {
                _ = try? mutationsStore.enqueue(
                    entityType: .sample, entityId: sample.id, op: .update, payload: Data()
                )
            }
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

    /// Waits for the backend enrichment of a sample pushed without
    /// final place data (status ≠ backend_service). Done when the
    /// server reports `backend_service` or a newer version (the
    /// enricher bumps it). Merges onto a fresh row: the version always
    /// (so a queued local edit doesn't 409 against our own
    /// enrichment), place data only when no local edit is queued —
    /// then pulls placemark and features.
    private func pollEnrichment(backendID: String, localID: String, baseVersion: Int,
                                via client: SamplePushClient) async
    {
        for _ in 0 ..< 6 {
            try? await Task.sleep(for: enrichmentPollInterval)
            guard let s = try? await client.fetchSample(id: backendID) else { continue }
            guard s.locationStatus == .backendService || s.version > baseVersion else { continue }
            guard var fresh = try? store.fetchById(localID), fresh.backendId == backendID else { return }
            fresh.version = max(fresh.version, s.version)
            if !hasQueuedMutation(localID) {
                fresh.mergeServerLocation(s, localPlacemarkID: localPlacemarkID)
            }
            try? store.update(fresh)
            await makeLocationHydration()?.hydrate([s])
            return
        }
    }
}

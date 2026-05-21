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

/// Pushes pending local samples up to PocketBase.
///
/// Push contract (Phase 3b):
///   - We send `code`, `client_uuid`, `client_updated_at`.
///   - Server honors `code` if it doesn't collide with an existing
///     sample. On collision the server reassigns and stores our code
///     in `original_code` — the user-readable code on the tube
///     remains authoritative.
///   - On any push success we set `syncStatus=.synced` and copy
///     `backend_id`, `excursion`, and the enrichment fields from the
///     response. If the server reassigned, we record both `backendCode`
///     (the server-authoritative one) and keep `code` as the
///     local/tube value.
///
/// Retry: every 30 s a background tick re-runs the pass for any rows
/// still in `.pending` or `.failed`. kick() also runs a pass on
/// demand (e.g. after a new local insert).
@MainActor
final class SyncRunner: ObservableObject {
    let store: LocalSampleStore
    let photoStore: LocalPhotoStore?
    let endpointProvider: () -> String
    let authProvider: () -> AuthSession?
    let onSampleSynced: (String) -> Void
    /// Factory für den HTTP-Client. Produktiv konstruiert das jedes
    /// Mal ein frisches `SampleClient` mit dem aktuellen Endpoint;
    /// Tests injizieren einen Mock.
    let clientFactory: (_ endpoint: String, _ auth: AuthSession?) -> SamplePushClient

    @Published private(set) var inFlight = 0

    private var passTask: Task<Void, Never>?
    private var retryTimer: Task<Void, Never>?

    /// Time between automatic retry passes when there are pending or
    /// failed rows. Bumped to 5s in tests.
    private let retryInterval: Duration
    /// Wartezeit zwischen Enrichment-Polls. 1.5 s in Prod, in Tests
    /// auf 0 setzbar, damit `pollEnrichment` nicht künstlich blockt.
    private let enrichmentPollInterval: Duration

    init(store: LocalSampleStore,
         photoStore: LocalPhotoStore? = nil,
         endpointProvider: @escaping () -> String,
         authProvider: @escaping () -> AuthSession? = { nil },
         retryInterval: Duration = .seconds(30),
         enrichmentPollInterval: Duration = .seconds(1.5),
         clientFactory: @escaping (_ endpoint: String, _ auth: AuthSession?) -> SamplePushClient = { SampleClient(endpoint: $0, auth: $1) },
         onSampleSynced: @escaping (String) -> Void = { _ in })
    {
        self.store = store
        self.photoStore = photoStore
        self.endpointProvider = endpointProvider
        self.authProvider = authProvider
        self.retryInterval = retryInterval
        self.enrichmentPollInterval = enrichmentPollInterval
        self.clientFactory = clientFactory
        self.onSampleSynced = onSampleSynced
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
                if let pending = try? self.store.fetchPending(), !pending.isEmpty {
                    self.kick()
                }
            }
        }
    }

    private func runPass() async {
        let endpoint = endpointProvider().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !endpoint.isEmpty else { return }

        let pending: [LocalSample]
        do {
            pending = try store.fetchPending()
        } catch {
            Log.sync.error("fetchPending failed: \(error.localizedDescription)")
            return
        }
        if pending.isEmpty { return }

        let client = clientFactory(endpoint, authProvider())
        for sample in pending {
            await push(sample, via: client)
        }
    }

    private func push(_ sample: LocalSample, via client: SamplePushClient) async {
        var working = sample
        working.syncStatus = .syncing
        working.syncError = nil
        try? store.update(working)

        do {
            inFlight += 1
            defer { inFlight -= 1 }

            let created = try await client.createSample(SampleCreateInput(
                lat: sample.lat,
                lon: sample.lon,
                accuracy: sample.accuracyM,
                altitude: sample.altitudeM,
                collectedFrom: sample.collectedFrom,
                notes: sample.notes.isEmpty ? nil : sample.notes,
                marked: sample.marked,
                code: sample.code,
                clientUuid: sample.id,
                clientUpdatedAt: sample.updatedAt
            ))

            working.backendId = created.id
            working.excursion = created.excursion
            working.adminUnitsLocality = created.adminUnits?.locality
            working.adminUnitsCountry = created.adminUnits?.country
            working.mtbSheetNumber = created.mtb?.sheetNumber
            working.mtbSheetName = created.mtb?.sheetName

            if created.code != sample.code {
                // Server reassigned on conflict. The original is what
                // the user wrote on the tube; the server's reassigned
                // code is the authoritative database value.
                working.backendCode = created.code
                working.originalCode = created.originalCode ?? sample.code
            } else {
                working.backendCode = nil
                // Server honored — but it might still return
                // original_code from a prior conflict round. Keep
                // whatever the server has.
                working.originalCode = created.originalCode
            }

            working.syncStatus = .synced
            try store.update(working)

            // Hand off the parent excursion id to the container so
            // the excursion-side hydration runs in parallel.
            onSampleSynced(created.excursion)

            // Push any photos that were captured for this sample
            // before the sync round-trip. We have the backend id now,
            // so each photo gets its own multipart POST.
            await pushPhotos(for: working, backendSampleID: created.id, endpoint: endpointProvider())

            await pollEnrichment(id: created.id, sample: working, via: client)
        } catch {
            working.syncStatus = .failed
            working.syncError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            try? store.update(working)
            Log.sync.error("sample push failed: \(working.syncError ?? "")")
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

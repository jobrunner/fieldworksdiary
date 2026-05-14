import Foundation

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
    let endpointProvider: () -> String
    let authProvider: () -> AuthSession?
    let onSampleSynced: (String) -> Void

    @Published private(set) var inFlight = 0
    @Published private(set) var lastError: String?

    private var passTask: Task<Void, Never>?
    private var retryTimer: Task<Void, Never>?

    /// Time between automatic retry passes when there are pending or
    /// failed rows. Bumped to 5s in tests.
    private let retryInterval: Duration

    init(store: LocalSampleStore,
         endpointProvider: @escaping () -> String,
         authProvider: @escaping () -> AuthSession? = { nil },
         retryInterval: Duration = .seconds(30),
         onSampleSynced: @escaping (String) -> Void = { _ in }) {
        self.store = store
        self.endpointProvider = endpointProvider
        self.authProvider = authProvider
        self.retryInterval = retryInterval
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
            lastError = error.localizedDescription
            return
        }
        if pending.isEmpty { return }

        let client = SampleClient(endpoint: endpoint, auth: authProvider())
        for sample in pending {
            await push(sample, via: client)
        }
    }

    private func push(_ sample: LocalSample, via client: SampleClient) async {
        var working = sample
        working.syncStatus = .syncing
        working.syncError = nil
        try? store.update(working)

        do {
            inFlight += 1
            defer { inFlight -= 1 }

            let created = try await client.createSample(
                lat: sample.lat,
                lon: sample.lon,
                accuracy: sample.accuracyM,
                altitude: sample.altitudeM,
                collectedFrom: sample.collectedFrom,
                code: sample.code,
                clientUuid: sample.id,
                clientUpdatedAt: sample.updatedAt
            )

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

            await pollEnrichment(id: created.id, sample: working, via: client)
        } catch {
            working.syncStatus = .failed
            working.syncError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            try? store.update(working)
            lastError = working.syncError
        }
    }

    private func pollEnrichment(id: String, sample: LocalSample, via client: SampleClient) async {
        var working = sample
        for _ in 0..<6 {
            try? await Task.sleep(for: .seconds(1.5))
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

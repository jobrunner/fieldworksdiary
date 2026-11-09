import FieldworksGeo
import Foundation
import GRDB

/// CRUD for `local_samples` plus the per-(user, collecting_day)
/// sequence allocation. Sequences are derived strictly from
/// successfully-inserted samples — if an insert fails, the
/// transaction rolls back and the counter doesn't advance.
final class LocalSampleStore {
    let database: Database
    /// The user id the local rows are tagged with. Mutable so the
    /// AppContainer can swap it in when the auth user changes — local
    /// rows from the previous user are wiped first via `reset()`, so
    /// changing this on the fly is safe.
    var userId: String
    let cutoffHour: Int
    let timeZone: TimeZone

    init(database: Database,
         userId: String = "default",
         cutoffHour: Int = 5,
         timeZone: TimeZone = TimeZone(identifier: "Europe/Berlin") ?? .current)
    {
        self.database = database
        self.userId = userId
        self.cutoffHour = cutoffHour
        self.timeZone = timeZone
    }

    /// Inserts a new sample with locally-allocated provisional code.
    /// Returns the persisted record.
    ///
    /// If `overrideCode` is non-nil, that code is used verbatim and the
    /// local sequence counter is not advanced (matches the backend
    /// contract: the user-typed code goes on the tube; a server-side
    /// collision is resolved via `original_code`).
    func createLocal(
        lat: Double,
        lon: Double,
        accuracy: Double? = nil,
        verticalAccuracy: Double? = nil,
        elevation: Double? = nil,
        collectedFrom: Date = Date(),
        notes: String = "",
        overrideCode: String? = nil,
        locationSource: LocationSource = .locationService
    ) throws -> LocalSample {
        let day = Codes.collectingDay(collectedFrom, cutoffHour: cutoffHour, timeZone: timeZone)
        let dayKey = Codes.collectingDayKey(day, timeZone: timeZone)
        let userId = self.userId
        let timeZone = self.timeZone

        return try database.writer.write { db in
            let code: String
            if let overrideCode, !overrideCode.isEmpty {
                code = overrideCode
            } else {
                let seq = try Self.nextSequence(db, userId: userId, dayKey: dayKey)
                code = Codes.formatCode(day: day, sequence: seq, timeZone: timeZone, template: .current)
            }
            let now = Date()
            var sample = LocalSample(
                id: UUID().uuidString,
                backendId: nil,
                sampleID: code,
                backendCode: nil,
                originalCode: nil,
                userId: userId,
                collectingDay: dayKey,
                latitude: lat,
                longitude: lon,
                horizontalAccuracy: accuracy,
                verticalAccuracy: verticalAccuracy,
                elevation: elevation,
                beginDate: collectedFrom,
                endDate: nil,
                isAllDay: false,
                timeZone: timeZone.identifier,
                notes: notes,
                marked: false,
                fieldtrip: nil,
                locality: nil,
                locationSource: locationSource.rawValue,
                version: 1,
                adminUnitsLocality: nil,
                adminUnitsCountry: nil,
                mtbSheetNumber: nil,
                mtbSheetName: nil,
                syncStatus: .pending,
                syncError: nil,
                createdAt: now,
                updatedAt: now,
                elevationSource: elevation == nil ? nil : .locationService
            )
            try sample.insert(db)
            return sample
        }
    }

    /// All samples flagged with `marked = true`. Ordered newest-first
    /// (Phase 14b).
    func fetchMarked() throws -> [LocalSample] {
        try database.reader.read { db in
            try LocalSample
                .filter(Column("marked") == true)
                .order(Column("begin_date").desc)
                .fetchAll(db)
        }
    }

    func countMarked() throws -> Int {
        try database.reader.read { db in
            try LocalSample
                .filter(Column("marked") == true)
                .fetchCount(db)
        }
    }

    /// Flips the star on a single sample. Stays local-only; the
    /// caller decides whether to push an immediate PATCH (e.g. via
    /// `SampleClient.setMarked`) when the network is up.
    func setMarked(id: String, marked: Bool) throws {
        try database.writer.write { db in
            try db.execute(
                sql: "UPDATE local_samples SET marked = ?, updated_at = ? WHERE id = ?",
                arguments: [marked, Date(), id]
            )
        }
    }

    /// All samples ordered newest-first by `collected_from`. Backs the
    /// top-level Samples list (Phase 14).
    func fetchAll() throws -> [LocalSample] {
        try database.reader.read { db in
            try LocalSample
                .order(Column("begin_date").desc)
                .fetchAll(db)
        }
    }

    /// AsyncSequence over every sample, newest first. Used by the
    /// localities map (R8e) to render samples as a secondary pin
    /// layer that updates live as syncs land.
    func observeAll() -> AsyncValueObservation<[LocalSample]> {
        AsyncValueObservation(observation: ValueObservation.tracking { db in
            try LocalSample.order(Column("begin_date").desc).fetchAll(db)
        }, reader: database.reader)
    }

    /// Returns the code that *would* be assigned to the next sample
    /// for `collectedFrom`'s collecting day. Non-destructive — the
    /// counter doesn't advance. Used to seed the code field in the
    /// editor so the user sees a sensible default.
    func peekNextCode(for collectedFrom: Date = Date()) -> String {
        let day = Codes.collectingDay(collectedFrom, cutoffHour: cutoffHour, timeZone: timeZone)
        let dayKey = Codes.collectingDayKey(day, timeZone: timeZone)
        let userId = self.userId
        let next = (try? database.reader.read { db -> Int in
            if let row = try SequenceRow.fetchOne(
                db,
                sql: "SELECT last_seq FROM local_sequences WHERE user_id = ? AND collecting_day = ?",
                arguments: [userId, dayKey]
            ) {
                return row.lastSeq + 1
            }
            return 1
        }) ?? 1
        return Codes.formatCode(day: day, sequence: next, timeZone: timeZone, template: .current)
    }

    /// Most recently collected sample (regardless of sync state). Used
    /// on the home dashboard to show "Recently Sample".
    func mostRecent() throws -> LocalSample? {
        try database.reader.read { db in
            try LocalSample
                .order(Column("begin_date").desc)
                .fetchOne(db)
        }
    }

    func count() throws -> Int {
        try database.reader.read { db in
            try LocalSample.fetchCount(db)
        }
    }

    func fetchById(_ id: String) throws -> LocalSample? {
        try database.reader.read { db in
            try LocalSample.fetchOne(db, key: id)
        }
    }

    /// Samples belonging to the given fieldtrip id. Only rows that
    /// have already been synced are returned (the fieldtrip column
    /// is set after the SyncRunner round-trip).
    func fetchByFieldtrip(_ fieldtripID: String) throws -> [LocalSample] {
        try database.reader.read { db in
            try LocalSample
                .filter(Column("fieldtrip") == fieldtripID)
                .order(Column("begin_date"))
                .fetchAll(db)
        }
    }

    func fetchPending() throws -> [LocalSample] {
        try database.reader.read { db in
            try LocalSample
                .filter(Column("sync_status") == SyncStatus.pending.rawValue ||
                    Column("sync_status") == SyncStatus.failed.rawValue)
                .order(Column("created_at"))
                .fetchAll(db)
        }
    }

    /// Writes the whole row. `version` only ever moves forward: a copy
    /// carrying an older counter than the stored one keeps the stored
    /// one, so a stale snapshot can't make the next PATCH 409.
    func update(_ sample: LocalSample) throws {
        var copy = sample
        copy.updatedAt = Date()
        try database.writer.write { db in
            if let stored = try Self.storedVersion(db, id: copy.id), stored > copy.version {
                copy.version = stored
            }
            try copy.update(db)
        }
    }

    private static func storedVersion(_ db: GRDB.Database, id: String) throws -> Int? {
        try Int.fetchOne(db, sql: "SELECT version FROM local_samples WHERE id = ?", arguments: [id])
    }

    /// Sets only the sync bookkeeping columns. Used by the SyncRunner
    /// around network calls so it never writes a stale copy of the
    /// whole row over edits that landed meanwhile.
    func setSyncState(id: String, status: SyncStatus, error: String?) throws {
        try database.writer.write { db in
            try db.execute(
                sql: "UPDATE local_samples SET sync_status = ?, sync_error = ? WHERE id = ?",
                arguments: [status.rawValue, error, id]
            )
        }
    }

    func fetchByBackendID(_ backendID: String) throws -> LocalSample? {
        try database.reader.read { db in
            try LocalSample.filter(Column("backend_id") == backendID).fetchOne(db)
        }
    }

    func fetchByLocality(_ localityID: String) throws -> [LocalSample] {
        try database.reader.read { db in
            try LocalSample.filter(Column("locality") == localityID).fetchAll(db)
        }
    }

    /// Corrects the coordinate of an existing sample (Phase O2).
    ///
    /// Everything derived from the old point is cleared: MTB, DEM,
    /// terrain, bearing, the features, a DEM-derived elevation, and the
    /// placemark unless the user curated it (`manual`, whose stale
    /// suggestion is dropped instead). The status goes back to
    /// `pending` (except `manual`). The online resolver or the backend
    /// refills the values for the new point.
    ///
    /// A synced row gets a `.sample/.update` with
    /// `coordinateChanged`, so the push sends the coordinate, the
    /// status and explicit clears for the derived columns, and then
    /// waits for the backend's re-enrichment. Callers re-run
    /// `SampleLocationResolver.resolveOnline` afterwards.
    ///
    /// `keepManualPlace` is the answer to the editor's „Ortsangaben neu
    /// übernehmen?“ dialog for a `manual` sample: true („Meine Angaben
    /// behalten“) keeps the curated placemark (the resolver may then
    /// offer a suggestion); false („Übernehmen“) drops it like for any
    /// other status, so the new point's place is taken.
    func updateCoordinate(
        id: String,
        latitude: Double,
        longitude: Double,
        horizontalAccuracy: Double? = nil,
        locationSource: LocationSource = .user,
        keepManualPlace: Bool = true,
        mutationsStore: PendingMutationsStore
    ) throws {
        let backendID: String? = try database.writer.write { db in
            guard var sample = try LocalSample.fetchOne(db, key: id) else { return nil }
            sample.latitude = latitude
            sample.longitude = longitude
            sample.horizontalAccuracy = horizontalAccuracy
            sample.locationSource = locationSource.rawValue
            sample.clearDerivedLocation(keepManualPlace: keepManualPlace)
            sample.updatedAt = Date()
            try sample.update(db)
            _ = try LocalSampleFeature.filter(Column("sample_id") == id).deleteAll(db)
            return sample.backendId
        }
        guard let backendID, !backendID.isEmpty else { return }
        _ = try mutationsStore.enqueue(
            entityType: .sample,
            entityId: id,
            op: .update,
            payload: SampleUpdatePayload(coordinateChanged: true).encoded
        )
    }

    /// Persists the user-editable fields (code, notes, star) of
    /// `sample` and — if the row has a backend id — enqueues a
    /// `.sample/.update` outbox row whose payload is built fresh at
    /// execute time.
    ///
    /// Only those columns are taken from `sample`; everything else
    /// (version, place data, sync state) stays as stored. An editor
    /// holding an older snapshot therefore can't roll back a version
    /// bump or place data the SyncRunner merged meanwhile.
    ///
    /// The mutation carries the *local* sample id as `entityId`
    /// (same shape as `.sample/.create`) and an empty payload; the
    /// SyncRunner reads the current row at PATCH time, so successive
    /// edits never need to coalesce or rewrite payload JSON — the
    /// latest committed row state always wins. Multiple PATCHes per
    /// logical edit are wasteful but eventually consistent (the
    /// backend bumps `version` each round).
    ///
    /// Rows that haven't been pushed yet (`backendId == nil`) get
    /// no update mutation: the pending `.create` will pick up the
    /// freshly-edited values when the SyncRunner reads from the row
    /// (see `executeSampleCreate`).
    func saveEdits(_ sample: LocalSample, mutationsStore: PendingMutationsStore) throws {
        let backendID: String? = try database.writer.write { db in
            guard var stored = try LocalSample.fetchOne(db, key: sample.id) else { return nil }
            stored.sampleID = sample.sampleID
            stored.notes = sample.notes
            stored.marked = sample.marked
            stored.updatedAt = Date()
            try stored.update(db)
            return stored.backendId
        }

        guard let backendID, !backendID.isEmpty else { return }

        _ = try mutationsStore.enqueue(
            entityType: .sample,
            entityId: sample.id,
            op: .update,
            payload: Data()
        )
    }

    // MARK: - Phase O2 place edits (Task 17)

    /// Saves a place the user typed in: looks up or creates the
    /// `manual` placemark for `place` and points only this sample at
    /// it (other samples sharing the old placemark keep it; the old
    /// row itself is never edited). Status becomes `manual`, a pending
    /// suggestion is dropped (also on the server). The sync pushes the
    /// manual placemark through `/api/placemarks/resolve` first.
    @discardableResult
    func setManualPlace(
        id: String,
        place: Place,
        placemarks: LocalPlacemarkStore,
        mutationsStore: PendingMutationsStore
    ) throws -> LocalPlacemark {
        let placemark = try placemarks.lookupOrCreate(place: place, source: .manual)
        try writePlaceEdit(id: id, mutationsStore: mutationsStore,
                           payload: SampleUpdatePayload(clearsSuggestion: true)) { sample in
            sample.placemark = placemark.id
            sample.placemarkSuggestion = nil
            sample.locationStatus = .manual
            return true
        }
        return placemark
    }

    /// A height typed by the user: source `manual`, no measured
    /// accuracy. Never overwritten by GPS or the DEM afterwards.
    func setManualElevation(id: String, elevation: Double, mutationsStore: PendingMutationsStore) throws {
        try writePlaceEdit(id: id, mutationsStore: mutationsStore, payload: SampleUpdatePayload()) { sample in
            sample.elevation = elevation
            sample.elevationSource = .manual
            sample.verticalAccuracy = nil
            return true
        }
    }

    /// „Übernehmen“ on „Neue Ortsangaben verfügbar“: the backend's
    /// suggestion becomes the placemark, status `backend_service`.
    /// No-op without a suggestion.
    func acceptPlacemarkSuggestion(id: String, mutationsStore: PendingMutationsStore) throws {
        try writePlaceEdit(id: id, mutationsStore: mutationsStore,
                           payload: SampleUpdatePayload(clearsSuggestion: true)) { sample in
            guard let suggestion = sample.placemarkSuggestion, !suggestion.isEmpty else { return false }
            sample.placemark = suggestion
            sample.placemarkSuggestion = nil
            sample.locationStatus = .backendService
            return true
        }
    }

    /// „Verwerfen“: drops the suggestion, the user's place stays. The
    /// queued update sends `placemark_suggestion: ""` so the server
    /// forgets it too (a plain nil is never sent).
    func dismissPlacemarkSuggestion(id: String, mutationsStore: PendingMutationsStore) throws {
        try writePlaceEdit(id: id, mutationsStore: mutationsStore,
                           payload: SampleUpdatePayload(clearsSuggestion: true)) { sample in
            guard let suggestion = sample.placemarkSuggestion, !suggestion.isEmpty else { return false }
            sample.placemarkSuggestion = nil
            return true
        }
    }

    /// „Erneut senden“ for a `.failed` sample. A pushed row whose
    /// update the SyncRunner gave up on (repeated 409) gets a fresh
    /// `.sample/.update`; an unpushed row without a queued create gets
    /// its `.create` back. If a mutation is still queued, only the
    /// state is reset (the caller kicks the sync). No-op for rows that
    /// are not failed.
    func resendFailed(id: String, mutationsStore: PendingMutationsStore) throws {
        guard let sample = try fetchById(id), sample.syncStatus == .failed else { return }
        let queued = try mutationsStore.fetch(entityType: .sample).filter { $0.entityId == id }
        try setSyncState(id: id, status: .pending, error: nil)
        guard queued.isEmpty else { return }
        if let backendID = sample.backendId, !backendID.isEmpty {
            _ = try mutationsStore.enqueue(entityType: .sample, entityId: id, op: .update, payload: Data())
        } else {
            _ = try mutationsStore.enqueue(entityType: .sample, entityId: id, op: .create, payload: Data())
        }
    }

    /// Applies `change` to the stored row (only the columns it sets)
    /// in one transaction and queues an update when the row is pushed.
    /// `change` returns false for "nothing to do".
    private func writePlaceEdit(
        id: String,
        mutationsStore: PendingMutationsStore,
        payload: SampleUpdatePayload,
        change: (inout LocalSample) -> Bool
    ) throws {
        let backendID: String? = try database.writer.write { db in
            guard var sample = try LocalSample.fetchOne(db, key: id) else { return nil }
            guard change(&sample) else { return nil }
            sample.updatedAt = Date()
            try sample.update(db)
            return sample.backendId
        }
        guard let backendID, !backendID.isEmpty else { return }
        _ = try mutationsStore.enqueue(entityType: .sample, entityId: id, op: .update, payload: payload.encoded)
    }

    /// Placemark of the most recently collected sample on
    /// `collectingDay` (YYYY-MM-DD key) that has one, skipping the
    /// sample `excluding` (local id). Used to inherit a place offline
    /// when Ortus is unreachable.
    func latestPlacemarkID(collectingDay: String, excluding: String) throws -> String? {
        try database.reader.read { db in
            try String.fetchOne(db, sql: """
                SELECT placemark FROM local_samples
                WHERE collecting_day = ? AND id != ?
                  AND placemark IS NOT NULL AND placemark != ''
                ORDER BY begin_date DESC, created_at DESC
                LIMIT 1
            """, arguments: [collectingDay, excluding])
        }
    }

    /// Returns the first local sample whose `sample_id` matches `code`
    /// for the current user, optionally excluding a given row by id.
    /// Used by the editor's pre-save uniqueness check.
    func findByCode(_ code: String, excludingId: String? = nil) throws -> LocalSample? {
        let userId = self.userId
        return try database.reader.read { db in
            var query = LocalSample
                .filter(Column("sample_id") == code)
                .filter(Column("user_id") == userId)
            if let excludingId {
                query = query.filter(Column("id") != excludingId)
            }
            return try query.fetchOne(db)
        }
    }

    /// Merges a batch of remote samples into the local store. Local
    /// rows that haven't been pushed yet (`.pending` / `.syncing`) are
    /// left untouched — the SyncRunner is mid-flight on those and a
    /// blind overwrite would lose user data.
    ///
    /// Matching is done via `client_uuid` first (the round-trip key
    /// we set on push), then by `backend_id` as a fallback for rows
    /// that were created via another device and never had a local
    /// counterpart on this one. Anything without a match is inserted
    /// fresh with `syncStatus = .synced`.
    func upsert(_ remote: [Sample]) throws {
        let userId = self.userId
        let cutoffHour = self.cutoffHour
        let timeZone = self.timeZone

        try database.writer.write { db in
            for r in remote {
                guard let collectedFrom = r.beginDate else { continue }
                let day = Codes.collectingDay(collectedFrom, cutoffHour: cutoffHour, timeZone: timeZone)
                let dayKey = Codes.collectingDayKey(day, timeZone: timeZone)

                // Server placemark ids map onto the local row that
                // already represents them (locally created rows keep a
                // UUID id and carry the backend id in `backend_id`).
                let localPlacemarkID: (String) -> String = { backendID in
                    ((try? LocalPlacemarkStore.localID(forBackendID: backendID, in: db)) ?? nil) ?? backendID
                }
                let match = try findExisting(db, clientUuid: r.clientUuid, backendId: r.id)
                if var local = match {
                    if local.syncStatus == .pending || local.syncStatus == .syncing {
                        // The push is still in flight; the SyncRunner
                        // will reconcile the round-trip itself.
                        continue
                    }
                    if local.syncStatus == .failed, !(local.backendId ?? "").isEmpty {
                        // A rejected update (conflict) — keep the
                        // user's edit visible; their next save retries.
                        continue
                    }
                    if r.version < local.version {
                        // Snapshot older than what a push already
                        // brought in (list fetched before the PATCH).
                        continue
                    }
                    if try Self.hasQueuedMutation(db, sampleID: local.id) {
                        // Local edits (user or on-device resolver) are
                        // waiting in the outbox — they win; the push
                        // brings the server up to date.
                        continue
                    }
                    apply(remote: r, to: &local, dayKey: dayKey, userId: userId, localPlacemarkID: localPlacemarkID)
                    try local.update(db)
                } else {
                    var local = makeLocal(from: r, dayKey: dayKey, userId: userId)
                    local.mergeServerLocation(r, localPlacemarkID: localPlacemarkID)
                    try local.insert(db)
                }

                // Keep the sequence counter in sync with hydrated codes
                // so future offline allocations don't collide with
                // already-assigned numbers on the same day.
                if let seq = sequenceNumber(in: r.sampleID) {
                    try Self.bumpSequence(db, userId: userId, dayKey: dayKey, atLeast: seq)
                }
            }
        }
    }

    /// Wipes every row from the local sample tables. Called on logout
    /// and when the auth user changes — different users must not share
    /// the same local store.
    func reset() throws {
        try database.writer.write { db in
            try db.execute(sql: "DELETE FROM local_samples")
            try db.execute(sql: "DELETE FROM local_sequences")
            try db.execute(sql: "DELETE FROM local_sample_features")
        }
    }

    // MARK: - upsert helpers

    private func findExisting(_ db: GRDB.Database, clientUuid: String?, backendId: String) throws -> LocalSample? {
        if let clientUuid, !clientUuid.isEmpty,
           let byUuid = try LocalSample.fetchOne(db, key: clientUuid)
        {
            return byUuid
        }
        return try LocalSample
            .filter(Column("backend_id") == backendId)
            .fetchOne(db)
    }

    private static func hasQueuedMutation(_ db: GRDB.Database, sampleID: String) throws -> Bool {
        try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM pending_mutations
                          WHERE entity_type = 'sample' AND entity_id = ?)
        """, arguments: [sampleID]) ?? false
    }

    private func apply(
        remote r: Sample,
        to local: inout LocalSample,
        dayKey: String,
        userId: String,
        localPlacemarkID: (String) -> String
    ) {
        local.backendId = r.id
        // Server may have reassigned the sample_id on collision;
        // respect that as the new authoritative id.
        if local.sampleID != r.sampleID {
            local.backendCode = r.sampleID
            local.originalCode = r.originalCode ?? local.sampleID
        } else {
            local.backendCode = nil
            local.originalCode = r.originalCode
        }
        local.userId = userId
        local.collectingDay = dayKey
        local.latitude = r.latitude ?? local.latitude
        local.longitude = r.longitude ?? local.longitude
        local.horizontalAccuracy = r.horizontalAccuracy ?? local.horizontalAccuracy
        local.verticalAccuracy = r.verticalAccuracy ?? local.verticalAccuracy
        if let from = r.beginDate { local.beginDate = from }
        local.endDate = r.endDate ?? local.endDate
        local.isAllDay = r.isAllDay
        local.timeZone = r.timeZone
        if let n = r.notes { local.notes = n }
        local.marked = r.marked
        local.fieldtrip = r.fieldtrip
        // A client-created locality (UUID) whose push is pending stays;
        // the locality push re-points it and queues the sample update.
        if local.locality.map(PlacemarkClient.isRecordID) ?? true {
            local.locality = r.locality
        }
        local.locationSource = r.locationSource.rawValue
        local.version = r.version
        // Elevation, status, placemark, MTB and geo: never replaced by
        // nil/empty from a server that has not enriched (yet).
        local.mergeServerLocation(r, localPlacemarkID: localPlacemarkID)
        local.syncStatus = .synced
        local.syncError = nil
        if let cua = r.clientUpdatedAt { local.updatedAt = cua }
    }

    private func makeLocal(from r: Sample, dayKey: String, userId: String) -> LocalSample {
        let now = Date()
        return LocalSample(
            // Prefer the client_uuid so a future push from this device
            // for the same row matches up. If the row was created on
            // another device and never had a client_uuid, fall back to
            // the backend id so the local row still has a stable key.
            id: (r.clientUuid.flatMap { $0.isEmpty ? nil : $0 }) ?? r.id,
            backendId: r.id,
            sampleID: r.sampleID,
            backendCode: nil,
            originalCode: r.originalCode,
            userId: userId,
            collectingDay: dayKey,
            latitude: r.latitude,
            longitude: r.longitude,
            horizontalAccuracy: r.horizontalAccuracy,
            verticalAccuracy: r.verticalAccuracy,
            elevation: nil, // set by mergeServerLocation
            beginDate: r.beginDate ?? now,
            endDate: r.endDate,
            isAllDay: r.isAllDay,
            timeZone: r.timeZone,
            notes: r.notes ?? "",
            marked: r.marked,
            fieldtrip: r.fieldtrip,
            locality: r.locality,
            locationSource: r.locationSource.rawValue,
            version: r.version,
            adminUnitsLocality: nil,
            adminUnitsCountry: nil,
            mtbSheetNumber: nil,
            mtbSheetName: nil,
            syncStatus: .synced,
            syncError: nil,
            createdAt: r.beginDate ?? now,
            updatedAt: r.clientUpdatedAt ?? now
        )
    }

    /// Pulls the sequence number out of a code like `"260513/03"`.
    /// Returns nil for malformed codes — never blows up the upsert
    /// loop because of an unfamiliar shape.
    private func sequenceNumber(in code: String) -> Int? {
        guard let slash = code.firstIndex(of: "/") else { return nil }
        let tail = code[code.index(after: slash)...]
        return Int(tail)
    }

    private static func bumpSequence(_ db: GRDB.Database, userId: String, dayKey: String, atLeast n: Int) throws {
        if let row = try SequenceRow.fetchOne(
            db,
            sql: "SELECT last_seq FROM local_sequences WHERE user_id = ? AND collecting_day = ?",
            arguments: [userId, dayKey]
        ) {
            if row.lastSeq < n {
                try db.execute(
                    sql: "UPDATE local_sequences SET last_seq = ? WHERE user_id = ? AND collecting_day = ?",
                    arguments: [n, userId, dayKey]
                )
            }
        } else {
            try db.execute(
                sql: "INSERT INTO local_sequences (user_id, collecting_day, last_seq) VALUES (?, ?, ?)",
                arguments: [userId, dayKey, n]
            )
        }
    }

    /// Atomically increments and returns the per-(user, day) counter.
    private static func nextSequence(_ db: GRDB.Database, userId: String, dayKey: String) throws -> Int {
        if let row = try SequenceRow.fetchOne(
            db,
            sql: "SELECT last_seq FROM local_sequences WHERE user_id = ? AND collecting_day = ?",
            arguments: [userId, dayKey]
        ) {
            let next = row.lastSeq + 1
            try db.execute(
                sql: "UPDATE local_sequences SET last_seq = ? WHERE user_id = ? AND collecting_day = ?",
                arguments: [next, userId, dayKey]
            )
            return next
        } else {
            try db.execute(
                sql: "INSERT INTO local_sequences (user_id, collecting_day, last_seq) VALUES (?, ?, 1)",
                arguments: [userId, dayKey]
            )
            return 1
        }
    }
}

extension LocalSample {
    /// Merges the server-derived place data of `r` into this row.
    ///
    /// Rule: a server value only replaces a local one when it is
    /// present and not worse — the server may simply not have enriched
    /// yet, and the on-device resolver may already know more.
    /// - Elevation: taken when the server's source ranks at least as
    ///   high as the local one (manual > location_service >
    ///   backend_service), together with its source and accuracy.
    /// - Status: taken, except a server `pending` never downgrades a
    ///   local `inherited`/`backend_service`/`manual`.
    /// - Placemark / suggestion: taken when present, mapped to the local
    ///   placemark row id via `localPlacemarkID`.
    /// - MTB / DEM / terrain / bearing: per field, only when present.
    mutating func mergeServerLocation(_ r: Sample, localPlacemarkID: (String) -> String) {
        if let serverElevation = r.elevation {
            let serverSource = r.elevationSource ?? .locationService
            if elevation == nil || serverSource.rank >= (elevationSource?.rank ?? -1) {
                elevation = serverElevation
                elevationSource = serverSource
                if let accuracy = r.verticalAccuracy { verticalAccuracy = accuracy }
            }
        }
        if let status = r.locationStatus, !(status == .pending && locationStatus != .pending) {
            locationStatus = status
        }
        if let id = r.placemark { placemark = localPlacemarkID(id) }
        if let id = r.placemarkSuggestion { placemarkSuggestion = localPlacemarkID(id) }
        guard let g = r.geo else { return }
        mtbSheetNumber = g.mtbSheetNumber ?? mtbSheetNumber
        mtbSheetName = g.mtbSheetName ?? mtbSheetName
        mtbQuadrant = g.mtbQuadrant ?? mtbQuadrant
        elevationDEM = g.elevationDEM ?? elevationDEM
        elevationDEMAccuracy = g.elevationDEMAccuracy ?? elevationDEMAccuracy
        slopeDeg = g.slopeDeg ?? slopeDeg
        aspectDeg = g.aspectDeg ?? aspectDeg
        aspectCompass = g.aspectCompass ?? aspectCompass
        terrainFlat = g.terrainFlat || terrainFlat
        bearingLabel = g.bearingLabel ?? bearingLabel
        bearingReference = g.bearingReference ?? bearingReference
        bearingDistanceKm = g.bearingDistanceKm ?? bearingDistanceKm
        bearingCompass = g.bearingCompass ?? bearingCompass
        bearingInside = g.bearingInside || bearingInside
    }
}

extension LocalSample {
    /// Clears everything derived from the coordinate (see
    /// `LocalSampleStore.updateCoordinate`).
    mutating func clearDerivedLocation(keepManualPlace: Bool = true) {
        mtbSheetNumber = nil
        mtbSheetName = nil
        mtbQuadrant = nil
        elevationDEM = nil
        elevationDEMAccuracy = nil
        slopeDeg = nil
        aspectDeg = nil
        aspectCompass = nil
        terrainFlat = false
        bearingLabel = nil
        bearingReference = nil
        bearingDistanceKm = nil
        bearingCompass = nil
        bearingInside = false
        if elevationSource == .backendService {
            elevation = nil
            elevationSource = nil
            verticalAccuracy = nil
        }
        switch locationStatus {
        case .manual where keepManualPlace:
            placemarkSuggestion = nil
        case .manual, .pending, .inherited, .backendService:
            placemark = nil
            placemarkSuggestion = nil
            locationStatus = .pending
        }
    }
}

extension ElevationSource {
    /// Trust order for merging heights: a user's own value beats GPS,
    /// GPS beats the DEM.
    var rank: Int {
        switch self {
        case .backendService: 0
        case .locationService: 1
        case .manual: 2
        }
    }
}

private struct SequenceRow: FetchableRecord, Decodable {
    let lastSeq: Int
    enum CodingKeys: String, CodingKey { case lastSeq = "last_seq" }
}

/// Thin AsyncSequence facade over GRDB's ValueObservation. Makes it
/// trivial to drive an `@Published` list in a SwiftUI view model:
///
///     for await samples in store.observeAll() { /* update state */ }
struct AsyncValueObservation<T>: AsyncSequence {
    typealias Element = T

    let observation: ValueObservation<ValueReducers.Fetch<T>>
    let reader: any DatabaseReader

    func makeAsyncIterator() -> AsyncStream<T>.Iterator {
        AsyncStream { continuation in
            let cancellable = observation.start(in: reader) { error in
                continuation.finish()
                _ = error // swallow; caller decides if it cares
            } onChange: { value in
                continuation.yield(value)
            }
            continuation.onTermination = { _ in cancellable.cancel() }
        }.makeAsyncIterator()
    }
}

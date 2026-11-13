import FieldworksGeo
import Foundation
import GRDB

/// CRUD for `local_samples`. Sample ids come from
/// `SampleIDTemplate.nextSuggestion` over the user's local ids; the
/// running counter (`<n>`) is only advanced when a suggestion is
/// taken over unchanged.
final class LocalSampleStore {
    let database: Database
    /// The user id the local rows are tagged with. Mutable so the
    /// AppContainer can swap it in when the auth user changes — local
    /// rows from the previous user are wiped first via `reset()`, so
    /// changing this on the fly is safe.
    var userId: String
    /// Zone used for new samples (the device zone) and as the fallback
    /// when a remote row carries no usable zone.
    /// Resolved at use time, so a traveller whose app stays alive gets
    /// the current device zone for new samples.
    var timeZone: TimeZone {
        timeZoneProvider()
    }

    private let timeZoneProvider: () -> TimeZone
    private let defaults: UserDefaults
    private let settingsProvider: () -> SampleIDSettings

    /// `settings` defaults to a fresh read of the persisted app settings.
    init(database: Database,
         userId: String = "default",
         timeZone: TimeZone? = nil,
         timeZoneProvider: (() -> TimeZone)? = nil,
         defaults: UserDefaults = .standard,
         settings: (() -> SampleIDSettings)? = nil)
    {
        self.database = database
        self.userId = userId
        if let timeZone {
            self.timeZoneProvider = { timeZone }
        } else {
            self.timeZoneProvider = timeZoneProvider ?? { TimeZone.current }
        }
        self.defaults = defaults
        settingsProvider = settings ?? { SampleIDSettings.current(defaults: defaults) }
    }

    var cutoffHour: Int {
        settingsProvider().cutoffHour
    }

    /// Inserts a new sample. Returns the persisted record.
    ///
    /// Time: the zone is the store's (device) zone, `timezone_source`
    /// is `.device`. Begin/end are the default 15-minute window around
    /// `collectedFrom`; the collecting day is derived from the creation
    /// instant `collectedFrom` (not the rounded begin) with the
    /// configured rollover, in that zone.
    ///
    /// ID: if `overrideCode` is non-nil it is used verbatim (the empty
    /// string is a valid, stored id) and the running counter is not
    /// touched. With nil the current suggestion is used; if it came
    /// from the running counter, that counter is advanced.
    ///
    /// Coordinate: `lat`/`lon` may be nil for an instant creation
    /// (Phase E) before the first GPS fix; `PendingFixService` fills
    /// them in later.
    func createLocal(
        lat: Double?,
        lon: Double?,
        accuracy: Double? = nil,
        verticalAccuracy: Double? = nil,
        elevation: Double? = nil,
        collectedFrom: Date = Date(),
        notes: String = "",
        overrideCode: String? = nil,
        locationSource: LocationSource = .locationService
    ) throws -> LocalSample {
        let settings = settingsProvider()
        let timeZone = self.timeZone
        let dayKey = SampleTime.collectingDay(collectedFrom, cutoffHour: settings.cutoffHour, in: timeZone)
        let window = SampleTime.defaultWindow(createdAt: collectedFrom, in: timeZone)
        let userId = self.userId

        let (sample, consumedRunning) = try database.writer.write { db in
            let code: String
            var running: Int?
            if let overrideCode {
                code = overrideCode
            } else {
                let suggestion = try Self.suggestion(db, userId: userId, day: dayKey, settings: settings)
                code = suggestion.id
                running = suggestion.running
            }
            let now = Date()
            var sample = LocalSample(
                id: UUID().uuidString,
                backendId: nil,
                sampleID: code,
                originalCode: nil,
                userId: userId,
                collectingDay: dayKey,
                latitude: lat,
                longitude: lon,
                horizontalAccuracy: accuracy,
                verticalAccuracy: verticalAccuracy,
                elevation: elevation,
                beginDate: window.begin,
                endDate: window.end,
                isAllDay: false,
                timezone: timeZone.identifier,
                timezoneSource: .device,
                notes: notes,
                marked: false,
                fieldtrip: nil,
                locality: nil,
                locationSource: locationSource.rawValue,
                version: 1,
                mtbSheetNumber: nil,
                mtbSheetName: nil,
                syncStatus: .pending,
                syncError: nil,
                createdAt: now,
                updatedAt: now,
                elevationSource: elevation == nil ? nil : .locationService
            )
            try sample.insert(db)
            return (sample, running)
        }
        if let consumedRunning {
            defaults.set(consumedRunning, forKey: SampleIDSettings.Keys.lastRunning)
        }
        return sample
    }

    /// Inserts a sample entered afterwards („Probe nachtragen“) and
    /// queues its `.sample/.create`.
    ///
    /// Time: the window is the Phase Z default window around
    /// `beginDate`, read in `timezone`; the collecting day follows the
    /// begin date with the configured rollover in that zone (and keeps
    /// following it, see `saveEdits`). `code` is stored verbatim; the
    /// running counter is not touched. The coordinate may be nil (photo
    /// without GPS). Nothing registers with `PendingFixService`: a
    /// retrospective sample never gets a background fix. Provenance of
    /// the coordinate is `.user` (typed or taken from a photo).
    @discardableResult
    func createRetrospective(
        code: String,
        latitude: Double?,
        longitude: Double?,
        beginDate: Date,
        timezone: String,
        timezoneSource: TimezoneSource,
        mutationsStore: PendingMutationsStore
    ) throws -> LocalSample {
        let zone = TimeZone(identifier: timezone) ?? timeZone
        let window = SampleTime.defaultWindow(createdAt: beginDate, in: zone)
        let dayKey = SampleTime.collectingDay(window.begin, cutoffHour: settingsProvider().cutoffHour, in: zone)
        let userId = self.userId
        let sample = try database.writer.write { db in
            let now = Date()
            var sample = LocalSample(
                id: UUID().uuidString,
                backendId: nil,
                sampleID: code,
                originalCode: nil,
                userId: userId,
                collectingDay: dayKey,
                latitude: latitude,
                longitude: longitude,
                horizontalAccuracy: nil,
                verticalAccuracy: nil,
                elevation: nil,
                beginDate: window.begin,
                endDate: window.end,
                isAllDay: false,
                timezone: zone.identifier,
                timezoneSource: timezoneSource,
                notes: "",
                marked: false,
                fieldtrip: nil,
                locality: nil,
                locationSource: LocationSource.user.rawValue,
                version: 1,
                mtbSheetNumber: nil,
                mtbSheetName: nil,
                syncStatus: .pending,
                syncError: nil,
                createdAt: now,
                updatedAt: now,
                elevationSource: nil,
                isRetrospective: true
            )
            try sample.insert(db)
            return sample
        }
        _ = try mutationsStore.enqueue(entityType: .sample, entityId: sample.id, op: .create, payload: Data())
        return sample
    }

    /// A retrospective sample's day follows its begin date; a field
    /// sample keeps the day it was collected on. Call only when begin,
    /// zone or all-day actually changed in the write, so a later change
    /// of the rollover setting never silently moves old samples. The
    /// update always carries `begin_date`, `timezone` and
    /// `collecting_day` together (SyncRunner), which the backend needs
    /// to re-assign the fieldtrip.
    func refreshRetrospectiveCollectingDay(_ sample: inout LocalSample) {
        guard sample.isRetrospective else { return }
        let zone = TimeZone(identifier: sample.timezone) ?? timeZone
        sample.collectingDay = Self.collectingDay(
            begin: sample.beginDate, isAllDay: sample.isAllDay, zone: zone, cutoffHour: cutoffHour
        )
    }

    /// Collecting day of a begin instant read in `zone`. All-day rows
    /// are pinned to midnight, so the rollover must not apply: their
    /// day is the calendar day.
    static func collectingDay(begin: Date, isAllDay: Bool, zone: TimeZone, cutoffHour: Int) -> String {
        SampleTime.collectingDay(begin, cutoffHour: isAllDay ? 0 : cutoffHour, in: zone)
    }

    /// Suggestion for `day` from the user's non-empty local ids.
    private static func suggestion(
        _ db: GRDB.Database, userId: String, day: String, settings: SampleIDSettings
    ) throws -> (id: String, running: Int?) {
        let ids = try String.fetchAll(
            db, sql: "SELECT sample_id FROM local_samples WHERE user_id = ? AND sample_id != ''",
            arguments: [userId]
        )
        return SampleIDTemplate.nextSuggestion(
            template: settings.template, prefix: settings.prefix, day: day,
            existingIDs: Set(ids), lastRunning: settings.lastRunning, offset: settings.offset
        )
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

    /// AsyncSequence over the samples (all, or those of one fieldtrip)
    /// together with every cached placemark. Emits whenever either table
    /// changes, so place lines derived from samples follow a hydration
    /// (samples first, their placemarks right after) without the screen
    /// having to reappear.
    func observeWithPlacemarks(fieldtrip: String? = nil) -> AsyncValueObservation<SamplePlaceSnapshot> {
        AsyncValueObservation(observation: ValueObservation.tracking { db in
            var request = LocalSample.order(Column("begin_date").desc)
            if let fieldtrip {
                request = request.filter(Column("fieldtrip") == fieldtrip)
            }
            let samples = try request.fetchAll(db)
            let placemarks = try LocalPlacemark.fetchAll(db)
            return SamplePlaceSnapshot(
                samples: samples,
                placemarks: Dictionary(placemarks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            )
        }, reader: database.reader)
    }

    /// The id that *would* be suggested for the next sample created at
    /// `collectedFrom`. No side effects — the running counter does not
    /// advance. `running` is the consumed number when the format uses
    /// `<n>`; the caller passes the id back via `createLocal` only if
    /// the user kept it, otherwise the counter must stay untouched.
    /// `zone` reads the collecting day in another zone than the device
    /// zone (a photo's capture day in the Ortus zone of its position).
    func peekSuggestion(for collectedFrom: Date = Date(), in zone: TimeZone? = nil) -> (id: String, running: Int?) {
        let settings = settingsProvider()
        let day = SampleTime.collectingDay(collectedFrom, cutoffHour: settings.cutoffHour, in: zone ?? timeZone)
        let userId = self.userId
        let result = try? database.reader.read { db in
            try Self.suggestion(db, userId: userId, day: day, settings: settings)
        }
        return result ?? (id: "", running: nil)
    }

    /// Convenience for the editor's seed value.
    func peekNextCode(for collectedFrom: Date = Date()) -> String {
        peekSuggestion(for: collectedFrom).id
    }

    /// Advances the running counter to `running` (never backwards).
    /// Used when an instantly created sample keeps its suggested id:
    /// the counter only moves once the user took the suggestion over
    /// unchanged (Phase Z rule), which for an instant creation is
    /// known when the editor saves.
    func advanceRunning(to running: Int) {
        if running > settingsProvider().lastRunning {
            defaults.set(running, forKey: SampleIDSettings.Keys.lastRunning)
        }
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

    /// AsyncSequence over one sample row; emits nil once it is gone.
    /// The editor uses it to show a coordinate `PendingFixService`
    /// writes while the editor is open.
    func observeSample(id: String) -> AsyncValueObservation<LocalSample?> {
        AsyncValueObservation(observation: ValueObservation.tracking { db in
            try LocalSample.fetchOne(db, key: id)
        }, reader: database.reader)
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
        verticalAccuracy: Double? = nil,
        elevation: Double? = nil,
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
            // GPS height of a field fix (nil for map/manual corrections:
            // those keep the existing behaviour).
            if let elevation {
                sample.elevation = elevation
                sample.verticalAccuracy = verticalAccuracy
                sample.elevationSource = .locationService
            }
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
            // The old point's accuracy must not stay on the server.
            payload: SampleUpdatePayload(
                coordinateChanged: true, horizontalAccuracyEdited: horizontalAccuracy == nil
            ).encoded
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
            if stored.sampleID != sample.sampleID {
                // User edited the ID: the conflict marker no longer
                // applies (the update sends original_code "").
                stored.originalCode = nil
            }
            stored.sampleID = sample.sampleID
            stored.notes = sample.notes
            stored.marked = sample.marked
            // Time window and zone (editor): the instants are UTC, the
            // zone only changes how they are read.
            let timeChanged = stored.beginDate != sample.beginDate
                || stored.timezone != sample.timezone
                || stored.isAllDay != sample.isAllDay
            stored.beginDate = sample.beginDate
            stored.endDate = sample.endDate
            stored.timezone = sample.timezone
            stored.timezoneSource = sample.timezoneSource
            stored.isAllDay = sample.isAllDay
            if timeChanged { refreshRetrospectiveCollectingDay(&stored) }
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

    /// Deletes a sample and everything hanging off it locally: photo
    /// rows and files, feature rows, queued mutations of the sample.
    /// (Determinations have no local table; the server cascades them.)
    ///
    /// - Never pushed (no backend id): the queued `.create` is dropped
    ///   with the other mutations, nothing goes to the server.
    /// - Pushed: all queued mutations are dropped and a
    ///   `.sample/.delete` carrying the *backend* id is queued; the
    ///   SyncRunner deletes it on the server (404 = done).
    ///
    /// `dropCreatedLocality` („Sample löschen“ on a new sample): when
    /// the offline fusion created the sample's locality for it
    /// (`locality_origins`) and no other local sample uses it, that
    /// locality goes too — never pushed: its queued `.locality/.create`
    /// is dropped; pushed: a `.locality/.delete` with its backend id is
    /// queued. All in the same transaction.
    func deleteSample(id: String, mutationsStore _: PendingMutationsStore,
                      dropCreatedLocality: Bool = false) throws
    {
        // Local delete and the server-delete mutation share one
        // transaction (outbox and samples use the same writer): either
        // both happen or neither.
        try database.writer.write { db in
            guard let sample = try LocalSample.fetchOne(db, key: id) else { return }
            let photoIDs = try String.fetchAll(
                db, sql: "SELECT id FROM local_photos WHERE sample_id = ?", arguments: [id]
            )
            for photoID in photoIDs {
                try db.execute(
                    sql: "DELETE FROM pending_mutations WHERE entity_type = 'sample_photo' AND entity_id = ?",
                    arguments: [photoID]
                )
            }
            try db.execute(sql: "DELETE FROM local_photos WHERE sample_id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM local_sample_features WHERE sample_id = ?", arguments: [id])
            try db.execute(
                sql: "DELETE FROM pending_mutations WHERE entity_type = 'sample' AND entity_id = ?",
                arguments: [id]
            )
            _ = try LocalSample.deleteOne(db, key: id)
            if let backendID = sample.backendId, !backendID.isEmpty {
                // entityId of a delete is the *backend* id: the local
                // row is gone by the time the SyncRunner runs it.
                var mutation = PendingMutation(
                    id: UUID().uuidString, entityType: .sample, entityId: backendID, op: .delete,
                    payloadJson: Data(), createdAt: Date(), attempts: 0, lastAttemptAt: nil, lastError: nil
                )
                try mutation.insert(db)
            }
            if dropCreatedLocality, let localityID = sample.locality, !localityID.isEmpty {
                try Self.dropLocality(db, localityID: localityID, createdFor: id)
            }
        }
        PhotoStorage.deleteSampleDir(sampleID: id)
    }

    /// Part of `deleteSample(dropCreatedLocality:)`: removes the locality
    /// the fusion created for `sampleID` once no sample points at it.
    private static func dropLocality(_ db: GRDB.Database, localityID: String, createdFor sampleID: String) throws {
        let origin = try String.fetchOne(
            db, sql: "SELECT sample_id FROM locality_origins WHERE locality_id = ?", arguments: [localityID]
        )
        guard origin == sampleID else { return }
        let stillUsed = try Bool.fetchOne(
            db, sql: "SELECT EXISTS(SELECT 1 FROM local_samples WHERE locality = ?)", arguments: [localityID]
        ) ?? false
        guard !stillUsed else { return }
        try db.execute(
            sql: "DELETE FROM pending_mutations WHERE entity_type = 'locality' AND op = 'create' AND entity_id = ?",
            arguments: [localityID]
        )
        let wasQueued = db.changesCount > 0
        try db.execute(
            sql: "DELETE FROM pending_mutations WHERE entity_type = 'locality' AND entity_id = ?",
            arguments: [localityID]
        )
        try db.execute(sql: "DELETE FROM locality_origins WHERE locality_id = ?", arguments: [localityID])
        try db.execute(sql: "DELETE FROM local_localities WHERE id = ?", arguments: [localityID])
        guard !wasQueued else { return }
        // Already pushed: the id is the backend id.
        var mutation = PendingMutation(
            id: UUID().uuidString, entityType: .locality, entityId: localityID, op: .delete,
            payloadJson: Data(), createdAt: Date(), attempts: 0, lastAttemptAt: nil, lastError: nil
        )
        try mutation.insert(db)
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
                           payload: SampleUpdatePayload(clearsSuggestion: true))
        { sample in
            sample.placemark = placemark.id
            sample.placemarkSuggestion = nil
            sample.locationStatus = .manual
            return true
        }
        return placemark
    }

    /// A height typed by the user: source `manual`, accuracy = the
    /// given value or nil (a previous accuracy is discarded). Never
    /// overwritten by GPS or the DEM afterwards.
    func setManualElevation(
        id: String,
        elevation: Double,
        verticalAccuracy: Double?,
        mutationsStore: PendingMutationsStore
    ) throws {
        try writePlaceEdit(id: id, mutationsStore: mutationsStore,
                           payload: SampleUpdatePayload(elevationEdited: true))
        { sample in
            sample.elevation = elevation
            sample.elevationSource = .manual
            sample.verticalAccuracy = verticalAccuracy
            return true
        }
    }

    /// Horizontal accuracy typed in the edit form (metres; nil = none).
    /// The coordinate and its source stay. A nil is pushed as an
    /// explicit clear (`horizontalAccuracyEdited`).
    func setHorizontalAccuracy(
        id: String,
        horizontalAccuracy: Double?,
        mutationsStore: PendingMutationsStore
    ) throws {
        try writePlaceEdit(id: id, mutationsStore: mutationsStore,
                           payload: SampleUpdatePayload(horizontalAccuracyEdited: true))
        { sample in
            guard sample.horizontalAccuracy != horizontalAccuracy else { return false }
            sample.horizontalAccuracy = horizontalAccuracy
            return true
        }
    }

    /// „Übernehmen“ on „Neue Ortsangaben verfügbar“: the backend's
    /// suggestion becomes the placemark, status `backend_service`.
    /// No-op without a suggestion.
    func acceptPlacemarkSuggestion(id: String, mutationsStore: PendingMutationsStore) throws {
        try writePlaceEdit(id: id, mutationsStore: mutationsStore,
                           payload: SampleUpdatePayload(clearsSuggestion: true))
        { sample in
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
                           payload: SampleUpdatePayload(clearsSuggestion: true))
        { sample in
            guard let suggestion = sample.placemarkSuggestion, !suggestion.isEmpty else { return false }
            sample.placemarkSuggestion = nil
            return true
        }
    }

    /// „Erneut senden“ for a `.failed` sample.
    ///
    /// - The update the SyncRunner parked after repeated 409s is
    ///   revived with its payload flags (suggestion clear, coordinate
    ///   change, features).
    /// - Without a parked one and nothing queued, a pushed row gets a
    ///   fresh `.sample/.update` carrying the flags that are safe to
    ///   derive from the row (`clearsSuggestion` when it has no
    ///   suggestion, `pushFeatures` when it has local features); an
    ///   unpushed row gets its `.create` back.
    /// - If an active mutation is still queued, only the state is reset
    ///   (the caller kicks the sync).
    ///
    /// No-op for rows that are not failed.
    func resendFailed(id: String, mutationsStore: PendingMutationsStore) throws {
        guard let sample = try fetchById(id), sample.syncStatus == .failed else { return }
        let queued = try mutationsStore.fetch(entityType: .sample).filter { $0.entityId == id }
        try setSyncState(id: id, status: .pending, error: nil)
        if queued.contains(where: \.isParked) {
            try mutationsStore.revive(entityType: .sample, entityId: id)
            return
        }
        guard queued.isEmpty else { return }
        if let backendID = sample.backendId, !backendID.isEmpty {
            let featureCount = try database.reader.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM local_sample_features WHERE sample_id = ?",
                                 arguments: [id]) ?? 0
            }
            let payload = SampleUpdatePayload(
                pushFeatures: featureCount > 0,
                clearsSuggestion: sample.placemarkSuggestion == nil
            )
            _ = try mutationsStore.enqueue(entityType: .sample, entityId: id, op: .update, payload: payload.encoded)
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
            guard var sample = try LocalSample.fetchOne(db, key: id), change(&sample) else { return nil }
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
    /// Used by the editor's pre-save uniqueness check. The empty id is
    /// never "taken" — any number of samples may have none.
    func findByCode(_ code: String, excludingId: String? = nil) throws -> LocalSample? {
        guard !code.isEmpty else { return nil }
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
        let fallbackZone = timeZone

        try database.writer.write { db in
            for r in remote {
                guard let collectedFrom = r.beginDate else { continue }
                // The server's collecting day (in the sample's own zone)
                // is authoritative. Only without it compute locally —
                // then in the sample's zone, not the device zone.
                let zone = TimeZone(identifier: r.timezone) ?? fallbackZone
                let dayKey = r.collectingDay
                    ?? SampleTime.collectingDay(collectedFrom, cutoffHour: cutoffHour, in: zone)

                // Server placemark ids map onto the local row that
                // already represents them (locally created rows keep a
                // UUID id and carry the backend id in `backend_id`).
                let localPlacemarkID: (String) -> String = { backendID in
                    ((try? LocalPlacemarkStore.localID(forBackendID: backendID, in: db)) ?? nil) ?? backendID
                }
                // Deleted locally, the server delete is still queued:
                // do not resurrect the row from the list.
                if try Self.hasQueuedDelete(db, backendID: r.id) { continue }
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
            }
        }
    }

    /// Wipes every row from the local sample tables. Called on logout
    /// and when the auth user changes — different users must not share
    /// the same local store.
    func reset() throws {
        try database.writer.write { db in
            try db.execute(sql: "DELETE FROM local_samples")
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

    private static func hasQueuedDelete(_ db: GRDB.Database, backendID: String) throws -> Bool {
        try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM pending_mutations
                          WHERE entity_type = 'sample' AND op = 'delete' AND entity_id = ?)
        """, arguments: [backendID]) ?? false
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
        local.sampleID = r.sampleID
        local.originalCode = r.originalCode
        local.userId = userId
        local.collectingDay = dayKey
        local.isRetrospective = r.isRetrospective
        local.latitude = r.latitude ?? local.latitude
        local.longitude = r.longitude ?? local.longitude
        local.horizontalAccuracy = r.horizontalAccuracy ?? local.horizontalAccuracy
        local.verticalAccuracy = r.verticalAccuracy ?? local.verticalAccuracy
        if let from = r.beginDate { local.beginDate = from }
        local.endDate = r.endDate ?? local.endDate
        local.isAllDay = r.isAllDay
        local.timezone = r.timezone
        local.timezoneSource = r.timezoneSource ?? local.timezoneSource
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
            timezone: r.timezone,
            timezoneSource: r.timezoneSource,
            notes: r.notes ?? "",
            marked: r.marked,
            fieldtrip: r.fieldtrip,
            locality: r.locality,
            locationSource: r.locationSource.rawValue,
            version: r.version,
            mtbSheetNumber: nil,
            mtbSheetName: nil,
            syncStatus: .synced,
            syncError: nil,
            createdAt: r.beginDate ?? now,
            updatedAt: r.clientUpdatedAt ?? now,
            isRetrospective: r.isRetrospective
        )
    }
}

extension LocalSample {
    /// Adopts the server's zone when it comes from the location service
    /// or the user, unless the local zone was set manually (a device
    /// zone must never override the Ortus zone on a retry). An all-day
    /// row keeps its calendar day: its begin moves to 00:00 of that day
    /// in the new zone (same rule as the backend and the resolver).
    mutating func adoptServerZone(_ r: Sample) {
        guard timezoneSource != .manual,
              let source = r.timezoneSource, source == .locationService || source == .manual,
              !r.timezone.isEmpty else { return }
        if isAllDay, r.timezone != timezone,
           let oldZone = TimeZone(identifier: timezone),
           let newZone = TimeZone(identifier: r.timezone)
        {
            beginDate = SampleTime.startOfSameDay(beginDate, from: oldZone, to: newZone)
            endDate = nil
        }
        timezone = r.timezone
        timezoneSource = source
    }

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
                // The server's value is authoritative for the elevation it
                // sent, including "no accuracy" (stale one from another device).
                verticalAccuracy = r.verticalAccuracy
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
    /// True when both latitude and longitude are set. Samples created
    /// instantly (Phase E) start without one until a fix or a map pick
    /// arrives.
    var hasCoordinate: Bool {
        latitude != nil && longitude != nil
    }

    /// Clears everything derived from the coordinate (see
    /// `LocalSampleStore.updateCoordinate`).
    mutating func clearDerivedLocation(keepManualPlace: Bool = true) {
        mtbSheetNumber = nil
        mtbSheetName = nil
        mtbQuadrant = nil
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

/// One read of samples plus the cached placemarks by id, emitted by
/// `LocalSampleStore.observeWithPlacemarks(fieldtrip:)`.
struct SamplePlaceSnapshot {
    let samples: [LocalSample]
    let placemarks: [String: LocalPlacemark]
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

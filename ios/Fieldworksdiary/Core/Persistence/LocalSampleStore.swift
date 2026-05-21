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
         timeZone: TimeZone = TimeZone(identifier: "Europe/Berlin") ?? .current) {
        self.database = database
        self.userId = userId
        self.cutoffHour = cutoffHour
        self.timeZone = timeZone
    }

    /// Inserts a new sample with locally-allocated provisional code.
    /// Returns the persisted record.
    func createLocal(
        lat: Double,
        lon: Double,
        accuracy: Double? = nil,
        altitude: Double? = nil,
        collectedFrom: Date = Date()
    ) throws -> LocalSample {
        let day = Codes.collectingDay(collectedFrom, cutoffHour: cutoffHour, timeZone: timeZone)
        let dayKey = Codes.collectingDayKey(day, timeZone: timeZone)
        let userId = self.userId
        let timeZone = self.timeZone

        return try database.writer.write { db in
            let seq = try Self.nextSequence(db, userId: userId, dayKey: dayKey)
            let code = Codes.formatCode(day: day, sequence: seq, timeZone: timeZone)
            let now = Date()
            var sample = LocalSample(
                id: UUID().uuidString,
                backendId: nil,
                code: code,
                backendCode: nil,
                originalCode: nil,
                userId: userId,
                collectingDay: dayKey,
                lat: lat,
                lon: lon,
                accuracyM: accuracy,
                altitudeM: altitude,
                collectedFrom: collectedFrom,
                excursion: nil,
                adminUnitsLocality: nil,
                adminUnitsCountry: nil,
                mtbSheetNumber: nil,
                mtbSheetName: nil,
                syncStatus: .pending,
                syncError: nil,
                createdAt: now,
                updatedAt: now
            )
            try sample.insert(db)
            return sample
        }
    }

    /// Returns all samples in newest-first order. For a future
    /// observed list, switch the caller to `observeAll()`.
    func fetchAll() throws -> [LocalSample] {
        try database.reader.read { db in
            try LocalSample.order(Column("created_at").desc).fetchAll(db)
        }
    }

    func fetchById(_ id: String) throws -> LocalSample? {
        try database.reader.read { db in
            try LocalSample.fetchOne(db, key: id)
        }
    }

    /// Samples belonging to the given excursion id. Only rows that
    /// have already been synced are returned (the excursion column
    /// is set after the SyncRunner round-trip).
    func fetchByExcursion(_ excursionID: String) throws -> [LocalSample] {
        try database.reader.read { db in
            try LocalSample
                .filter(Column("excursion") == excursionID)
                .order(Column("collected_from"))
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

    /// Streams the full sample list. SwiftUI views can bridge this to
    /// an `@Published` via a Task.
    func observeAll() -> AsyncValueObservation<[LocalSample]> {
        AsyncValueObservation(observation: ValueObservation.tracking { db in
            try LocalSample.order(Column("created_at").desc).fetchAll(db)
        }, reader: database.reader)
    }

    func update(_ sample: LocalSample) throws {
        var copy = sample
        copy.updatedAt = Date()
        try database.writer.write { db in
            try copy.update(db)
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
                guard let collectedFrom = r.collectedFrom else { continue }
                let day = Codes.collectingDay(collectedFrom, cutoffHour: cutoffHour, timeZone: timeZone)
                let dayKey = Codes.collectingDayKey(day, timeZone: timeZone)

                let match = try findExisting(db, clientUuid: r.clientUuid, backendId: r.id)
                if var local = match {
                    if local.syncStatus == .pending || local.syncStatus == .syncing {
                        // The push is still in flight; the SyncRunner
                        // will reconcile the round-trip itself.
                        continue
                    }
                    apply(remote: r, to: &local, dayKey: dayKey, userId: userId)
                    try local.update(db)
                } else {
                    let local = makeLocal(from: r, dayKey: dayKey, userId: userId)
                    var copy = local
                    try copy.insert(db)
                }

                // Keep the sequence counter in sync with hydrated codes
                // so future offline allocations don't collide with
                // already-assigned numbers on the same day.
                if let seq = sequenceNumber(in: r.code) {
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
        }
    }

    // MARK: - upsert helpers

    private func findExisting(_ db: GRDB.Database, clientUuid: String?, backendId: String) throws -> LocalSample? {
        if let clientUuid, !clientUuid.isEmpty,
           let byUuid = try LocalSample.fetchOne(db, key: clientUuid) {
            return byUuid
        }
        return try LocalSample
            .filter(Column("backend_id") == backendId)
            .fetchOne(db)
    }

    private func apply(remote r: Sample, to local: inout LocalSample, dayKey: String, userId: String) {
        local.backendId = r.id
        // Server may have reassigned the code on collision; respect
        // that as the new authoritative code.
        if local.code != r.code {
            local.backendCode = r.code
            local.originalCode = r.originalCode ?? local.code
        } else {
            local.backendCode = nil
            local.originalCode = r.originalCode
        }
        local.userId = userId
        local.collectingDay = dayKey
        local.lat = r.lat
        local.lon = r.lon
        local.accuracyM = r.accuracyM ?? local.accuracyM
        local.altitudeM = r.altitudeM ?? local.altitudeM
        if let from = r.collectedFrom { local.collectedFrom = from }
        local.excursion = r.excursion
        local.adminUnitsLocality = r.adminUnits?.locality
        local.adminUnitsCountry = r.adminUnits?.country
        local.mtbSheetNumber = r.mtb?.sheetNumber
        local.mtbSheetName = r.mtb?.sheetName
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
            id: (r.clientUuid?.isEmpty == false ? r.clientUuid! : r.id),
            backendId: r.id,
            code: r.code,
            backendCode: nil,
            originalCode: r.originalCode,
            userId: userId,
            collectingDay: dayKey,
            lat: r.lat,
            lon: r.lon,
            accuracyM: r.accuracyM,
            altitudeM: r.altitudeM,
            collectedFrom: r.collectedFrom ?? now,
            excursion: r.excursion,
            adminUnitsLocality: r.adminUnits?.locality,
            adminUnitsCountry: r.adminUnits?.country,
            mtbSheetNumber: r.mtb?.sheetNumber,
            mtbSheetName: r.mtb?.sheetName,
            syncStatus: .synced,
            syncError: nil,
            createdAt: r.collectedFrom ?? now,
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
        struct Row: FetchableRecord, Decodable {
            let lastSeq: Int
            enum CodingKeys: String, CodingKey { case lastSeq = "last_seq" }
        }
        if let row = try Row.fetchOne(
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
        struct Row: FetchableRecord, Decodable {
            let lastSeq: Int
            enum CodingKeys: String, CodingKey { case lastSeq = "last_seq" }
        }
        if let row = try Row.fetchOne(
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
                _ = error  // swallow; caller decides if it cares
            } onChange: { value in
                continuation.yield(value)
            }
            continuation.onTermination = { _ in cancellable.cancel() }
        }.makeAsyncIterator()
    }
}

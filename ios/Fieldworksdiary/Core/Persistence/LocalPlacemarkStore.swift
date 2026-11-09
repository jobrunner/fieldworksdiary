import FieldworksGeo
import Foundation
import GRDB

/// Slim wrapper around `local_placemarks`. Placemarks are a
/// deduplicated reference table on the server (Spec §6): upsert
/// (rows fetched from the backend, merged onto locally created rows
/// via `backend_id`), lookupOrCreate (Phase O2: places
/// mapped from an Ortus response on-device), fetchById, count, reset.
final class LocalPlacemarkStore {
    let database: Database

    init(database: Database) {
        self.database = database
    }

    /// Insert-or-update one placemark fetched from the backend.
    ///
    /// - A row whose `id` is the backend id is updated in place.
    /// - Otherwise a locally created row (UUID id) that already maps to
    ///   this backend id via `backend_id` is updated in place, so the
    ///   server copy never duplicates it.
    /// - Otherwise the record is inserted with the backend id as `id`.
    ///
    /// Ortus place columns of an existing row are kept when the server
    /// record has none (legacy row), so an upsert never blanks them.
    func upsert(_ remote: Placemark) throws {
        try database.writer.write { db in
            try Self.upsert(remote, in: db)
        }
    }

    /// Batch variant of `upsert(_:)`, one transaction.
    func upsert(_ remotes: [Placemark]) throws {
        try database.writer.write { db in
            for remote in remotes {
                try Self.upsert(remote, in: db)
            }
        }
    }

    private static func upsert(_ remote: Placemark, in db: GRDB.Database) throws {
        let existing = try LocalPlacemark.fetchOne(db, key: remote.id)
            ?? LocalPlacemark
            .filter(Column(LocalPlacemark.Columns.backendId) == remote.id)
            .order(Column.rowID)
            .fetchOne(db)
        var row = LocalPlacemark(from: remote)
        if let existing {
            row.id = existing.id
            if remote.countryISO.isEmpty, !existing.countryISO.isEmpty {
                row.countryISO = existing.countryISO
                row.admin = existing.admin
                row.island = existing.island
                row.mountainRange = existing.mountainRange
                row.mountain = existing.mountain
            }
        }
        try row.save(db)
    }

    /// Records the backend id (and owner) of a locally created row
    /// after `POST /api/placemarks/resolve` answered.
    func setBackend(localID: String, backendID: String, owner: String?) throws {
        try database.writer.write { db in
            try db.execute(
                sql: "UPDATE local_placemarks SET backend_id = ?, owner = ? WHERE id = ?",
                arguments: [backendID, owner, localID]
            )
        }
    }

    /// Local row id for a backend placemark id: the row itself when it
    /// was pulled from the server (`id == backend id`), else the oldest
    /// locally created row mapped to it. Nil when unknown locally.
    func localID(forBackendID backendID: String) throws -> String? {
        try database.reader.read { db in
            try Self.localID(forBackendID: backendID, in: db)
        }
    }

    static func localID(forBackendID backendID: String, in db: GRDB.Database) throws -> String? {
        try String.fetchOne(db, sql: """
            SELECT id FROM local_placemarks
            WHERE id = ? OR backend_id = ?
            ORDER BY (id = ?) DESC, rowid
            LIMIT 1
        """, arguments: [backendID, backendID, backendID])
    }

    /// The subset of `backendIDs` with no local row (neither as `id`
    /// nor as `backend_id`), deduplicated, in first-seen order.
    func missingBackendIDs(_ backendIDs: [String]) throws -> [String] {
        var seen = Set<String>()
        let unique = backendIDs.filter { !$0.isEmpty && seen.insert($0).inserted }
        return try database.reader.read { db in
            try unique.filter { try Self.localID(forBackendID: $0, in: db) == nil }
        }
    }

    /// Returns the placemark for `place` + `source`, creating it if
    /// none exists. Dedup key is `Place.dedupHash` + `geocoding_source`;
    /// if several rows match (e.g. a server copy and a local copy), the
    /// oldest inserted row wins — same rule as the backend's
    /// `geoplace.LookupOrCreatePlacemark` (ordered by `created`; here
    /// by SQLite `rowid`, i.e. insertion order).
    ///
    /// Owner is not part of the local key: the local DB only ever
    /// holds one user's data (wiped on user switch).
    func lookupOrCreate(place: Place, source: Placemark.GeocodingSource) throws -> LocalPlacemark {
        let hash = place.dedupHash
        return try database.writer.write { db in
            if let existing = try LocalPlacemark
                .filter(Column(LocalPlacemark.Columns.dedupHash) == hash)
                .filter(Column(LocalPlacemark.Columns.geocodingSource) == source.rawValue)
                .order(Column.rowID)
                .fetchOne(db)
            {
                return existing
            }
            var created = LocalPlacemark(id: UUID().uuidString, place: place, source: source)
            try created.insert(db)
            return created
        }
    }

    func fetchById(_ id: String) throws -> LocalPlacemark? {
        try database.reader.read { db in
            try LocalPlacemark.fetchOne(db, key: id)
        }
    }

    /// The local row for a backend placemark id — either stored under
    /// that id or a locally created row mapped to it via `backend_id`
    /// (see `localID(forBackendID:)`). Use this, not `fetchById`, for
    /// ids that come from the server (e.g. `localities.placemark`).
    func fetch(backendID: String) throws -> LocalPlacemark? {
        guard !backendID.isEmpty else { return nil }
        return try database.reader.read { db in
            guard let id = try Self.localID(forBackendID: backendID, in: db) else { return nil }
            return try LocalPlacemark.fetchOne(db, key: id)
        }
    }

    /// Every cached placemark keyed by its local row id. Backs list
    /// rows and the fieldtrip place filter (one read instead of one
    /// per row; the table holds one user's places only).
    func fetchAllByID() throws -> [String: LocalPlacemark] {
        try database.reader.read { db in
            let rows = try LocalPlacemark.fetchAll(db)
            return Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
    }

    func count() throws -> Int {
        try database.reader.read { db in
            try LocalPlacemark.fetchCount(db)
        }
    }

    /// Empties the table. Called on logout / user-switch in the
    /// AppContainer.
    func reset() throws {
        try database.writer.write { db in
            try db.execute(sql: "DELETE FROM local_placemarks")
        }
    }
}

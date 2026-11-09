import FieldworksGeo
import Foundation
import GRDB

/// Slim wrapper around `local_placemarks`. Placemarks are a
/// deduplicated reference table on the server (Spec §6): upsert
/// (rows fetched from the backend), lookupOrCreate (Phase O2: places
/// mapped from an Ortus response on-device), fetchById, count, reset.
final class LocalPlacemarkStore {
    let database: Database

    init(database: Database) {
        self.database = database
    }

    /// Insert-or-update one placemark. Idempotent on the dedup_hash
    /// at the GRDB level — `id` is the primary key, so the same row
    /// re-saved with new field values just patches in place.
    func upsert(_ remote: Placemark) throws {
        try database.writer.write { db in
            var local = LocalPlacemark(from: remote)
            try local.save(db)
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

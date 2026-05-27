import Foundation
import GRDB

/// Slim wrapper around `local_placemarks`. Placemarks are a
/// deduplicated reference table on the server (Spec §6) — clients
/// only ever read them, so the store stays small: upsert (called by
/// the future PlacemarksHydrator or ad-hoc by detail views that
/// fetched a row), fetchById, count, reset.
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

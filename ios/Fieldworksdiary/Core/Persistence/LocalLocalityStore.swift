import Foundation
import GRDB

final class LocalLocalityStore {
    let database: Database

    init(database: Database) {
        self.database = database
    }

    /// Rows with a queued server delete are skipped: a pull between the
    /// local delete and the SyncRunner's DELETE must not bring them back.
    func upsert(_ remote: [Locality]) throws {
        try database.writer.write { db in
            for r in remote where try !Self.hasQueuedDelete(db, localityID: r.id) {
                var local = LocalLocality(from: r)
                try local.save(db)
            }
        }
    }

    func upsertOne(_ remote: Locality) throws {
        try database.writer.write { db in
            guard try !Self.hasQueuedDelete(db, localityID: remote.id) else { return }
            var local = LocalLocality(from: remote)
            try local.save(db)
        }
    }

    private static func hasQueuedDelete(_ db: GRDB.Database, localityID: String) throws -> Bool {
        try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM pending_mutations
                          WHERE entity_type = 'locality' AND op = 'delete' AND entity_id = ?)
        """, arguments: [localityID]) ?? false
    }

    func fetchById(_ id: String) throws -> LocalLocality? {
        try database.reader.read { db in
            try LocalLocality.fetchOne(db, key: id)
        }
    }

    /// Snapshot of every locality, for the offline-fusion pass in the
    /// sample editor (R8d). A plain read, no observation.
    func fetchAll() throws -> [LocalLocality] {
        try database.reader.read { db in
            try LocalLocality.order(Column("name")).fetchAll(db)
        }
    }

    /// Create a brand-new locality locally (offline-first, R8d). The
    /// row uses a client UUID as its id; the SyncRunner's
    /// `.locality/.create` dispatch later swaps it for the backend id
    /// and re-points any samples. `centroid_*` mirror `latitude`/
    /// `longitude` so the list + detail (which still read the legacy
    /// columns) render coordinates immediately.
    ///
    /// `createdForSample` records that the offline fusion created this
    /// locality for that sample (`locality_origins`), in the same
    /// transaction.
    @discardableResult
    func createLocal(
        latitude: Double,
        longitude: Double,
        radiusM: Double = LocalityFusion.defaultRadiusM,
        locationSource: LocationSource = .locationService,
        name: String = "",
        createdForSample: String? = nil
    ) throws -> LocalLocality {
        let now = Date()
        var local = LocalLocality(
            id: UUID().uuidString,
            name: name,
            latitude: latitude,
            longitude: longitude,
            altitude: nil,
            horizontalAccuracy: nil,
            verticalAccuracy: nil,
            locationSource: locationSource.rawValue,
            locationNumber: nil,
            placemark: nil,
            radiusM: radiusM,
            notes: "",
            version: 1,
            clientUuid: UUID().uuidString,
            clientUpdatedAt: now,
            needsHumanReview: false,
            centroidLat: latitude,
            centroidLon: longitude,
            backendUpdatedAt: now
        )
        try database.writer.write { db in
            try local.insert(db)
            if let createdForSample {
                try db.execute(
                    sql: "INSERT OR REPLACE INTO locality_origins (locality_id, sample_id) VALUES (?, ?)",
                    arguments: [local.id, createdForSample]
                )
            }
        }
        return local
    }

    /// The sample the offline fusion created `localityID` for, if any.
    func originSample(ofLocality localityID: String) throws -> String? {
        try database.reader.read { db in
            try String.fetchOne(
                db, sql: "SELECT sample_id FROM locality_origins WHERE locality_id = ?", arguments: [localityID]
            )
        }
    }

    /// Carries the origin over the UUID → backend id swap of a pushed
    /// locality.
    func moveOrigin(from oldID: String, to newID: String) throws {
        guard oldID != newID else { return }
        try database.writer.write { db in
            try db.execute(
                sql: "UPDATE locality_origins SET locality_id = ? WHERE locality_id = ?",
                arguments: [newID, oldID]
            )
        }
    }

    /// AsyncSequence over the full sorted list.
    func observeAll() -> AsyncValueObservation<[LocalLocality]> {
        AsyncValueObservation(observation: ValueObservation.tracking { db in
            try LocalLocality.order(Column("name")).fetchAll(db)
        }, reader: database.reader)
    }

    func count() throws -> Int {
        try database.reader.read { db in
            try LocalLocality.fetchCount(db)
        }
    }

    /// Re-point a locality's placemark relation locally after a manual
    /// override (PATCH) or reset (DELETE), so the detail view reflects
    /// the change without waiting for the next full locality pull.
    /// Passing `nil` detaches the placemark.
    func setPlacemark(localityID: String, placemarkID: String?) throws {
        try database.writer.write { db in
            try db.execute(
                sql: "UPDATE local_localities SET placemark = ? WHERE id = ?",
                arguments: [placemarkID, localityID]
            )
        }
    }

    /// Empties the table. Called on logout/user switch.
    func reset() throws {
        try database.writer.write { db in
            try db.execute(sql: "DELETE FROM local_localities")
            try db.execute(sql: "DELETE FROM locality_origins")
        }
    }

    /// Apply a Spec §5.3 LocalityRemap event: every local sample
    /// that still points at `oldID` is re-hung onto `newID`, and the
    /// old locality row is dropped. Idempotent — re-applying after
    /// the old row is already gone is a no-op, which matters because
    /// the puller may re-deliver an event after a network blip.
    ///
    /// `affectedSampleIDs` from the server are advisory; we always
    /// run the full SQL update so a sample row that arrived on this
    /// device through some out-of-band path still gets re-pointed.
    ///
    /// Returns the count of samples that were actually re-pointed,
    /// for diagnostics + the UI notification.
    @discardableResult
    func applyRemap(oldID: String, newID: String) throws -> Int {
        guard oldID != newID else { return 0 } // defensive: pathological event
        return try database.writer.write { db in
            // Re-point samples first; the FK reference (loose, in
            // GRDB-land — but the UI relies on it) stays consistent
            // even if the delete below fails for some reason.
            try db.execute(
                sql: "UPDATE local_samples SET locality = ? WHERE locality = ?",
                arguments: [newID, oldID]
            )
            let movedCount = db.changesCount
            try db.execute(
                sql: "DELETE FROM local_localities WHERE id = ?",
                arguments: [oldID]
            )
            return movedCount
        }
    }
}

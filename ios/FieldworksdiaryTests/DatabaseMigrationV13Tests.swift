@testable import Fieldworksdiary
import GRDB
import XCTest

/// Pins the `v13_ortus_location` data migration: legacy rows written
/// under v12 must come through with `elevation` filled from
/// `altitude`, a `pending` location status, and the placemark source
/// renamed to the snake_case wire value.
final class DatabaseMigrationV13Tests: XCTestCase {
    private func migratedToV12() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try Database.makeMigrator().migrate(queue, upTo: "v12_localities_needs_human_review")
        return queue
    }

    private func insertLegacySample(_ db: GRDB.Database, id: String, altitude: Double?) throws {
        try db.execute(sql: """
            INSERT INTO local_samples
              (id, sample_id, user_id, collecting_day, latitude, longitude, altitude,
               begin_date, sync_status, created_at, updated_at)
            VALUES (?, ?, 'u1', '2026-05-19', 49.79, 9.94, ?,
                    '2026-05-19 12:00:00.000', 'synced',
                    '2026-05-19 12:00:00.000', '2026-05-19 12:00:00.000')
        """, arguments: [id, "260519/\(id)", altitude])
    }

    func testMigration_CopiesAltitudeIntoElevation() throws {
        let queue = try migratedToV12()
        try queue.write { db in
            try insertLegacySample(db, id: "1", altitude: 312.5)
            try insertLegacySample(db, id: "2", altitude: nil)
        }

        try Database.makeMigrator().migrate(queue)

        try queue.read { db in
            let withAlt = try XCTUnwrap(LocalSample.fetchOne(db, key: "1"))
            XCTAssertEqual(withAlt.elevation, 312.5)
            XCTAssertEqual(withAlt.elevationSource, .locationService)
            XCTAssertEqual(withAlt.locationStatus, .pending)

            let withoutAlt = try XCTUnwrap(LocalSample.fetchOne(db, key: "2"))
            XCTAssertNil(withoutAlt.elevation)
            XCTAssertNil(withoutAlt.elevationSource)
            XCTAssertEqual(withoutAlt.locationStatus, .pending)
            XCTAssertNil(withoutAlt.placemark)
            XCTAssertFalse(withoutAlt.terrainFlat)
            XCTAssertFalse(withoutAlt.bearingInside)
        }
    }

    func testMigration_RenamesLegacyGeocodingSource() throws {
        let queue = try migratedToV12()
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO local_placemarks (id, country, geocoding_source, dedup_hash, backend_updated_at)
                VALUES ('p1', 'DE', 'backend-service', 'h1', '2026-05-19 12:00:00.000'),
                       ('p2', 'DE', 'manual', 'h2', '2026-05-19 12:00:00.000')
            """)
        }

        try Database.makeMigrator().migrate(queue)

        try queue.read { db in
            let p1 = try XCTUnwrap(LocalPlacemark.fetchOne(db, key: "p1"))
            XCTAssertEqual(p1.geocodingSource, "backend_service")
            let p2 = try XCTUnwrap(LocalPlacemark.fetchOne(db, key: "p2"))
            XCTAssertEqual(p2.geocodingSource, "manual")
        }
    }

    func testMigration_DedupHashIsNoLongerUnique() throws {
        let queue = try migratedToV12()
        try Database.makeMigrator().migrate(queue)

        // Same hash, different source — must be allowed now (the
        // backend dedups on hash + source + owner).
        XCTAssertNoThrow(try queue.write { db in
            try db.execute(sql: """
                INSERT INTO local_placemarks (id, country, geocoding_source, dedup_hash, backend_updated_at)
                VALUES ('a', 'DE', 'backend_service', 'same', '2026-05-19 12:00:00.000'),
                       ('b', 'DE', 'manual', 'same', '2026-05-19 12:00:00.000')
            """)
        })
    }

    func testMigration_CreatesSampleFeaturesTable() throws {
        let queue = try migratedToV12()
        try Database.makeMigrator().migrate(queue)

        try queue.read { db in
            XCTAssertTrue(try db.tableExists("local_sample_features"))
            let columns = try Set(db.columns(in: "local_sample_features").map(\.name))
            XCTAssertEqual(columns, [
                "id", "sample_id", "source_id", "source_name", "layer",
                "feature_id", "properties_json", "license_json", "fetched_at"
            ])
        }
    }
}

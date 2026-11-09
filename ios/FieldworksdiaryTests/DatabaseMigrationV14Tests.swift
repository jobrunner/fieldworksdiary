@testable import Fieldworksdiary
import GRDB
import XCTest

/// Pins the `v14_timezone_elevation` migration: `time_zone` becomes
/// `timezone` (value kept), `timezone_source` is backfilled with
/// `device`, a DEM height moves into `elevation` only when the sample
/// has no height of its own, and the DEM columns are gone.
final class DatabaseMigrationV14Tests: XCTestCase {
    private func migratedToV13() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try Database.makeMigrator().migrate(queue, upTo: "v13_ortus_location")
        return queue
    }

    private func insert(
        _ db: GRDB.Database,
        id: String,
        timeZone: String = "Europe/Berlin",
        elevation: Double? = nil,
        elevationSource: String? = nil,
        dem: Double? = nil,
        demAccuracy: Double? = nil
    ) throws {
        try db.execute(sql: """
            INSERT INTO local_samples
              (id, sample_id, user_id, collecting_day, latitude, longitude,
               begin_date, sync_status, created_at, updated_at, time_zone,
               elevation, elevation_source, elevation_dem, elevation_dem_accuracy)
            VALUES (?, ?, 'u1', '2026-05-19', 49.79, 9.94,
                    '2026-05-19 12:00:00.000', 'synced',
                    '2026-05-19 12:00:00.000', '2026-05-19 12:00:00.000', ?,
                    ?, ?, ?, ?)
        """, arguments: [id, "260519/\(id)", timeZone, elevation, elevationSource, dem, demAccuracy])
    }

    func testMigration_RenamesTimeZoneAndBackfillsSource() throws {
        let queue = try migratedToV13()
        try queue.write { db in
            try insert(db, id: "1", timeZone: "Atlantic/Canary")
        }

        try Database.makeMigrator().migrate(queue)

        try queue.read { db in
            let row = try XCTUnwrap(LocalSample.fetchOne(db, key: "1"))
            XCTAssertEqual(row.timezone, "Atlantic/Canary")
            XCTAssertEqual(row.timezoneSource, .device)
        }
    }

    func testMigration_TakesDEMHeightOnlyWithoutOwnHeight() throws {
        let queue = try migratedToV13()
        try queue.write { db in
            try insert(db, id: "dem", dem: 236, demAccuracy: 4)
            try insert(db, id: "gps", elevation: 0, elevationSource: "location_service", dem: 236, demAccuracy: 4)
            try insert(db, id: "none")
        }

        try Database.makeMigrator().migrate(queue)

        try queue.read { db in
            let dem = try XCTUnwrap(LocalSample.fetchOne(db, key: "dem"))
            XCTAssertEqual(dem.elevation, 236)
            XCTAssertEqual(dem.verticalAccuracy, 4)
            XCTAssertEqual(dem.elevationSource, .backendService)

            let gps = try XCTUnwrap(LocalSample.fetchOne(db, key: "gps"))
            XCTAssertEqual(gps.elevation, 0)
            XCTAssertEqual(gps.elevationSource, .locationService)
            XCTAssertNil(gps.verticalAccuracy)

            let none = try XCTUnwrap(LocalSample.fetchOne(db, key: "none"))
            XCTAssertNil(none.elevation)
            XCTAssertNil(none.elevationSource)
        }
    }

    func testMigration_DropsLegacyColumns() throws {
        let queue = try migratedToV13()
        try Database.makeMigrator().migrate(queue)

        try queue.read { db in
            let columns = try db.columns(in: "local_samples").map(\.name)
            XCTAssertTrue(columns.contains("timezone"))
            XCTAssertTrue(columns.contains("timezone_source"))
            XCTAssertFalse(columns.contains("time_zone"))
            XCTAssertFalse(columns.contains("elevation_dem"))
            XCTAssertFalse(columns.contains("elevation_dem_accuracy"))
        }
    }
}

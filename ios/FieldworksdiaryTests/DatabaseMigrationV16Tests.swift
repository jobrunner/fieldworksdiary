@testable import Fieldworksdiary
import GRDB
import XCTest

/// Pins `v16_sample_coordinate_optional`: latitude/longitude accept
/// NULL (samples created before the first fix), existing rows and
/// indexes survive the table rebuild.
final class DatabaseMigrationV16Tests: XCTestCase {
    private let insert = """
    INSERT INTO local_samples
      (id, sample_id, user_id, collecting_day, latitude, longitude,
       begin_date, sync_status, created_at, updated_at, elevation)
    VALUES (?, '260519/1', 'u1', '2026-05-19', ?, ?,
            '2026-05-19 12:00:00.000', 'synced',
            '2026-05-19 12:00:00.000', '2026-05-19 12:00:00.000', 236)
    """

    func testMigration_KeepsRowsAndIndexesAndAllowsNullCoordinates() throws {
        let queue = try DatabaseQueue()
        try Database.makeMigrator().migrate(queue, upTo: "v15_drop_legacy_location")
        let columnsBefore = try queue.read { db in try db.columns(in: "local_samples").map(\.name) }
        let indexesBefore = try queue.read { db in
            try Set(String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'local_samples' AND sql IS NOT NULL"
            ))
        }
        try queue.write { db in
            try db.execute(sql: insert, arguments: ["s1", 49.79, 9.94])
        }

        try Database.makeMigrator().migrate(queue)

        try queue.write { db in
            // The rebuild keeps every column in order; later migrations
            // (v18 `is_retrospective`) may only append.
            let columnsAfter = try db.columns(in: "local_samples").map(\.name)
            XCTAssertEqual(Array(columnsAfter.prefix(columnsBefore.count)), columnsBefore)
            let indexesAfter = try Set(String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'local_samples' AND sql IS NOT NULL"
            ))
            XCTAssertEqual(indexesAfter, indexesBefore)

            let kept = try Row.fetchOne(db, sql: "SELECT latitude, longitude, elevation FROM local_samples WHERE id = 's1'")
            XCTAssertEqual(kept?["latitude"] as Double?, 49.79)
            XCTAssertEqual(kept?["longitude"] as Double?, 9.94)
            XCTAssertEqual(kept?["elevation"] as Double?, 236)

            try db.execute(sql: insert, arguments: ["s2", nil, nil])
            let sample = try LocalSample.fetchOne(db, key: "s2")
            XCTAssertNotNil(sample)
            XCTAssertNil(sample?.latitude)
            XCTAssertFalse(sample?.hasCoordinate ?? true)
        }
    }
}

import GRDB
@testable import Legulus
import XCTest

/// Pins `v19_photo_attempts`: `local_photos` gets the retry bookkeeping
/// (`attempts`, `last_attempt_at`); existing rows keep their data and
/// start with zero attempts.
final class DatabaseMigrationV19Tests: XCTestCase {
    func testMigration_AddsAttemptsAndKeepsRows() throws {
        let queue = try DatabaseQueue()
        try Database.makeMigrator().migrate(queue, upTo: "v18_sample_is_retrospective")
        try queue.write { db in
            try db.execute(sql: """
            INSERT INTO local_photos
              (id, sample_id, local_path, sync_status, client_uuid, client_updated_at, created_at)
            VALUES ('p1', 's1', 'photos/s1/p1.jpg', 'failed', 'p1',
                    '2026-05-19 12:00:00.000', '2026-05-19 12:00:00.000')
            """)
        }

        try Database.makeMigrator().migrate(queue)

        try queue.read { db in
            let columns = try db.columns(in: "local_photos").map(\.name)
            XCTAssertTrue(columns.contains("attempts"))
            XCTAssertTrue(columns.contains("last_attempt_at"))
            let photo = try XCTUnwrap(LocalPhoto.fetchOne(db, key: "p1"))
            XCTAssertEqual(photo.attempts, 0)
            XCTAssertNil(photo.lastAttemptAt)
            XCTAssertEqual(photo.localPath, "photos/s1/p1.jpg")
            XCTAssertEqual(photo.syncStatus, .failed)
        }
    }
}

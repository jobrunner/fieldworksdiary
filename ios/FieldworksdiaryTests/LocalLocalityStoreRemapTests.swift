@testable import Fieldworksdiary
import XCTest

@MainActor
final class LocalLocalityStoreRemapTests: XCTestCase {
    private var database: Database!
    private var localities: LocalLocalityStore!
    private var samples: LocalSampleStore!
    // swiftlint:disable:next force_unwrapping
    private let berlin = TimeZone(identifier: "Europe/Berlin")!

    override func setUpWithError() throws {
        try super.setUpWithError()
        database = try Database(inMemory: ())
        localities = LocalLocalityStore(database: database)
        samples = LocalSampleStore(database: database, userId: "u1", cutoffHour: 5, timeZone: berlin)

        // Two localities; we'll merge "old" into "new".
        try database.writer.write { db in
            try db.execute(sql: """
                INSERT INTO local_localities
                (id, name, location_source, version, notes, backend_updated_at)
                VALUES
                ('old', 'Duplicate', 0, 1, '', ?),
                ('new', 'Survivor',  0, 1, '', ?)
                """, arguments: [Date(), Date()])
        }
    }

    override func tearDownWithError() throws {
        samples = nil
        localities = nil
        database = nil
        try super.tearDownWithError()
    }

    private func seedSample(id: String, locality: String) throws {
        try database.writer.write { db in
            try db.execute(sql: """
                INSERT INTO local_samples (
                    id, sample_id, user_id, collecting_day,
                    latitude, longitude, begin_date,
                    is_all_day, time_zone, version,
                    notes, marked, locality, location_source,
                    sync_status, created_at, updated_at
                ) VALUES (?, ?, 'u1', '2026-05-19',
                          49.79, 9.94, ?,
                          0, 'Europe/Berlin', 1,
                          '', 0, ?, 0,
                          'synced', ?, ?)
                """,
                arguments: [id, "260519/1", Date(), locality, Date(), Date()])
        }
    }

    func testApplyRemapRepointsSamplesAndDeletesOldLocality() throws {
        try seedSample(id: "s1", locality: "old")
        try seedSample(id: "s2", locality: "old")
        try seedSample(id: "s3", locality: "new") // already on target

        let moved = try localities.applyRemap(oldID: "old", newID: "new")
        XCTAssertEqual(moved, 2)

        // Samples now all point at "new".
        let all = try samples.fetchAll()
        let onNew = all.filter { $0.locality == "new" }
        let onOld = all.filter { $0.locality == "old" }
        XCTAssertEqual(onNew.count, 3)
        XCTAssertEqual(onOld.count, 0)

        // Old locality is gone.
        XCTAssertNil(try localities.fetchById("old"))
        XCTAssertNotNil(try localities.fetchById("new"))
    }

    func testApplyRemapIsIdempotent() throws {
        try seedSample(id: "s1", locality: "old")

        XCTAssertEqual(try localities.applyRemap(oldID: "old", newID: "new"), 1)
        // Second pass: old is already gone, 0 samples to re-point.
        XCTAssertEqual(try localities.applyRemap(oldID: "old", newID: "new"), 0)
        XCTAssertNil(try localities.fetchById("old"))
    }

    func testApplyRemapNoOpWhenOldUnknown() throws {
        // Neither samples nor a locality named "ghost" — apply is
        // a clean no-op.
        XCTAssertEqual(try localities.applyRemap(oldID: "ghost", newID: "new"), 0)
        XCTAssertNotNil(try localities.fetchById("new"))
    }

    func testApplyRemapRejectsSelfMerge() throws {
        // Defensive: same-id merge is a pathological event; the
        // store should treat it as a no-op rather than nuke its
        // own samples.
        try seedSample(id: "s1", locality: "old")
        XCTAssertEqual(try localities.applyRemap(oldID: "old", newID: "old"), 0)
        XCTAssertNotNil(try localities.fetchById("old"))
    }
}

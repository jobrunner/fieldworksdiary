@testable import Fieldworksdiary
import XCTest

/// R8c: the `needs_human_review` column (GRDB migration v12) must
/// round-trip through the store, and the list's review/regular
/// partition must split on it. A renamed CodingKey would silently
/// decode every row as `false` and the review section would vanish.
@MainActor
final class LocalityReviewFlagTests: XCTestCase {
    func testNeedsHumanReviewRoundTripsAndPartitions() throws {
        let database = try Database(inMemory: ())
        let store = LocalLocalityStore(database: database)

        try database.writer.write { db in
            try db.execute(sql: """
                INSERT INTO local_localities
                (id, name, location_source, version, notes,
                 needs_human_review, backend_updated_at)
                VALUES
                ('flagged', 'Duplicate', 0, 1, '', 1, ?),
                ('clean',   'Survivor',  0, 1, '', 0, ?)
                """, arguments: [Date(), Date()])
        }

        let flagged = try XCTUnwrap(store.fetchById("flagged"))
        let clean = try XCTUnwrap(store.fetchById("clean"))
        XCTAssertTrue(flagged.needsHumanReview)
        XCTAssertFalse(clean.needsHumanReview)

        // Same predicate the LocalitiesListViewModel uses.
        let all = [flagged, clean]
        XCTAssertEqual(all.filter(\.needsHumanReview).map(\.id), ["flagged"])
        XCTAssertEqual(all.filter { !$0.needsHumanReview }.map(\.id), ["clean"])
    }
}

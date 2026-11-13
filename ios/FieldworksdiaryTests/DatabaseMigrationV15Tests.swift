@testable import Fieldworksdiary
import GRDB
import XCTest

/// Pins the `v15_drop_legacy_location` migration: the legacy location
/// columns and the dead `local_sequences` table are gone, the data of
/// the Ortus columns survives.
final class DatabaseMigrationV15Tests: XCTestCase {
    private func columns(_ db: GRDB.Database, _ table: String) throws -> Set<String> {
        try Set(db.columns(in: table).map(\.name))
    }

    func testMigration_DropsLegacyColumnsAndKeepsNewData() throws {
        let queue = try DatabaseQueue()
        try Database.makeMigrator().migrate(queue, upTo: "v14_timezone_elevation")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO local_samples
                  (id, sample_id, user_id, collecting_day, latitude, longitude,
                   begin_date, sync_status, created_at, updated_at,
                   elevation, elevation_source, mtb_sheet_number, mtb_sheet_name,
                   admin_units_locality, admin_units_country, backend_code)
                VALUES ('s1', '260519/1', 'u1', '2026-05-19', 49.79, 9.94,
                        '2026-05-19 12:00:00.000', 'synced',
                        '2026-05-19 12:00:00.000', '2026-05-19 12:00:00.000',
                        236, 'location_service', '6326', 'Ochsenfurt',
                        'Würzburg', 'Deutschland', '')
            """)
            try db.execute(sql: """
                INSERT INTO local_placemarks
                  (id, country, locality, geocoding_source, dedup_hash, backend_updated_at,
                   country_iso, admin_state)
                VALUES ('p1', 'DE', 'Würzburg', 'manual', 'h', '2026-05-19 12:00:00.000',
                        'DE', 'Bayern')
            """)
            try db.execute(sql: """
                INSERT INTO local_fieldtrips
                  (id, collecting_day, backend_updated_at, country, admin_area,
                   admin_units_json, mtb_json, day_of_year)
                VALUES ('f1', '2026-05-19', '2026-05-19 12:00:00.000', 'Deutschland', 'Bayern',
                        '{}', '{}', 139)
            """)
            try db.execute(sql: "INSERT INTO local_sequences (user_id, collecting_day, last_seq) VALUES ('u1', '2026-05-19', 3)")
        }

        try Database.makeMigrator().migrate(queue)

        try queue.read { db in
            let samples = try columns(db, "local_samples")
            for gone in ["admin_units_locality", "admin_units_country", "backend_code", "altitude"] {
                XCTAssertFalse(samples.contains(gone), "local_samples.\(gone)")
            }
            let trips = try columns(db, "local_fieldtrips")
            for gone in ["admin_units_json", "mtb_json", "country", "admin_area"] {
                XCTAssertFalse(trips.contains(gone), "local_fieldtrips.\(gone)")
            }
            let placemarks = try columns(db, "local_placemarks")
            for gone in [
                "country", "administrative_area", "sub_administrative_area", "locality",
                "sub_locality", "postal_code", "name", "thoroughfare"
            ] {
                XCTAssertFalse(placemarks.contains(gone), "local_placemarks.\(gone)")
            }
            XCTAssertFalse(try db.tableExists("local_sequences"))

            let sample = try XCTUnwrap(LocalSample.fetchOne(db, key: "s1"))
            XCTAssertEqual(sample.elevation, 236)
            XCTAssertEqual(sample.mtbSheetNumber, "6326")
            XCTAssertEqual(sample.mtbSheetName, "Ochsenfurt")
            let placemark = try XCTUnwrap(LocalPlacemark.fetchOne(db, key: "p1"))
            XCTAssertEqual(placemark.countryISO, "DE")
            XCTAssertEqual(placemark.admin[.state]?.name, "Bayern")
            let trip = try XCTUnwrap(LocalFieldtrip.fetchOne(db, key: "f1"))
            XCTAssertEqual(trip.dayOfYear, 139)
        }
    }
}

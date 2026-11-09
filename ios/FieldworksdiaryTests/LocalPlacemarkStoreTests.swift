@testable import Fieldworksdiary
import FieldworksGeo
import XCTest

/// `LocalPlacemarkStore.lookupOrCreate` mirrors the backend's
/// `geoplace.LookupOrCreatePlacemark`: dedup on hash + source, oldest
/// match wins.
final class LocalPlacemarkStoreTests: XCTestCase {
    private var database: Database!
    private var store: LocalPlacemarkStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        database = try Database(inMemory: ())
        store = LocalPlacemarkStore(database: database)
    }

    override func tearDownWithError() throws {
        store = nil
        database = nil
        try super.tearDownWithError()
    }

    private func wuerzburg() -> Place {
        Place(
            countryISO: "DE",
            admin: [
                .country: AdminValue(name: "Deutschland", native: "Deutschland", level: 2),
                .state: AdminValue(name: "Bayern", native: "Bayern", level: 4),
                .municipality: AdminValue(name: "Würzburg", level: 8)
            ],
            mountainRange: "Spessart"
        )
    }

    func testLookupOrCreate_CreatesRowWithPlaceColumns() throws {
        let place = wuerzburg()
        let created = try store.lookupOrCreate(place: place, source: .backendService)

        XCTAssertEqual(created.dedupHash, place.dedupHash)
        XCTAssertEqual(created.geocodingSource, "backend_service")
        XCTAssertEqual(created.countryISO, "DE")
        XCTAssertEqual(created.country, "DE", "legacy country mirrors country_iso")
        XCTAssertNil(created.backendId)
        XCTAssertNotNil(created.geocodingDate)

        let reloaded = try XCTUnwrap(store.fetchById(created.id))
        XCTAssertEqual(reloaded.place, place)
        XCTAssertEqual(reloaded.admin[.state], AdminValue(name: "Bayern", native: "Bayern", level: 4))
        XCTAssertNil(reloaded.admin[.county])
        XCTAssertEqual(reloaded.mountainRange, "Spessart")
        XCTAssertEqual(try store.count(), 1)
    }

    func testLookupOrCreate_DeduplicatesSamePlaceAndSource() throws {
        let first = try store.lookupOrCreate(place: wuerzburg(), source: .backendService)
        let second = try store.lookupOrCreate(place: wuerzburg(), source: .backendService)

        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(try store.count(), 1)
    }

    func testLookupOrCreate_DifferentSourceCreatesSeparateRow() throws {
        let auto = try store.lookupOrCreate(place: wuerzburg(), source: .backendService)
        let manual = try store.lookupOrCreate(place: wuerzburg(), source: .manual)

        XCTAssertNotEqual(auto.id, manual.id)
        XCTAssertEqual(manual.geocodingSource, "manual")
        XCTAssertEqual(try store.count(), 2)
    }

    func testLookupOrCreate_DifferentPlaceCreatesSeparateRow() throws {
        var other = wuerzburg()
        other.admin[.municipality] = AdminValue(name: "Veitshöchheim", level: 8)

        let a = try store.lookupOrCreate(place: wuerzburg(), source: .backendService)
        let b = try store.lookupOrCreate(place: other, source: .backendService)

        XCTAssertNotEqual(a.id, b.id)
    }

    func testLookupOrCreate_PicksOldestOfExistingDuplicates() throws {
        let place = wuerzburg()
        try database.writer.write { db in
            for id in ["older", "newer"] {
                var row = LocalPlacemark(
                    id: id,
                    country: "DE",
                    geocodingSource: "backend_service",
                    dedupHash: place.dedupHash,
                    backendUpdatedAt: Date()
                )
                try row.insert(db)
            }
        }

        let found = try store.lookupOrCreate(place: place, source: .backendService)
        XCTAssertEqual(found.id, "older")
        XCTAssertEqual(try store.count(), 2)
    }

    func testUpsertRemote_StoresBackendIdAndSnakeCaseSource() throws {
        let json = """
        {"id": "pb1", "country": "DE", "geocoding_source": "backend-service", "dedup_hash": "h"}
        """
        let remote = try JSONDecoder.fieldworks.decode(Placemark.self, from: Data(json.utf8))
        XCTAssertEqual(remote.geocodingSource, .backendService)

        try store.upsert(remote)

        let local = try XCTUnwrap(store.fetchById("pb1"))
        XCTAssertEqual(local.backendId, "pb1")
        XCTAssertEqual(local.geocodingSource, "backend_service")
    }

    func testGeocodingSource_DecodesBothSpellingsAndWritesSnakeCase() throws {
        let decoder = JSONDecoder()
        let legacy = try decoder.decode([Placemark.GeocodingSource].self, from: Data(#"["backend-service"]"#.utf8))
        let current = try decoder.decode([Placemark.GeocodingSource].self, from: Data(#"["backend_service"]"#.utf8))
        let manual = try decoder.decode([Placemark.GeocodingSource].self, from: Data(#"["manual"]"#.utf8))
        XCTAssertEqual(legacy, [.backendService])
        XCTAssertEqual(current, [.backendService])
        XCTAssertEqual(manual, [.manual])

        let encoded = try JSONEncoder().encode([Placemark.GeocodingSource.backendService])
        XCTAssertEqual(String(decoding: encoded, as: UTF8.self), #"["backend_service"]"#)
    }
}

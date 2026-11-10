@testable import Fieldworksdiary
import FieldworksGeo
import XCTest

/// Place lines of the fieldtrip list and detail follow sample and
/// placemark writes (O3 final review): after a reinstall the samples
/// hydration writes samples first and their placemarks right after,
/// outside the screen's own refresh.
@MainActor
final class FieldtripPlaceObservationTests: XCTestCase {
    private var database: Database!
    private var samples: LocalSampleStore!
    private var placemarks: LocalPlacemarkStore!
    private var fieldtrips: LocalFieldtripStore!
    // swiftlint:disable:next force_unwrapping
    private let berlin = TimeZone(identifier: "Europe/Berlin")!

    override func setUpWithError() throws {
        try super.setUpWithError()
        database = try Database(inMemory: ())
        samples = LocalSampleStore(database: database, userId: "u1", timeZone: berlin,
                                   settings: { SampleIDSettings(cutoffHour: 5) })
        placemarks = LocalPlacemarkStore(database: database)
        fieldtrips = LocalFieldtripStore(database: database)
    }

    override func tearDownWithError() throws {
        samples = nil
        placemarks = nil
        fieldtrips = nil
        database = nil
        try super.tearDownWithError()
    }

    private func seedSample(fieldtrip: String, placemark: String) throws {
        var sample = try samples.createLocal(lat: 49.68, lon: 10.04)
        sample.fieldtrip = fieldtrip
        sample.placemark = placemark
        try samples.update(sample)
    }

    private func upsertWuerzburg(id: String) throws {
        let json = """
        {"id": "\(id)", "country_iso": "DE", "admin_state": "Bayern", "admin_state_level": 4,
         "admin_municipality": "Würzburg", "admin_municipality_level": 8,
         "geocoding_source": "backend_service", "dedup_hash": "h-\(id)"}
        """
        try placemarks.upsert(JSONDecoder.fieldworks.decode(Placemark.self, from: Data(json.utf8)))
    }

    func testObserveWithPlacemarks_EmitsWhenPlacemarkArrivesAfterSample() async throws {
        try seedSample(fieldtrip: "ft1", placemark: "pmlater")
        try seedSample(fieldtrip: "ft2", placemark: "pmother")
        var iterator = samples.observeWithPlacemarks(fieldtrip: "ft1").makeAsyncIterator()

        let firstValue = await iterator.next()
        let first = try XCTUnwrap(firstValue)
        XCTAssertEqual(first.samples.count, 1, "only the fieldtrip's samples")
        XCTAssertNil(first.placemarks["pmlater"])

        try upsertWuerzburg(id: "pmlater")
        let secondValue = await iterator.next()
        let second = try XCTUnwrap(secondValue)
        XCTAssertEqual(second.placemarks["pmlater"]?.place.admin[.municipality]?.name, "Würzburg")
    }

    func testListViewModel_PlaceSummaryFollowsHydrationWithoutReappearing() async throws {
        let viewModel = FieldtripsListViewModel(
            store: fieldtrips,
            hydrator: FieldtripsHydrator(store: fieldtrips, endpointProvider: { "" }),
            samples: samples,
            placemarks: placemarks
        )
        viewModel.start()
        XCTAssertNil(viewModel.placeSummaries["ft1"])

        // Hydration order: samples first, then their placemarks.
        try seedSample(fieldtrip: "ft1", placemark: "pmlater")
        try upsertWuerzburg(id: "pmlater")

        let deadline = Date().addingTimeInterval(2)
        while viewModel.placeSummaries["ft1"]?.name == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(viewModel.placeSummaries["ft1"]?.name, "Würzburg")
    }

    func testDetailParts_DateFirstAndNoSeparatorTexts() {
        let summary = FieldtripPlaceSummary(name: "Würzburg", region: "Deutschland, Bayern", mtb: "MTB 6225 Würzburg")
        let parts = FieldtripsListScreen.detailParts(collectingDay: "2026-05-19", summary: summary)
        XCTAssertEqual(parts, ["2026-05-19", "Würzburg", "MTB 6225 Würzburg"])
        XCTAssertFalse(parts.contains { $0.contains("·") }, "VoiceOver must not read separators")
        XCTAssertEqual(FieldtripsListScreen.detailParts(collectingDay: "2026-05-19", summary: nil), ["2026-05-19"])
    }
}

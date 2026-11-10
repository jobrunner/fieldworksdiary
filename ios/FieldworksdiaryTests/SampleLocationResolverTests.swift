@testable import Fieldworksdiary
import FieldworksGeo
import XCTest

/// Phase O2: on-device place resolution right after a sample is saved.
/// Online → Ortus fills placemark/features/MTB/geo; offline → the place
/// is inherited from the previous sample of the collecting day.
@MainActor
final class SampleLocationResolverTests: XCTestCase {
    private var database: Database!
    private var samples: LocalSampleStore!
    private var placemarks: LocalPlacemarkStore!
    private var features: LocalSampleFeatureStore!
    // swiftlint:disable:next force_unwrapping
    private let berlin = TimeZone(identifier: "Europe/Berlin")!

    /// Query point of the Ochsenfurt fixture.
    private let lat = 49.681616
    private let lon = 10.039652

    override func setUpWithError() throws {
        try super.setUpWithError()
        database = try Database(inMemory: ())
        samples = LocalSampleStore(database: database, userId: "u1", timeZone: berlin, settings: { SampleIDSettings(cutoffHour: 5) })
        placemarks = LocalPlacemarkStore(database: database)
        features = LocalSampleFeatureStore(database: database)
    }

    override func tearDownWithError() throws {
        database = nil
        samples = nil
        placemarks = nil
        features = nil
        try super.tearDownWithError()
    }

    // MARK: - online

    func testResolveOnline_Success_SetsPlacemarkFeaturesMTBAndStatus() async throws {
        let fake = FakeOrtus(.success(try Self.decode(Self.ochsenfurtJSON)))
        let sample = try samples.createLocal(lat: lat, lon: lon, accuracy: 5, elevation: 250)

        let ok = await makeResolver(fake).resolveOnline(sampleID: sample.id)

        XCTAssertTrue(ok)
        XCTAssertEqual(fake.queries.count, 1)
        XCTAssertEqual(fake.queries.first?.lat ?? 0, lat, accuracy: 1e-9)
        XCTAssertEqual(fake.queries.first?.lon ?? 0, lon, accuracy: 1e-9)

        let fresh = try XCTUnwrap(samples.fetchById(sample.id))
        XCTAssertEqual(fresh.locationStatus, .backendService)
        let placemarkID = try XCTUnwrap(fresh.placemark)
        let placemark = try XCTUnwrap(placemarks.fetchById(placemarkID))
        XCTAssertEqual(placemark.geocodingSource, Placemark.GeocodingSource.backendService.rawValue)
        XCTAssertEqual(placemark.countryISO, "DE")
        XCTAssertEqual(placemark.admin[.municipality]?.name, "Ochsenfurt")

        XCTAssertEqual(fresh.mtbSheetNumber, "6326")
        XCTAssertEqual(fresh.mtbSheetName, "Ochsenfurt")
        XCTAssertEqual(fresh.mtbQuadrant, 1)
        XCTAssertEqual(fresh.slopeDeg, 8.4)
        XCTAssertEqual(fresh.aspectCompass, "SSW")
        XCTAssertEqual(fresh.bearingLabel, "2 km WNW Ochsenfurt")
        XCTAssertEqual(fresh.bearingDistanceKm, 2.3)

        // GPS height wins over the DEM.
        XCTAssertEqual(fresh.elevation, 250)
        XCTAssertEqual(fresh.elevationSource, .locationService)

        XCTAssertEqual(try features.features(sampleID: sample.id, sourceID: "tk25-blattschnitt-de").count, 1)
        XCTAssertEqual(try features.features(sampleID: sample.id, sourceID: "natura2000-de").count, 1)
    }

    func testResolveOnline_GPSHeightZeroIsKept() async throws {
        let fake = FakeOrtus(.success(try Self.decode(Self.ochsenfurtJSON)))
        let sample = try samples.createLocal(lat: lat, lon: lon, elevation: 0)

        _ = await makeResolver(fake).resolveOnline(sampleID: sample.id)

        let fresh = try XCTUnwrap(samples.fetchById(sample.id))
        XCTAssertEqual(fresh.elevation, 0)
        XCTAssertEqual(fresh.elevationSource, .locationService)
    }

    func testResolveOnline_ManualCoordinateWithoutHeight_UsesDEM() async throws {
        let fake = FakeOrtus(.success(try Self.decode(Self.ochsenfurtJSON)))
        let sample = try samples.createLocal(lat: lat, lon: lon, locationSource: .user)
        XCTAssertNil(sample.elevationSource)

        let ok = await makeResolver(fake).resolveOnline(sampleID: sample.id)

        XCTAssertTrue(ok)
        let fresh = try XCTUnwrap(samples.fetchById(sample.id))
        XCTAssertEqual(fresh.elevation, 236)
        XCTAssertEqual(fresh.elevationSource, .backendService)
        XCTAssertEqual(fresh.verticalAccuracy, 4)
        XCTAssertEqual(fresh.locationStatus, .backendService)
        XCTAssertEqual(fresh.locationSource, LocationSource.user.rawValue)
    }

    func testResolveOnline_ManualHeightIsNeverOverwritten() async throws {
        let fake = FakeOrtus(.success(try Self.decode(Self.ochsenfurtJSON)))
        var sample = try samples.createLocal(lat: lat, lon: lon, locationSource: .user)
        sample.elevation = 300
        sample.elevationSource = .manual
        try samples.update(sample)

        _ = await makeResolver(fake).resolveOnline(sampleID: sample.id)

        let fresh = try XCTUnwrap(samples.fetchById(sample.id))
        XCTAssertEqual(fresh.elevation, 300)
        XCTAssertEqual(fresh.elevationSource, .manual)
    }

    func testResolveOnline_Sea_StoresGeoWithoutPlacemark() async throws {
        let fake = FakeOrtus(.success(try Self.decode(Self.seaJSON)))
        let sample = try samples.createLocal(lat: 40, lon: -25, locationSource: .user)

        let ok = await makeResolver(fake).resolveOnline(sampleID: sample.id)

        XCTAssertTrue(ok)
        let fresh = try XCTUnwrap(samples.fetchById(sample.id))
        XCTAssertNil(fresh.placemark)
        XCTAssertEqual(fresh.locationStatus, .backendService)
        XCTAssertNil(fresh.mtbSheetNumber)
        XCTAssertNil(fresh.elevation)
        XCTAssertEqual(try placemarks.count(), 0)
    }

    func testResolveOnline_Failure_ReturnsFalseAndLeavesSampleUntouched() async throws {
        let fake = FakeOrtus(.failure(URLError(.timedOut)))
        let sample = try samples.createLocal(lat: lat, lon: lon, elevation: 250)

        let ok = await makeResolver(fake).resolveOnline(sampleID: sample.id)

        XCTAssertFalse(ok)
        let fresh = try XCTUnwrap(samples.fetchById(sample.id))
        XCTAssertEqual(fresh.locationStatus, .pending)
        XCTAssertNil(fresh.placemark)
    }

    func testResolveOnline_NoClient_ReturnsFalse() async throws {
        let sample = try samples.createLocal(lat: lat, lon: lon)
        let ok = await makeResolver(nil).resolveOnline(sampleID: sample.id)
        XCTAssertFalse(ok)
    }

    func testResolveOnline_ManualPlacemark_KeepsPlacemarkAndSetsSuggestion() async throws {
        let fake = FakeOrtus(.success(try Self.decode(Self.ochsenfurtJSON)))
        let manualPlace = Place(countryISO: "DE",
                                admin: [.municipality: AdminValue(name: "Anderswo", native: "", level: 8)])
        let manual = try placemarks.lookupOrCreate(place: manualPlace, source: .manual)
        var sample = try samples.createLocal(lat: lat, lon: lon, elevation: 250)
        sample.placemark = manual.id
        sample.locationStatus = .manual
        try samples.update(sample)

        let ok = await makeResolver(fake).resolveOnline(sampleID: sample.id)

        XCTAssertTrue(ok)
        let fresh = try XCTUnwrap(samples.fetchById(sample.id))
        XCTAssertEqual(fresh.locationStatus, .manual)
        XCTAssertEqual(fresh.placemark, manual.id)
        let suggestionID = try XCTUnwrap(fresh.placemarkSuggestion)
        XCTAssertNotEqual(suggestionID, manual.id)
        XCTAssertEqual(try placemarks.fetchById(suggestionID)?.admin[.municipality]?.name, "Ochsenfurt")
    }

    // MARK: - offline

    func testInheritOffline_CopiesPlacemarkOfPreviousSample() async throws {
        let fake = FakeOrtus(.success(try Self.decode(Self.ochsenfurtJSON)))
        let first = try samples.createLocal(lat: lat, lon: lon, collectedFrom: Self.morning)
        _ = await makeResolver(fake).resolveOnline(sampleID: first.id)
        let firstPlacemark = try XCTUnwrap(samples.fetchById(first.id)?.placemark)

        let offline = makeResolver(FakeOrtus(.failure(URLError(.notConnectedToInternet))))
        let second = try samples.createLocal(lat: lat, lon: lon,
                                             collectedFrom: Self.morning.addingTimeInterval(600))
        let ok = await offline.resolveOnline(sampleID: second.id)
        XCTAssertFalse(ok)
        try offline.inheritOffline(sampleID: second.id)

        let fresh = try XCTUnwrap(samples.fetchById(second.id))
        XCTAssertEqual(fresh.placemark, firstPlacemark)
        XCTAssertEqual(fresh.locationStatus, .inherited)
    }

    func testInheritOffline_NoPreviousSample_StaysPending() throws {
        let sample = try samples.createLocal(lat: lat, lon: lon)

        try makeResolver(nil).inheritOffline(sampleID: sample.id)

        let fresh = try XCTUnwrap(samples.fetchById(sample.id))
        XCTAssertNil(fresh.placemark)
        XCTAssertEqual(fresh.locationStatus, .pending)
    }

    // MARK: - outbox (Task 16)

    func testResolveOnline_PushedSample_QueuesUpdateWithFeatures() async throws {
        let mutations = PendingMutationsStore(database: database)
        let fake = FakeOrtus(.success(try Self.decode(Self.ochsenfurtJSON)))
        var sample = try samples.createLocal(lat: lat, lon: lon, elevation: 250)
        sample.backendId = "backend-1"
        sample.syncStatus = .synced
        try samples.update(sample)

        let resolver = SampleLocationResolver(ortus: fake, samples: samples, placemarks: placemarks,
                                              features: features, mutations: mutations)
        let ok = await resolver.resolveOnline(sampleID: sample.id)

        XCTAssertTrue(ok)
        let queued = try mutations.fetch(entityType: .sample)
        XCTAssertEqual(queued.map(\.op), [.update])
        XCTAssertEqual(queued.first?.entityId, sample.id)
        XCTAssertEqual(queued.first.map { SampleUpdatePayload.decode($0.payloadJson).pushFeatures }, true)
    }

    func testResolveOnline_UnpushedSample_QueuesNothing() async throws {
        let mutations = PendingMutationsStore(database: database)
        let fake = FakeOrtus(.success(try Self.decode(Self.ochsenfurtJSON)))
        let sample = try samples.createLocal(lat: lat, lon: lon)

        let resolver = SampleLocationResolver(ortus: fake, samples: samples, placemarks: placemarks,
                                              features: features, mutations: mutations)
        _ = await resolver.resolveOnline(sampleID: sample.id)

        XCTAssertEqual(try mutations.count(), 0, "the pending create carries the place data")
    }

    func testInheritOffline_PushedSample_QueuesUpdate() async throws {
        let mutations = PendingMutationsStore(database: database)
        let first = try samples.createLocal(lat: lat, lon: lon, collectedFrom: Self.morning)
        _ = await makeResolver(FakeOrtus(.success(try Self.decode(Self.ochsenfurtJSON))))
            .resolveOnline(sampleID: first.id)
        var second = try samples.createLocal(lat: lat, lon: lon,
                                             collectedFrom: Self.morning.addingTimeInterval(600))
        second.backendId = "backend-2"
        try samples.update(second)

        let resolver = SampleLocationResolver(ortus: nil, samples: samples, placemarks: placemarks,
                                              features: features, mutations: mutations)
        try resolver.inheritOffline(sampleID: second.id)

        let queued = try mutations.fetch(entityType: .sample)
        XCTAssertEqual(queued.map(\.entityId), [second.id])
        XCTAssertEqual(queued.first.map { SampleUpdatePayload.decode($0.payloadJson).pushFeatures }, false)
    }

    // MARK: - LocationProvider fix

    func testLocationFix_PassesVerticalAccuracyAndKeepsZeroAltitude() {
        let fix = LocationProvider.Fix(
            latitude: lat, longitude: lon,
            horizontalAccuracy: 5, verticalAccuracy: 3, altitude: 0
        )
        XCTAssertEqual(fix.elevation, 0)
        XCTAssertEqual(fix.verticalAccuracy, 3)

        let noAltitude = LocationProvider.Fix(
            latitude: lat, longitude: lon,
            horizontalAccuracy: 5, verticalAccuracy: -1, altitude: 123
        )
        XCTAssertNil(noAltitude.elevation)
        XCTAssertNil(noAltitude.verticalAccuracy)
    }

    // MARK: - timezone (Phase Z)

    func testResolveOnline_Timezone_SetsZoneAndSourceKeepsDayAndID() async throws {
        let fake = FakeOrtus(.success(try Self.decode(Self.canaryJSON)))
        let sample = try samples.createLocal(lat: lat, lon: lon, elevation: 250)
        XCTAssertEqual(sample.timezoneSource, .device)

        _ = await makeResolver(fake).resolveOnline(sampleID: sample.id)

        let fresh = try XCTUnwrap(samples.fetchById(sample.id))
        XCTAssertEqual(fresh.timezone, "Atlantic/Canary")
        XCTAssertEqual(fresh.timezoneSource, .locationService)
        XCTAssertEqual(fresh.collectingDay, sample.collectingDay)
        XCTAssertEqual(fresh.fieldtrip, sample.fieldtrip)
        XCTAssertEqual(fresh.sampleID, sample.sampleID)
    }

    func testResolveOnline_ManualTimezoneStays() async throws {
        let fake = FakeOrtus(.success(try Self.decode(Self.canaryJSON)))
        var sample = try samples.createLocal(lat: lat, lon: lon, elevation: 250)
        sample.timezone = "Asia/Kolkata"
        sample.timezoneSource = .manual
        try samples.update(sample)

        _ = await makeResolver(fake).resolveOnline(sampleID: sample.id)

        let fresh = try XCTUnwrap(samples.fetchById(sample.id))
        XCTAssertEqual(fresh.timezone, "Asia/Kolkata")
        XCTAssertEqual(fresh.timezoneSource, .manual)
    }

    func testResolveOnline_NoTimezoneInAnswer_KeepsDeviceZone() async throws {
        let fake = FakeOrtus(.success(try Self.decode(Self.ochsenfurtJSON)))
        let sample = try samples.createLocal(lat: lat, lon: lon, elevation: 250)

        _ = await makeResolver(fake).resolveOnline(sampleID: sample.id)

        let fresh = try XCTUnwrap(samples.fetchById(sample.id))
        XCTAssertEqual(fresh.timezone, sample.timezone)
        XCTAssertEqual(fresh.timezoneSource, .device)
    }

    func testResolveOnline_CanaryZeroHeightWithSourceIsKept() async throws {
        let fake = FakeOrtus(.success(try Self.decode(Self.canaryJSON)))
        let sample = try samples.createLocal(lat: lat, lon: lon, elevation: 0)

        _ = await makeResolver(fake).resolveOnline(sampleID: sample.id)

        let fresh = try XCTUnwrap(samples.fetchById(sample.id))
        XCTAssertEqual(fresh.elevation, 0)
        XCTAssertEqual(fresh.elevationSource, .locationService)
    }

    func testResolveOnline_PushedSample_QueuesUpdateWithNewTimezone() async throws {
        let mutations = PendingMutationsStore(database: database)
        let fake = FakeOrtus(.success(try Self.decode(Self.canaryJSON)))
        var sample = try samples.createLocal(lat: lat, lon: lon, elevation: 250)
        sample.backendId = "backend-1"
        sample.syncStatus = .synced
        try samples.update(sample)

        let resolver = SampleLocationResolver(ortus: fake, samples: samples, placemarks: placemarks,
                                              features: features, mutations: mutations)
        _ = await resolver.resolveOnline(sampleID: sample.id)

        XCTAssertEqual(try mutations.fetch(entityType: .sample).map(\.op), [.update])
        let fresh = try XCTUnwrap(samples.fetchById(sample.id))
        XCTAssertEqual(fresh.timezone, "Atlantic/Canary", "the update reads timezone from the row")
    }

    // MARK: - helpers

    private func makeResolver(_ ortus: OrtusQuerying?) -> SampleLocationResolver {
        SampleLocationResolver(ortus: ortus, samples: samples, placemarks: placemarks, features: features)
    }

    /// 2026-06-05 10:00 Europe/Berlin — well after the 5:00 rollover.
    private static let morning: Date = {
        var c = DateComponents()
        c.year = 2026
        c.month = 6
        c.day = 5
        c.hour = 10
        c.timeZone = TimeZone(identifier: "Europe/Berlin")
        return Calendar(identifier: .gregorian).date(from: c) ?? Date()
    }()

    private static func decode(_ json: String) throws -> OrtusResponse {
        try JSONDecoder().decode(OrtusResponse.self, from: Data(json.utf8))
    }

    /// Trimmed copy of `shared/testdata/ortus/query_de_ochsenfurt.json`.
    private static let ochsenfurtJSON = """
    {
      "wgs84": {"lon": 10.039652, "lat": 49.681616},
      "results": [
        {"source_id": "tk25-blattschnitt-de", "source_name": "tk25-blattschnitt-de.gpkg",
         "features": [{"id": 0, "layer": "sheets",
                       "properties": {"id": "6326", "dtknummer": "6326", "blattname": "Ochsenfurt"}}],
         "license": {"name": "dl-de/by-2-0"}},
        {"source_id": "natura2000-de", "source_name": "natura2000-de.gpkg",
         "features": [{"id": 7, "layer": "ffh", "properties": {"name": "Maintal"}}]}
      ],
      "gazetteer": {
        "admin": {"country_iso": "DE", "hierarchy": [
          {"level": 8, "name": "Ochsenfurt", "name_native": "", "equivalent": "municipality"},
          {"level": 6, "name": "Landkreis Würzburg", "name_native": "", "equivalent": "county"},
          {"level": 5, "name": "Unterfranken", "name_native": "", "equivalent": "region"},
          {"level": 4, "name": "Bayern", "name_native": "", "equivalent": "state"},
          {"level": 2, "name": "Deutschland", "name_native": "", "equivalent": "country"}
        ]},
        "islands": null, "mountains": null,
        "bearing": {"reference": "Ochsenfurt", "distance_km": 2.3, "compass": "WNW",
                    "label": "2 km WNW Ochsenfurt", "inside": false},
        "exposure": {"slope_deg": 8.4, "aspect_deg": 202.5, "aspect_compass": "SSW", "flat": false},
        "elevation": {"meters": 236.0, "accuracy_m": 4.0, "sea_level": false}
      }
    }
    """

    /// Ochsenfurt answer plus a `timezones-2026a` hit (zone is arbitrary here).
    private static let canaryJSON = ochsenfurtJSON.replacingOccurrences(
        of: "\"results\": [",
        with: """
        "results": [
            {"source_id": "timezones-2026a", "source_name": "timezones-2026a.gpkg",
             "features": [{"id": 1, "layer": "zones", "properties": {"tzid": "Atlantic/Canary"}}]},
        """
    )

    /// Copy of `shared/testdata/ortus/query_sea.json` (no admin coverage).
    private static let seaJSON = """
    {
      "wgs84": {"lon": -25.0, "lat": 40.0},
      "results": [],
      "gazetteer": {"admin": null, "islands": null, "mountains": null,
                    "bearing": null, "exposure": null, "elevation": null}
    }
    """
}

/// Records every query and answers with a canned result.
private final class FakeOrtus: OrtusQuerying, @unchecked Sendable {
    private let result: Result<OrtusResponse, Error>
    private(set) var queries: [(lat: Double, lon: Double)] = []

    init(_ result: Result<OrtusResponse, Error>) {
        self.result = result
    }

    func query(lat: Double, lon: Double) async throws -> OrtusResponse {
        queries.append((lat, lon))
        return try result.get()
    }

    func query(input: CoordinateInput) async throws -> OrtusResponse {
        try result.get()
    }
}

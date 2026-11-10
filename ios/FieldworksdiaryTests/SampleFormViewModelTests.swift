@testable import Fieldworksdiary
import FieldworksGeo
import XCTest

/// Phase N: the edit form („Bearbeiten“) — groups Koordinate, Zeit,
/// Ortsdaten, saving on back.
@MainActor
final class SampleFormViewModelTests: XCTestCase {
    private var database: Database!
    private var samples: LocalSampleStore!
    private var placemarks: LocalPlacemarkStore!
    private var features: LocalSampleFeatureStore!
    private var localities: LocalLocalityStore!
    private var mutations: PendingMutationsStore!
    private var sync: SyncRunner!
    // swiftlint:disable force_unwrapping
    private let berlin = TimeZone(identifier: "Europe/Berlin")!
    private let canary = TimeZone(identifier: "Atlantic/Canary")!
    // swiftlint:enable force_unwrapping

    override func setUpWithError() throws {
        try super.setUpWithError()
        database = try Database(inMemory: ())
        samples = LocalSampleStore(
            database: database, userId: "u1", timeZone: berlin,
            settings: { SampleIDSettings(cutoffHour: 5) }
        )
        placemarks = LocalPlacemarkStore(database: database)
        features = LocalSampleFeatureStore(database: database)
        localities = LocalLocalityStore(database: database)
        mutations = PendingMutationsStore(database: database)
        sync = SyncRunner(
            store: samples,
            mutationsStore: mutations,
            localitiesStore: localities,
            endpointProvider: { "" }, // no-op pass on kick()
            retryInterval: .seconds(3600)
        )
    }

    override func tearDownWithError() throws {
        sync = nil
        mutations = nil
        localities = nil
        features = nil
        placemarks = nil
        samples = nil
        database = nil
        try super.tearDownWithError()
    }

    // MARK: - Koordinate

    func testPrefill_StoredCoordinateAsWGS84Decimal_SystemSwitchClears() throws {
        let sample = try seed(lat: 49.68123, lon: 10.03134)
        let vm = makeVM(sample.id, ortus: nil)

        XCTAssertEqual(vm.system, .wgs84)
        XCTAssertEqual(vm.first, "49.681230")
        XCTAssertEqual(vm.second, "10.031340")
        XCTAssertFalse(vm.hasUnappliedCoordinate)

        vm.system = .gk3
        XCTAssertEqual(vm.first, "")
        XCTAssertEqual(vm.second, "")
        XCTAssertFalse(vm.hasUnappliedCoordinate, "empty fields are nothing to discard")
    }

    func testGaussKruegerInput_StoresWGS84OfAnswer_OneRequest() async throws {
        let sample = try seed(lat: 49.0, lon: 10.0)
        let ortus = StubOrtus(.success(try OrtusFixtures.decode(
            OrtusFixtures.answerJSON(lat: 49.6815634, lon: 10.0312817)
        )))
        let vm = makeVM(sample.id, ortus: ortus)
        vm.system = .gk3
        vm.first = "3574500"
        vm.second = "5505500"

        await vm.queryOrtus()

        XCTAssertNil(vm.coordinateError)
        XCTAssertEqual(ortus.inputQueries, [CoordinateInput(system: .gk3, first: "3574500", second: "5505500")])
        XCTAssertEqual(ortus.pointQueries, 0, "the answer is applied without a second request")
        let stored = try XCTUnwrap(samples.fetchById(sample.id))
        XCTAssertEqual(stored.latitude, 49.681563, "WGS84 of the answer, 6 decimals")
        XCTAssertEqual(stored.longitude, 10.031282)
        XCTAssertEqual(stored.locationSource, LocationSource.user.rawValue)
        XCTAssertEqual(stored.locationStatus, .backendService)
        XCTAssertEqual(stored.mtbSheetNumber, "6326")
        XCTAssertEqual(stored.elevation, 236, "DEM height of the answer")
        XCTAssertNotNil(stored.placemark)
        XCTAssertEqual(vm.system, .wgs84, "fields show the taken-over position")
        XCTAssertEqual(vm.first, "49.681563")
        XCTAssertEqual(vm.second, "10.031282")
        XCTAssertFalse(vm.hasUnappliedCoordinate)
        XCTAssertTrue(vm.finishEditing())
    }

    func testOrtusError_CoordinateUnchanged_ErrorShown_TimeSavedAnyway() async throws {
        let sample = try seed(lat: 49.0, lon: 10.0)
        let vm = makeVM(sample.id, ortus: StubOrtus(.failure(OrtusQueryError.server(message: "invalid input"))))
        vm.system = .gk3
        vm.first = "3574500"
        vm.second = "1"
        let newBegin = sample.beginDate.addingTimeInterval(3600)
        vm.setBeginDate(newBegin)

        await vm.queryOrtus()

        XCTAssertEqual(vm.coordinateError, "Ortus konnte die Koordinate nicht umrechnen: invalid input")
        XCTAssertEqual(vm.system, .gk3, "input stays")
        XCTAssertEqual(vm.first, "3574500")
        XCTAssertEqual(vm.second, "1")
        var stored = try XCTUnwrap(samples.fetchById(sample.id))
        XCTAssertEqual(stored.latitude, 49.0)
        XCTAssertEqual(stored.longitude, 10.0)

        XCTAssertFalse(vm.finishEditing(), "unapplied input asks first")
        XCTAssertTrue(vm.askDiscardCoordinate)
        stored = try XCTUnwrap(samples.fetchById(sample.id))
        XCTAssertEqual(stored.beginDate, newBegin, "time is saved regardless")
        XCTAssertEqual(stored.latitude, 49.0)
    }

    func testOffline_NoClient_OfflineMessage() async throws {
        let sample = try seed(lat: 49.0, lon: 10.0)
        let vm = makeVM(sample.id, ortus: nil)
        vm.first = "49.5"

        await vm.queryOrtus()

        XCTAssertEqual(vm.coordinateError, "Keine Verbindung zu Ortus. Bitte später erneut versuchen.")
    }

    func testInvalidInput_LocalMessage_NoRequest() async throws {
        let sample = try seed(lat: 49.0, lon: 10.0)
        let ortus = StubOrtus(.failure(OrtusQueryError.offline))
        let vm = makeVM(sample.id, ortus: ortus)
        vm.system = .gk3

        await vm.queryOrtus()

        XCTAssertEqual(vm.coordinateError, "Bitte eine gültige Koordinate eingeben.")
        XCTAssertTrue(ortus.inputQueries.isEmpty)
    }

    func testHeightChanged_StoredAsManual() throws {
        let sample = try seed(lat: 49.0, lon: 10.0)
        let vm = makeVM(sample.id, ortus: nil)
        let place = try XCTUnwrap(vm.place)
        place.elevationText = "312"

        XCTAssertTrue(vm.finishEditing())

        let stored = try XCTUnwrap(samples.fetchById(sample.id))
        XCTAssertEqual(stored.elevation, 312)
        XCTAssertEqual(stored.elevationSource, .manual)
    }

    func testHorizontalAccuracy_Saved() throws {
        let sample = try seed(lat: 49.0, lon: 10.0)
        let vm = makeVM(sample.id, ortus: nil)
        vm.horizontalAccuracyText = "7,5"

        XCTAssertTrue(vm.finishEditing())

        XCTAssertEqual(try XCTUnwrap(samples.fetchById(sample.id)).horizontalAccuracy, 7.5)
    }

    func testBackWithUnappliedInput_AsksDiscard_DiscardResetsInput() throws {
        let sample = try seed(lat: 49.68123, lon: 10.03134)
        let vm = makeVM(sample.id, ortus: nil)
        vm.first = "49.9"

        XCTAssertFalse(vm.finishEditing())
        XCTAssertTrue(vm.askDiscardCoordinate)
        XCTAssertFalse(vm.finished)

        vm.keepEditing()
        XCTAssertFalse(vm.askDiscardCoordinate)
        XCTAssertEqual(vm.first, "49.9", "„Weiter bearbeiten“ keeps the input")

        XCTAssertFalse(vm.finishEditing())
        vm.discardCoordinateAndFinish()
        XCTAssertTrue(vm.finished)
        XCTAssertEqual(vm.first, "49.681230")
        XCTAssertEqual(try XCTUnwrap(samples.fetchById(sample.id)).latitude, 49.68123)
    }

    func testManualPlace_QueryAsksFirst_KeepKeepsPlacemark() async throws {
        let sample = try seed(lat: 49.0, lon: 10.0)
        let ortus = StubOrtus(.success(try OrtusFixtures.decode(
            OrtusFixtures.answerJSON(lat: 49.68123, lon: 10.03134)
        )))
        let vm = makeVM(sample.id, ortus: ortus)
        let place = try XCTUnwrap(vm.place)
        place.selectCountry("DE")
        let field = try XCTUnwrap(place.fields.first)
        place.setValue("Handort", for: field.id)
        vm.first = "49.68123"
        vm.second = "10.03134"

        await vm.queryOrtus()

        XCTAssertTrue(vm.askRetakePlace, "typed place is saved first and counts as manual")
        let manual = try XCTUnwrap(samples.fetchById(sample.id))
        XCTAssertEqual(manual.locationStatus, .manual)
        XCTAssertEqual(manual.latitude, 49.0, "nothing written before the answer")

        vm.applyCorrection(keepManualPlace: true)

        let stored = try XCTUnwrap(samples.fetchById(sample.id))
        XCTAssertEqual(stored.latitude, 49.68123)
        XCTAssertEqual(stored.locationStatus, .manual)
        XCTAssertEqual(stored.placemark, manual.placemark, "the manual place stays")
    }

    // MARK: - Zeit

    func testAllDayOn_MidnightInCanary_NoEnd() throws {
        // 2026-11-10 10:07 Atlantic/Canary.
        let begin = try Self.date("2026-11-10 10:07", canary)
        let sample = try seed(lat: 28.68, lon: -17.76, begin: begin, zone: "Atlantic/Canary")
        let vm = makeVM(sample.id, ortus: nil)

        vm.setAllDay(true)
        XCTAssertTrue(vm.finishEditing())

        let stored = try XCTUnwrap(samples.fetchById(sample.id))
        XCTAssertTrue(stored.isAllDay)
        XCTAssertEqual(stored.beginDate, try Self.date("2026-11-10 00:00", canary))
        XCTAssertNil(stored.endDate)
        XCTAssertEqual(stored.collectingDay, "2026-11-10", "retrospective day = calendar day")
    }

    func testAllDayOff_DefaultWindowFromMidnight() throws {
        let begin = try Self.date("2026-11-10 10:07", canary)
        let sample = try seed(lat: 28.68, lon: -17.76, begin: begin, zone: "Atlantic/Canary")
        let vm = makeVM(sample.id, ortus: nil)

        vm.setAllDay(true)
        vm.setAllDay(false)
        vm.saveEdits()

        let stored = try XCTUnwrap(samples.fetchById(sample.id))
        let midnight = try Self.date("2026-11-10 00:00", canary)
        XCTAssertFalse(stored.isAllDay)
        XCTAssertEqual(stored.beginDate, midnight)
        XCTAssertEqual(stored.endDate, midnight.addingTimeInterval(15 * 60))
    }

    func testAllDay_ZoneChangeKeepsCalendarDay() throws {
        let begin = try Self.date("2026-11-10 10:07", canary)
        let sample = try seed(lat: 28.68, lon: -17.76, begin: begin, zone: "Atlantic/Canary")
        let vm = makeVM(sample.id, ortus: nil)

        vm.setAllDay(true)
        vm.setTimezone("Europe/Berlin")
        vm.saveEdits()

        let stored = try XCTUnwrap(samples.fetchById(sample.id))
        XCTAssertEqual(stored.beginDate, try Self.date("2026-11-10 00:00", berlin))
        XCTAssertEqual(stored.timezone, "Europe/Berlin")
        XCTAssertEqual(stored.timezoneSource, .manual)
    }

    func testNoChanges_WritesNothing() throws {
        let sample = try seed(lat: 49.0, lon: 10.0)
        let before = try mutations.count()
        let vm = makeVM(sample.id, ortus: nil)

        XCTAssertTrue(vm.finishEditing())

        XCTAssertEqual(try mutations.count(), before)
        XCTAssertEqual(try XCTUnwrap(samples.fetchById(sample.id)), sample)
    }

    // MARK: - helpers

    private func seed(
        lat: Double?, lon: Double?, begin: Date? = nil, zone: String = "Europe/Berlin"
    ) throws -> LocalSample {
        try samples.createRetrospective(
            code: "Altfund 1", latitude: lat, longitude: lon,
            beginDate: begin ?? Self.date("2026-11-10 10:07", berlin),
            timezone: zone, timezoneSource: .locationService, mutationsStore: mutations
        )
    }

    private func makeVM(_ id: String, ortus: OrtusQuerying?) -> SampleFormViewModel {
        // The resolver shares the stub, so a second request would show
        // up in its `pointQueries`.
        let resolver = SampleLocationResolver(
            ortus: ortus, samples: samples, placemarks: placemarks, features: features, mutations: mutations
        )
        return SampleFormViewModel(
            sampleID: id, store: samples, localitiesStore: localities, placemarkStore: placemarks,
            mutationsStore: mutations, sync: sync, ortus: ortus, resolver: resolver
        )
    }

    private static func date(_ text: String, _ zone: TimeZone) throws -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return try XCTUnwrap(formatter.date(from: text))
    }
}

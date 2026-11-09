@testable import Fieldworksdiary
import FieldworksGeo
import XCTest

/// `PlaceEditorViewModel` (Phase O2, Task 17): country first, then
/// only that country's levels plus island / mountain range / mountain;
/// saving detaches only this sample onto a manual placemark.
@MainActor
final class PlaceEditorViewModelTests: XCTestCase {
    private var database: Database!
    private var samples: LocalSampleStore!
    private var placemarks: LocalPlacemarkStore!
    private var mutations: PendingMutationsStore!
    // swiftlint:disable:next force_unwrapping
    private let berlin = TimeZone(identifier: "Europe/Berlin")!

    private let ochsenfurt = Place(
        countryISO: "DE",
        admin: [
            .country: AdminValue(name: "Deutschland", level: 2),
            .state: AdminValue(name: "Bayern", level: 4),
            .county: AdminValue(name: "Landkreis Würzburg", native: "Lkr. Würzburg", level: 6),
            .municipality: AdminValue(name: "Ochsenfurt", level: 8)
        ]
    )

    override func setUpWithError() throws {
        try super.setUpWithError()
        database = try Database(inMemory: ())
        samples = LocalSampleStore(database: database, userId: "u1", timeZone: berlin, settings: { SampleIDSettings(cutoffHour: 5) })
        placemarks = LocalPlacemarkStore(database: database)
        mutations = PendingMutationsStore(database: database)
    }

    override func tearDownWithError() throws {
        samples = nil
        placemarks = nil
        mutations = nil
        database = nil
        try super.tearDownWithError()
    }

    // MARK: - fields

    func testSelectCountry_ShowsOnlyThatCountrysLevelsPlusLandscape() throws {
        let vm = try makeVM(sample: seedSample(placemark: nil))
        vm.selectCountry("DE")

        let terms = vm.fields.map(\.displayTerm)
        XCTAssertEqual(Array(terms.prefix(3)), ["Staat", "Bundesland", "Regierungsbezirk"])
        XCTAssertTrue(terms.contains("Landkreis"))
        XCTAssertTrue(terms.contains("Gemeinde"))
        XCTAssertFalse(terms.contains("Provincia"))
        XCTAssertEqual(Array(terms.suffix(3)), ["Insel", "Gebirge", "Berg"])
        XCTAssertEqual(vm.fields.first { $0.tier == .county }?.genericLabel, "Kreis")
        XCTAssertEqual(vm.form.values[AdminTier.country.rawValue], "Deutschland", "country tier prefilled")

        vm.selectCountry("ES")
        let esTerms = vm.fields.map(\.displayTerm)
        XCTAssertTrue(esTerms.contains("Comunidad autónoma"))
        XCTAssertTrue(esTerms.contains("Provincia"))
        XCTAssertTrue(esTerms.contains("Municipio"))
        XCTAssertFalse(esTerms.contains("Landkreis"))
        XCTAssertEqual(vm.form.values[AdminTier.country.rawValue], "Spanien", "prefill follows the country")
    }

    func testInit_PrefillsFromCurrentPlacemark() throws {
        let pm = try placemarks.lookupOrCreate(place: ochsenfurt, source: .backendService)
        let vm = try makeVM(sample: seedSample(placemark: pm.id))
        XCTAssertEqual(vm.form.countryISO, "DE")
        XCTAssertEqual(vm.form.values[AdminTier.municipality.rawValue], "Ochsenfurt")
        XCTAssertFalse(vm.canSave, "nothing changed yet")
    }

    func testCountries_ComeFromLabelTableWithGermanNames() throws {
        let vm = try makeVM(sample: seedSample(placemark: nil))
        XCTAssertTrue(vm.countries.contains { $0.iso == "DE" && $0.name == "Deutschland" })
        XCTAssertTrue(vm.countries.contains { $0.iso == "ES" && $0.name == "Spanien" })
    }

    // MARK: - save

    func testSave_DetachesOnlyThisSampleOntoManualPlacemark() throws {
        let shared = try placemarks.lookupOrCreate(place: ochsenfurt, source: .backendService)
        let edited = try seedSample(placemark: shared.id, backendID: "backend-1")
        let other = try seedSample(placemark: shared.id, backendID: "backend-2")

        let vm = try makeVM(sample: edited)
        vm.setValue("Sommerhausen", for: AdminTier.municipality.rawValue)
        XCTAssertTrue(vm.canSave)
        XCTAssertTrue(vm.save())

        let stored = try XCTUnwrap(samples.fetchById(edited.id))
        XCTAssertEqual(stored.locationStatus, .manual)
        XCTAssertNil(stored.placemarkSuggestion)
        let manual = try XCTUnwrap(stored.placemark.flatMap { try placemarks.fetchById($0) })
        XCTAssertNotEqual(manual.id, shared.id)
        XCTAssertEqual(manual.geocodingSource, "manual")
        XCTAssertEqual(manual.admin[.municipality]?.name, "Sommerhausen")
        XCTAssertEqual(manual.admin[.municipality]?.level, 8)
        XCTAssertEqual(manual.admin[.county]?.native, "Lkr. Würzburg", "unchanged native kept")

        let untouched = try XCTUnwrap(samples.fetchById(other.id))
        XCTAssertEqual(untouched.placemark, shared.id, "other samples keep the shared placemark")
        XCTAssertEqual(untouched.locationStatus, .backendService)
        XCTAssertEqual(try placemarks.fetchById(shared.id)?.admin[.municipality]?.name, "Ochsenfurt",
                       "the shared row itself is never edited")

        let queued = try mutations.fetch(entityType: .sample)
        XCTAssertEqual(queued.count, 1)
        XCTAssertEqual(queued.first?.entityId, edited.id)
        XCTAssertEqual(queued.first?.op, .update)
        XCTAssertTrue(SampleUpdatePayload.decode(queued.first?.payloadJson ?? Data()).clearsSuggestion)
    }

    func testSave_DropsValuesOfLevelsTheNewCountryDoesNotHave() throws {
        let pm = try placemarks.lookupOrCreate(place: ochsenfurt, source: .backendService)
        let vm = try makeVM(sample: seedSample(placemark: pm.id))
        vm.selectCountry("AT")
        vm.setValue("Innsbruck", for: AdminTier.municipality.rawValue)
        XCTAssertTrue(vm.save())

        let stored = try XCTUnwrap(samples.fetchById(vm.sampleID))
        let manual = try XCTUnwrap(stored.placemark.flatMap { try placemarks.fetchById($0) })
        XCTAssertEqual(manual.countryISO, "AT")
        XCTAssertNil(manual.admin[.county], "AT has no admin_county level")
        XCTAssertEqual(manual.admin[.municipality]?.name, "Innsbruck")
        XCTAssertNil(manual.admin[.municipality]?.native.nilIfEmptyForTest, "native dropped on country change")
    }

    func testSave_LandscapeFields() throws {
        let vm = try makeVM(sample: seedSample(placemark: nil))
        vm.selectCountry("ES")
        vm.setValue("La Palma", for: PlaceForm.islandID)
        vm.setValue("Caldera de Taburiente", for: PlaceForm.mountainRangeID)
        vm.setValue("Roque de los Muchachos", for: PlaceForm.mountainID)
        XCTAssertTrue(vm.save())

        let stored = try XCTUnwrap(samples.fetchById(vm.sampleID))
        let manual = try XCTUnwrap(stored.placemark.flatMap { try placemarks.fetchById($0) })
        XCTAssertEqual(manual.island, "La Palma")
        XCTAssertEqual(manual.mountainRange, "Caldera de Taburiente")
        XCTAssertEqual(manual.mountain, "Roque de los Muchachos")
        XCTAssertEqual(try mutations.count(), 0, "unpushed sample: the pending create carries it")
    }

    func testSave_ElevationOnly_SetsManualSourceWithoutTouchingPlace() throws {
        let pm = try placemarks.lookupOrCreate(place: ochsenfurt, source: .backendService)
        let sample = try seedSample(placemark: pm.id, backendID: "backend-1")
        let vm = try makeVM(sample: sample)
        vm.elevationText = "312,5"
        XCTAssertTrue(vm.canSave)
        XCTAssertTrue(vm.save())

        let stored = try XCTUnwrap(samples.fetchById(sample.id))
        XCTAssertEqual(stored.elevation, 312.5)
        XCTAssertEqual(stored.elevationSource, .manual)
        XCTAssertEqual(stored.placemark, pm.id)
        XCTAssertEqual(stored.locationStatus, .backendService, "place untouched")
        XCTAssertEqual(try mutations.count(), 1)
    }

    func testElevationOnly_WithTierOutsideTheTable_KeepsPlaceUntouched() throws {
        var withOther = ochsenfurt
        withOther.admin[.other] = AdminValue(name: "Flur Am Hang", level: 11)
        let pm = try placemarks.lookupOrCreate(place: withOther, source: .backendService)
        let sample = try seedSample(placemark: pm.id, backendID: "backend-1")
        let vm = try makeVM(sample: sample)
        XCTAssertFalse(vm.placeChanged, "opening the sheet changes nothing")
        XCTAssertFalse(vm.canSave)

        vm.elevationText = "300"
        XCTAssertTrue(vm.save())

        let stored = try XCTUnwrap(samples.fetchById(sample.id))
        XCTAssertEqual(stored.placemark, pm.id, "height-only save never detaches the sample")
        XCTAssertEqual(stored.locationStatus, .backendService)
        XCTAssertEqual(stored.elevationSource, .manual)
        XCTAssertEqual(try placemarks.count(), 1, "no manual placemark created")
    }

    func testCountryOutsideTheTable_IsNotChangedOnOpen() throws {
        let place = Place(countryISO: "ZZ", admin: [.state: AdminValue(name: "Nowhere", level: 4)])
        let pm = try placemarks.lookupOrCreate(place: place, source: .backendService)
        let vm = try makeVM(sample: seedSample(placemark: pm.id))
        XCTAssertFalse(vm.placeChanged)
        XCTAssertFalse(vm.canSave)
    }

    func testEditingOneField_KeepsLevelsTheFormDoesNotShow() throws {
        var withOther = ochsenfurt
        withOther.admin[.other] = AdminValue(name: "Flur Am Hang", level: 11)
        let pm = try placemarks.lookupOrCreate(place: withOther, source: .backendService)
        let vm = try makeVM(sample: seedSample(placemark: pm.id))
        vm.setValue("Sommerhausen", for: AdminTier.municipality.rawValue)
        XCTAssertTrue(vm.save())

        let stored = try XCTUnwrap(samples.fetchById(vm.sampleID))
        let manual = try XCTUnwrap(stored.placemark.flatMap { try placemarks.fetchById($0) })
        XCTAssertEqual(manual.admin[.other], AdminValue(name: "Flur Am Hang", level: 11))
        XCTAssertEqual(manual.admin[.municipality]?.name, "Sommerhausen")
    }

    func testInvalidElevation_BlocksSave() throws {
        let vm = try makeVM(sample: seedSample(placemark: nil))
        vm.elevationText = "hoch"
        XCTAssertFalse(vm.canSave)
        XCTAssertNotNil(vm.elevationError)
    }

    // MARK: - helpers

    private func makeVM(sample: LocalSample) throws -> PlaceEditorViewModel {
        try XCTUnwrap(PlaceEditorViewModel(
            sampleID: sample.id,
            store: samples,
            placemarks: placemarks,
            mutationsStore: mutations
        ))
    }

    private func seedSample(placemark: String?, backendID: String? = nil) throws -> LocalSample {
        var sample = try samples.createLocal(lat: 49.68, lon: 10.04, elevation: 250)
        sample.placemark = placemark
        sample.locationStatus = placemark == nil ? .pending : .backendService
        if let backendID {
            sample.backendId = backendID
            sample.syncStatus = .synced
        }
        try samples.update(sample)
        return try XCTUnwrap(samples.fetchById(sample.id))
    }
}

private extension String {
    var nilIfEmptyForTest: String? {
        isEmpty ? nil : self
    }
}

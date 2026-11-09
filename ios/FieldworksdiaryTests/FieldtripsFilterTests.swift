@testable import Fieldworksdiary
import FieldworksGeo
import XCTest

final class FieldtripsFilterTests: XCTestCase {
    private func fieldtrip(
        day: String = "2026-05-10",
        doy: Int? = 130,
        country: String? = "Deutschland",
        id: String = UUID().uuidString,
        notes: String = "",
        lat: Double? = nil,
        lon: Double? = nil
    ) -> LocalFieldtrip {
        LocalFieldtrip(
            id: id,
            title: "Test",
            collectingDay: day,
            nightFieldtrip: false,
            beginDate: nil,
            endDate: nil,
            centroidLat: lat,
            centroidLon: lon,
            adminUnitsJson: nil,
            mtbJson: nil,
            astroJson: nil,
            locality: nil,
            suggestedLocality: nil,
            dayOfYear: doy,
            country: country,
            adminArea: nil,
            permitNumber: nil,
            permitPDFFile: nil,
            notes: notes,
            version: 1,
            backendUpdatedAt: Date()
        )
    }

    func testFilterOff_MatchesAll() {
        let filter = FieldtripsFilter.none
        XCTAssertTrue(filter.matches(fieldtrip()))
        XCTAssertTrue(filter.matches(fieldtrip(country: nil)))
    }

    func testAbsoluteRange_InsideMatches() throws {
        let cal = Calendar(identifier: .gregorian)
        let from = try XCTUnwrap(cal.date(from: DateComponents(year: 2026, month: 5, day: 1)))
        let to = try XCTUnwrap(cal.date(from: DateComponents(year: 2026, month: 5, day: 31)))
        var filter = FieldtripsFilter()
        filter.date = .absolute(from: from, to: to)
        XCTAssertTrue(filter.matches(fieldtrip(day: "2026-05-10")))
        XCTAssertFalse(filter.matches(fieldtrip(day: "2026-06-01")))
        XCTAssertFalse(filter.matches(fieldtrip(day: "2026-04-30")))
    }

    func testSeasonalRange_NoWrap() {
        var filter = FieldtripsFilter()
        filter.date = .seasonal(fromDOY: 105, toDOY: 135) // 15.04.–15.05.
        XCTAssertTrue(filter.matches(fieldtrip(doy: 105)))
        XCTAssertTrue(filter.matches(fieldtrip(doy: 135)))
        XCTAssertTrue(filter.matches(fieldtrip(doy: 120)))
        XCTAssertFalse(filter.matches(fieldtrip(doy: 104)))
        XCTAssertFalse(filter.matches(fieldtrip(doy: 136)))
        XCTAssertFalse(filter.matches(fieldtrip(doy: nil)))
    }

    func testSeasonalRange_WrapsAcrossYear() {
        var filter = FieldtripsFilter()
        filter.date = .seasonal(fromDOY: 349, toDOY: 15) // 15.12.–15.01.
        XCTAssertTrue(filter.matches(fieldtrip(doy: 349)))
        XCTAssertTrue(filter.matches(fieldtrip(doy: 360)))
        XCTAssertTrue(filter.matches(fieldtrip(doy: 1)))
        XCTAssertTrue(filter.matches(fieldtrip(doy: 15)))
        XCTAssertFalse(filter.matches(fieldtrip(doy: 16)))
        XCTAssertFalse(filter.matches(fieldtrip(doy: 348)))
    }

    // MARK: - Task 17: Land / Ort over the samples' places

    private let ochsenfurt = Place(
        countryISO: "DE",
        admin: [
            .country: AdminValue(name: "Deutschland", level: 2),
            .state: AdminValue(name: "Bayern", level: 4),
            .municipality: AdminValue(name: "Ochsenfurt", level: 8)
        ]
    )

    private var garafia: Place {
        var p = Place(countryISO: "ES", admin: [.municipality: AdminValue(name: "Garafía", level: 8)])
        p.island = "La Palma"
        return p
    }

    func testCountryFilter_MatchesWhenOneSampleIsInThatCountry() {
        var filter = FieldtripsFilter()
        filter.country = "ES"
        XCTAssertTrue(filter.isActive)
        XCTAssertTrue(filter.matches(fieldtrip(), places: [ochsenfurt, garafia]))
        XCTAssertFalse(filter.matches(fieldtrip(), places: [ochsenfurt]))
        XCTAssertFalse(filter.matches(fieldtrip(), places: []), "no sample places ⇒ no match")
    }

    func testCountryFilter_IgnoresLegacyFieldtripCountry() {
        var filter = FieldtripsFilter()
        filter.country = "ES"
        XCTAssertFalse(filter.matches(fieldtrip(country: "ES"), places: [ochsenfurt]),
                       "LocalFieldtrip.country is no longer read")
    }

    func testPlaceQuery_SearchesAllPlaceFields() {
        var filter = FieldtripsFilter()
        filter.placeQuery = "palma"
        XCTAssertTrue(filter.isActive)
        XCTAssertTrue(filter.matches(fieldtrip(), places: [ochsenfurt, garafia]), "island field")
        XCTAssertFalse(filter.matches(fieldtrip(), places: [ochsenfurt]))
        filter.placeQuery = "bayern"
        XCTAssertTrue(filter.matches(fieldtrip(), places: [ochsenfurt]), "state field, case-insensitive")
        filter.placeQuery = "   "
        XCTAssertFalse(filter.isActive, "blank query is off")
        XCTAssertTrue(filter.matches(fieldtrip(), places: []))
    }

    func testCountryAndPlaceQuery_MustHoldForTheSameSample() {
        var filter = FieldtripsFilter()
        filter.country = "DE"
        filter.placeQuery = "Palma"
        XCTAssertFalse(filter.matches(fieldtrip(), places: [ochsenfurt, garafia]))
        filter.placeQuery = "Ochsen"
        XCTAssertTrue(filter.matches(fieldtrip(), places: [ochsenfurt, garafia]))
    }

    func testCombined_SeasonalAndCountry() {
        var filter = FieldtripsFilter()
        filter.date = .seasonal(fromDOY: 105, toDOY: 135)
        filter.country = "ES"
        XCTAssertTrue(filter.matches(fieldtrip(doy: 115), places: [garafia]))
        XCTAssertFalse(filter.matches(fieldtrip(doy: 115), places: [ochsenfurt])) // wrong country
        XCTAssertFalse(filter.matches(fieldtrip(doy: 200), places: [garafia])) // wrong DOY
    }

    func testApply_UsesThePlaceIndexPerFieldtrip() {
        var filter = FieldtripsFilter()
        filter.country = "ES"
        let a = fieldtrip(id: "ft-a")
        let b = fieldtrip(id: "ft-b")
        let result = filter.apply(to: [a, b], places: ["ft-a": [ochsenfurt], "ft-b": [garafia]])
        XCTAssertEqual(result.map(\.id), ["ft-b"])
    }

    func testPlaceIndex_GroupsSamplePlacesByFieldtrip() {
        let pmDE = LocalPlacemark(id: "pm-de", place: ochsenfurt, source: .backendService)
        let pmES = LocalPlacemark(id: "pm-es", place: garafia, source: .manual)
        let index = FieldtripsFilter.placeIndex(
            samples: [
                (fieldtrip: "ft-a", placemark: "pm-de"),
                (fieldtrip: "ft-a", placemark: "pm-es"),
                (fieldtrip: "ft-b", placemark: nil),
                (fieldtrip: nil, placemark: "pm-de")
            ],
            placemarks: ["pm-de": pmDE, "pm-es": pmES]
        )
        XCTAssertEqual(index["ft-a"]?.map(\.countryISO), ["DE", "ES"])
        XCTAssertNil(index["ft-b"])
        XCTAssertEqual(FieldtripsFilter.countries(in: index), ["DE", "ES"])
    }

    func testDayOfYearFromMonthDay() {
        XCTAssertEqual(DayOfYear.from(month: 1, day: 1), 1)
        XCTAssertEqual(DayOfYear.from(month: 4, day: 15), 105)
        XCTAssertEqual(DayOfYear.from(month: 5, day: 15), 135)
        XCTAssertEqual(DayOfYear.from(month: 12, day: 31), 365)
    }

    // MARK: - R8e property filters

    func testRequireNotes() {
        var filter = FieldtripsFilter.none
        filter.requireNotes = true
        XCTAssertTrue(filter.isActive)
        XCTAssertTrue(filter.matches(fieldtrip(notes: "Bei Regen gesammelt")))
        XCTAssertFalse(filter.matches(fieldtrip(notes: "")))
        XCTAssertFalse(filter.matches(fieldtrip(notes: "   ")), "whitespace counts as empty")
    }

    func testRequireCoordinate() {
        var filter = FieldtripsFilter.none
        filter.requireCoordinate = true
        XCTAssertTrue(filter.matches(fieldtrip(lat: 49.79, lon: 9.94)))
        XCTAssertFalse(filter.matches(fieldtrip(lat: nil, lon: nil)))
        XCTAssertFalse(filter.matches(fieldtrip(lat: 49.79, lon: nil)), "needs both")
    }

    func testFieldtripIDSubstringCaseInsensitive() {
        var filter = FieldtripsFilter.none
        filter.fieldtripID = "ABC"
        XCTAssertTrue(filter.isActive)
        XCTAssertTrue(filter.matches(fieldtrip(id: "xx-abc-123")))
        XCTAssertFalse(filter.matches(fieldtrip(id: "xx-def-123")))
    }

    func testPropertyFiltersCombineWithCountry() {
        var filter = FieldtripsFilter.none
        filter.country = "DE"
        filter.requireNotes = true
        // country matches but no notes → excluded
        XCTAssertFalse(filter.matches(fieldtrip(notes: ""), places: [ochsenfurt]))
        XCTAssertTrue(filter.matches(fieldtrip(notes: "x"), places: [ochsenfurt]))
    }
}

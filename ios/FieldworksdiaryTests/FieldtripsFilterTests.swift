@testable import Fieldworksdiary
import XCTest

final class FieldtripsFilterTests: XCTestCase {
    private func fieldtrip(
        day: String = "2026-05-10",
        doy: Int? = 130,
        country: String? = "Deutschland"
    ) -> LocalFieldtrip {
        LocalFieldtrip(
            id: UUID().uuidString,
            name: "Test",
            collectingDay: day,
            nightFieldtrip: false,
            startedAt: nil,
            endedAt: nil,
            centroidLat: nil,
            centroidLon: nil,
            adminUnitsJson: nil,
            mtbJson: nil,
            astroJson: nil,
            locality: nil,
            suggestedLocality: nil,
            dayOfYear: doy,
            country: country,
            adminArea: nil,
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

    func testCountryFilter() {
        var filter = FieldtripsFilter()
        filter.country = "Spanien"
        XCTAssertTrue(filter.matches(fieldtrip(country: "Spanien")))
        XCTAssertFalse(filter.matches(fieldtrip(country: "Deutschland")))
        XCTAssertFalse(filter.matches(fieldtrip(country: nil)))
    }

    func testCombined_SeasonalAndCountry() {
        var filter = FieldtripsFilter()
        filter.date = .seasonal(fromDOY: 105, toDOY: 135)
        filter.country = "Spanien"
        XCTAssertTrue(filter.matches(fieldtrip(doy: 115, country: "Spanien")))
        XCTAssertFalse(filter.matches(fieldtrip(doy: 115, country: "Deutschland"))) // wrong country
        XCTAssertFalse(filter.matches(fieldtrip(doy: 200, country: "Spanien"))) // wrong DOY
    }

    func testDayOfYearFromMonthDay() {
        XCTAssertEqual(DayOfYear.from(month: 1, day: 1), 1)
        XCTAssertEqual(DayOfYear.from(month: 4, day: 15), 105)
        XCTAssertEqual(DayOfYear.from(month: 5, day: 15), 135)
        XCTAssertEqual(DayOfYear.from(month: 12, day: 31), 365)
    }
}

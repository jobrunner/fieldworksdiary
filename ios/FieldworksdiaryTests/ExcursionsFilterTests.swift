import XCTest
@testable import Weevilapp

final class ExcursionsFilterTests: XCTestCase {
    private func excursion(
        day: String = "2026-05-10",
        doy: Int? = 130,
        country: String? = "Deutschland"
    ) -> LocalExcursion {
        LocalExcursion(
            id: UUID().uuidString,
            name: "Test",
            collectingDay: day,
            nightExcursion: false,
            startedAt: nil, endedAt: nil,
            centroidLat: nil, centroidLon: nil,
            adminUnitsJson: nil, mtbJson: nil, astroJson: nil,
            locality: nil, suggestedLocality: nil,
            dayOfYear: doy,
            country: country,
            adminArea: nil,
            backendUpdatedAt: Date()
        )
    }

    func testFilterOff_MatchesAll() {
        let filter = ExcursionsFilter.none
        XCTAssertTrue(filter.matches(excursion()))
        XCTAssertTrue(filter.matches(excursion(country: nil)))
    }

    func testAbsoluteRange_InsideMatches() {
        let cal = Calendar(identifier: .gregorian)
        let from = cal.date(from: DateComponents(year: 2026, month: 5, day: 1))!
        let to   = cal.date(from: DateComponents(year: 2026, month: 5, day: 31))!
        var filter = ExcursionsFilter()
        filter.date = .absolute(from: from, to: to)
        XCTAssertTrue(filter.matches(excursion(day: "2026-05-10")))
        XCTAssertFalse(filter.matches(excursion(day: "2026-06-01")))
        XCTAssertFalse(filter.matches(excursion(day: "2026-04-30")))
    }

    func testSeasonalRange_NoWrap() {
        var filter = ExcursionsFilter()
        filter.date = .seasonal(fromDOY: 105, toDOY: 135) // 15.04.–15.05.
        XCTAssertTrue(filter.matches(excursion(doy: 105)))
        XCTAssertTrue(filter.matches(excursion(doy: 135)))
        XCTAssertTrue(filter.matches(excursion(doy: 120)))
        XCTAssertFalse(filter.matches(excursion(doy: 104)))
        XCTAssertFalse(filter.matches(excursion(doy: 136)))
        XCTAssertFalse(filter.matches(excursion(doy: nil)))
    }

    func testSeasonalRange_WrapsAcrossYear() {
        var filter = ExcursionsFilter()
        filter.date = .seasonal(fromDOY: 349, toDOY: 15)  // 15.12.–15.01.
        XCTAssertTrue(filter.matches(excursion(doy: 349)))
        XCTAssertTrue(filter.matches(excursion(doy: 360)))
        XCTAssertTrue(filter.matches(excursion(doy: 1)))
        XCTAssertTrue(filter.matches(excursion(doy: 15)))
        XCTAssertFalse(filter.matches(excursion(doy: 16)))
        XCTAssertFalse(filter.matches(excursion(doy: 348)))
    }

    func testCountryFilter() {
        var filter = ExcursionsFilter()
        filter.country = "Spanien"
        XCTAssertTrue(filter.matches(excursion(country: "Spanien")))
        XCTAssertFalse(filter.matches(excursion(country: "Deutschland")))
        XCTAssertFalse(filter.matches(excursion(country: nil)))
    }

    func testCombined_SeasonalAndCountry() {
        var filter = ExcursionsFilter()
        filter.date = .seasonal(fromDOY: 105, toDOY: 135)
        filter.country = "Spanien"
        XCTAssertTrue(filter.matches(excursion(doy: 115, country: "Spanien")))
        XCTAssertFalse(filter.matches(excursion(doy: 115, country: "Deutschland"))) // wrong country
        XCTAssertFalse(filter.matches(excursion(doy: 200, country: "Spanien")))     // wrong DOY
    }

    func testDayOfYearFromMonthDay() {
        XCTAssertEqual(DayOfYear.from(month: 1, day: 1), 1)
        XCTAssertEqual(DayOfYear.from(month: 4, day: 15), 105)
        XCTAssertEqual(DayOfYear.from(month: 5, day: 15), 135)
        XCTAssertEqual(DayOfYear.from(month: 12, day: 31), 365)
    }
}

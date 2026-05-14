import XCTest
@testable import Weevilapp

final class CodesTests: XCTestCase {
    private let berlin = TimeZone(identifier: "Europe/Berlin")!

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0, _ s: Int = 0, _ tz: TimeZone? = nil) -> Date {
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d
        c.hour = h; c.minute = mi; c.second = s
        c.timeZone = tz ?? berlin
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz ?? berlin
        return cal.date(from: c)!
    }

    func testCollectingDay_NoonBelongsToThatDay() {
        let input = date(2026, 5, 9, 12)
        let want  = date(2026, 5, 9)
        XCTAssertEqual(Codes.collectingDay(input, cutoffHour: 5, timeZone: berlin), want)
    }

    func testCollectingDay_BeforeCutoffBelongsToPreviousDay() {
        let input = date(2026, 5, 9, 3)
        let want  = date(2026, 5, 8)
        XCTAssertEqual(Codes.collectingDay(input, cutoffHour: 5, timeZone: berlin), want)
    }

    func testCollectingDay_AtCutoffStartsNewDay() {
        let input = date(2026, 5, 9, 5)
        let want  = date(2026, 5, 9)
        XCTAssertEqual(Codes.collectingDay(input, cutoffHour: 5, timeZone: berlin), want)
    }

    func testCollectingDay_OneSecondBeforeCutoff_PreviousDay() {
        let input = date(2026, 5, 9, 4, 59, 59)
        let want  = date(2026, 5, 8)
        XCTAssertEqual(Codes.collectingDay(input, cutoffHour: 5, timeZone: berlin), want)
    }

    func testCollectingDay_MidnightWithCutoff5_PreviousDay() {
        let input = date(2026, 5, 9, 0)
        let want  = date(2026, 5, 8)
        XCTAssertEqual(Codes.collectingDay(input, cutoffHour: 5, timeZone: berlin), want)
    }

    func testCollectingDay_CutoffZero_CalendarDay() {
        let input = date(2026, 5, 9, 23, 30)
        let want  = date(2026, 5, 9)
        XCTAssertEqual(Codes.collectingDay(input, cutoffHour: 0, timeZone: berlin), want)
    }

    func testFormatCode() {
        let day = date(2026, 5, 9)
        XCTAssertEqual(Codes.formatCode(day: day, sequence: 1,  timeZone: berlin), "260509/1")
        XCTAssertEqual(Codes.formatCode(day: day, sequence: 12, timeZone: berlin), "260509/12")
    }

    func testFormatCodeAcrossYearBoundary() {
        XCTAssertEqual(Codes.formatCode(day: date(2025, 12, 31), sequence: 7, timeZone: berlin), "251231/7")
        XCTAssertEqual(Codes.formatCode(day: date(2026, 1, 1),   sequence: 1, timeZone: berlin), "260101/1")
    }

    func testCollectingDayKey() {
        XCTAssertEqual(Codes.collectingDayKey(date(2026, 5, 9), timeZone: berlin), "2026-05-09")
        XCTAssertEqual(Codes.collectingDayKey(date(2025, 12, 31), timeZone: berlin), "2025-12-31")
    }
}

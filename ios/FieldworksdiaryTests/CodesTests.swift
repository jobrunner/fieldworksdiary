@testable import Fieldworksdiary
import XCTest

final class CodesTests: XCTestCase {
    // swiftlint:disable:next force_unwrapping
    private let berlin = TimeZone(identifier: "Europe/Berlin")!

    // XCTest-Konvention: Date-Builder darf `!` benutzen — ein nil-Date
    // hier wäre Setup-Fehler, der den Test ohnehin als invalid markiert.
    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int = 0,
        _ minute: Int = 0,
        _ second: Int = 0,
        _ tz: TimeZone? = nil
    ) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        components.timeZone = tz ?? berlin
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz ?? berlin
        // swiftlint:disable:next force_unwrapping
        return cal.date(from: components)!
    }

    func testCollectingDay_NoonBelongsToThatDay() {
        let input = date(2026, 5, 9, 12)
        let want = date(2026, 5, 9)
        XCTAssertEqual(Codes.collectingDay(input, cutoffHour: 5, timeZone: berlin), want)
    }

    func testCollectingDay_BeforeCutoffBelongsToPreviousDay() {
        let input = date(2026, 5, 9, 3)
        let want = date(2026, 5, 8)
        XCTAssertEqual(Codes.collectingDay(input, cutoffHour: 5, timeZone: berlin), want)
    }

    func testCollectingDay_AtCutoffStartsNewDay() {
        let input = date(2026, 5, 9, 5)
        let want = date(2026, 5, 9)
        XCTAssertEqual(Codes.collectingDay(input, cutoffHour: 5, timeZone: berlin), want)
    }

    func testCollectingDay_OneSecondBeforeCutoff_PreviousDay() {
        let input = date(2026, 5, 9, 4, 59, 59)
        let want = date(2026, 5, 8)
        XCTAssertEqual(Codes.collectingDay(input, cutoffHour: 5, timeZone: berlin), want)
    }

    func testCollectingDay_MidnightWithCutoff5_PreviousDay() {
        let input = date(2026, 5, 9, 0)
        let want = date(2026, 5, 8)
        XCTAssertEqual(Codes.collectingDay(input, cutoffHour: 5, timeZone: berlin), want)
    }

    func testCollectingDay_CutoffZero_CalendarDay() {
        let input = date(2026, 5, 9, 23, 30)
        let want = date(2026, 5, 9)
        XCTAssertEqual(Codes.collectingDay(input, cutoffHour: 0, timeZone: berlin), want)
    }

    func testFormatCode() {
        let day = date(2026, 5, 9)
        XCTAssertEqual(Codes.formatCode(day: day, sequence: 1, timeZone: berlin), "260509/1")
        XCTAssertEqual(Codes.formatCode(day: day, sequence: 12, timeZone: berlin), "260509/12")
    }

    func testFormatCodeAcrossYearBoundary() {
        XCTAssertEqual(Codes.formatCode(day: date(2025, 12, 31), sequence: 7, timeZone: berlin), "251231/7")
        XCTAssertEqual(Codes.formatCode(day: date(2026, 1, 1), sequence: 1, timeZone: berlin), "260101/1")
    }

    func testCollectingDayKey() {
        XCTAssertEqual(Codes.collectingDayKey(date(2026, 5, 9), timeZone: berlin), "2026-05-09")
        XCTAssertEqual(Codes.collectingDayKey(date(2025, 12, 31), timeZone: berlin), "2025-12-31")
    }
}

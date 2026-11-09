import XCTest
@testable import FieldworksGeo

final class SampleTimeTests: XCTestCase {
    private func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }
    private func tz(_ id: String) -> TimeZone { TimeZone(identifier: id)! }
    private func local(_ d: Date, _ id: String) -> DateComponents {
        var c = Calendar(identifier: .gregorian); c.timeZone = tz(id)
        return c.dateComponents([.hour, .minute, .second], from: d)
    }

    func testRoundedDownBerlin() {
        let a = SampleTime.roundedDown(date("2026-06-10T10:03:43Z"), in: tz("Europe/Berlin"))
        let ca = local(a, "Europe/Berlin")
        XCTAssertEqual([ca.hour, ca.minute, ca.second], [12, 0, 0])
        let b = SampleTime.roundedDown(date("2026-06-10T10:29:59Z"), in: tz("Europe/Berlin"))
        let cb = local(b, "Europe/Berlin")
        XCTAssertEqual([cb.hour, cb.minute, cb.second], [12, 15, 0])
    }

    func testRoundedDownKolkataIsLocal() {
        // 12:03 IST = 06:33 UTC
        let r = SampleTime.roundedDown(date("2026-06-10T06:33:00Z"), in: tz("Asia/Kolkata"))
        let c = local(r, "Asia/Kolkata")
        XCTAssertEqual([c.hour, c.minute], [12, 0])
    }

    func testRoundedDownRepeatedHourDST() {
        // 02:07:30 CET, second occurrence of the 02:00 hour.
        let r = SampleTime.roundedDown(date("2026-10-25T01:07:30Z"), in: tz("Europe/Berlin"))
        XCTAssertEqual(r, date("2026-10-25T01:00:00Z"))
    }

    func testDefaultWindow() {
        let w = SampleTime.defaultWindow(createdAt: date("2026-06-10T10:03:43Z"), in: tz("Europe/Berlin"))
        XCTAssertEqual(w.end.timeIntervalSince(w.begin), 900)
    }

    func testCollectingDay() {
        let t = date("2026-01-15T23:50:00Z")
        XCTAssertEqual(SampleTime.collectingDay(t, cutoffHour: 0, in: tz("Atlantic/Canary")), "2026-01-15")
        XCTAssertEqual(SampleTime.collectingDay(t, cutoffHour: 0, in: tz("Europe/Berlin")), "2026-01-16")
        XCTAssertEqual(SampleTime.collectingDay(date("2026-06-11T01:30:00Z"), cutoffHour: 5, in: tz("Europe/Berlin")), "2026-06-10")
    }

    func testTimezoneLabel() {
        let c = tz("Atlantic/Canary")
        XCTAssertEqual(SampleTime.timezoneLabel(c, at: date("2026-01-15T12:00:00Z")), "Atlantic/Canary (WET)")
        XCTAssertEqual(SampleTime.timezoneLabel(c, at: date("2026-07-15T12:00:00Z")), "Atlantic/Canary (WEST)")
    }
}

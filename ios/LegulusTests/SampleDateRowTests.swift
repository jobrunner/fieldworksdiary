@testable import Legulus
import XCTest

/// Datumszeile der Sample-Ansicht: Wochentag und Datum getrennt, damit
/// die Ansicht bei großer Schrift nach dem Wochentag umbrechen kann.
@MainActor
final class SampleDateRowTests: XCTestCase {
    func testLongDateParts_Berlin() throws {
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-16T12:00:00Z"))
        let zone = try XCTUnwrap(TimeZone(identifier: "Europe/Berlin"))
        let parts = SampleEditorViewModel.longDateParts(date, zone: zone)
        XCTAssertEqual(parts.weekday, "Montag,")
        XCTAssertEqual(parts.date, "16. November 2026")
    }

    /// 23:30 UTC ist in Auckland schon der nächste Tag.
    func testLongDateParts_UsesLocalDayOfZone() throws {
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-16T23:30:00Z"))
        let zone = try XCTUnwrap(TimeZone(identifier: "Pacific/Auckland"))
        let parts = SampleEditorViewModel.longDateParts(date, zone: zone)
        XCTAssertEqual(parts.weekday, "Dienstag,")
        XCTAssertEqual(parts.date, "17. November 2026")
    }
}

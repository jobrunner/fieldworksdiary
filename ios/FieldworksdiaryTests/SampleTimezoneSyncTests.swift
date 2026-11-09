@testable import Fieldworksdiary
import XCTest

/// Phase Z wire format: `timezone` / `timezone_source` /
/// `collecting_day` go out on create and update, never `time_zone` or
/// `elevation_dem*`; the decoder reads `timezone` and falls back to
/// the legacy `time_zone` key.
final class SampleTimezoneSyncTests: XCTestCase {
    private func location() -> SampleLocationFields {
        SampleLocationFields(
            latitude: 28.1,
            longitude: -15.4,
            elevation: 12,
            elevationSource: .locationService,
            locationSource: .locationService,
            locationStatus: .pending
        )
    }

    private func decode(_ extra: [String: Any]) throws -> Sample {
        var dict: [String: Any] = [
            "id": "s1",
            "sample_id": "260519/1",
            "fieldtrip": "ft",
            "begin_date": "2026-05-19T14:00:00.000Z"
        ]
        dict.merge(extra) { _, new in new }
        let data = try JSONSerialization.data(withJSONObject: dict)
        return try JSONDecoder.fieldworks.decode(Sample.self, from: data)
    }

    func testCreateBody_CarriesTimezoneFieldsAndNoLegacyKeys() {
        let input = SampleCreateInput(
            location: location(),
            collectedFrom: Date(timeIntervalSince1970: 1_779_000_000),
            marked: false,
            code: "260519/1",
            timezone: "Atlantic/Canary",
            timezoneSource: .device,
            collectingDay: "2026-05-19"
        )

        let body = SampleClient.createBody(input)

        XCTAssertEqual(body["timezone"] as? String, "Atlantic/Canary")
        XCTAssertEqual(body["timezone_source"] as? String, "device")
        XCTAssertEqual(body["collecting_day"] as? String, "2026-05-19")
        XCTAssertNil(body["time_zone"])
        XCTAssertNil(body["elevation_dem"])
        XCTAssertNil(body["elevation_dem_accuracy"])
    }

    func testUpdateBody_CarriesTimezoneFieldsAndNoLegacyKeys() {
        var loc = location()
        loc.clearsDerived = true
        let input = SampleUpdateInput(
            code: "260519/1",
            notes: nil,
            clientUuid: "u",
            clientUpdatedAt: Date(timeIntervalSince1970: 1_779_000_000),
            version: 2,
            location: loc,
            timezone: "Asia/Kolkata",
            timezoneSource: .manual,
            collectingDay: "2026-05-19"
        )

        let body = SampleClient.updateBody(input)

        XCTAssertEqual(body["timezone"] as? String, "Asia/Kolkata")
        XCTAssertEqual(body["timezone_source"] as? String, "manual")
        XCTAssertEqual(body["collecting_day"] as? String, "2026-05-19")
        XCTAssertNil(body["time_zone"])
        XCTAssertNil(body["elevation_dem"], "clears must not name dropped columns")
        XCTAssertNil(body["elevation_dem_accuracy"])
    }

    func testDecode_ReadsTimezoneFields() throws {
        let s = try decode([
            "timezone": "Atlantic/Canary",
            "timezone_source": "location_service",
            "collecting_day": "2026-05-19"
        ])
        XCTAssertEqual(s.timezone, "Atlantic/Canary")
        XCTAssertEqual(s.timezoneSource, .locationService)
        XCTAssertEqual(s.collectingDay, "2026-05-19")
    }

    func testDecode_FallsBackToLegacyKeyThenBerlin() throws {
        XCTAssertEqual(try decode(["time_zone": "Asia/Kolkata"]).timezone, "Asia/Kolkata")
        let none = try decode([:])
        XCTAssertEqual(none.timezone, "Europe/Berlin")
        XCTAssertNil(none.timezoneSource)
        XCTAssertNil(none.collectingDay)
    }
}

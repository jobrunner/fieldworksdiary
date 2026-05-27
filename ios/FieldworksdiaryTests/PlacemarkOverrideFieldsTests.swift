@testable import Fieldworksdiary
import XCTest

/// Pins the manual-override wire contract: the JSON keys the
/// `PATCH /api/localities/:id/placemark` endpoint expects, plus the
/// country normalisation the form relies on. Drift here would silently
/// break overrides (the server reads snake_case keys; a renamed key is
/// just ignored).
final class PlacemarkOverrideFieldsTests: XCTestCase {
    func testWireBodyUsesSnakeCaseKeys() {
        var f = PlacemarkOverrideFields(country: "de")
        f.administrativeArea = "Bayern"
        f.subAdministrativeArea = "Unterfranken"
        f.locality = "Würzburg"
        f.subLocality = "Sanderau"
        f.postalCode = "97070"
        f.name = "NSG"
        f.thoroughfare = "Sanderring"

        let body = f.wireBody
        XCTAssertEqual(body["administrative_area"] as? String, "Bayern")
        XCTAssertEqual(body["sub_administrative_area"] as? String, "Unterfranken")
        XCTAssertEqual(body["sub_locality"] as? String, "Sanderau")
        XCTAssertEqual(body["postal_code"] as? String, "97070")
        XCTAssertEqual(body["thoroughfare"] as? String, "Sanderring")
        XCTAssertEqual(Set(body.keys), [
            "country", "administrative_area", "sub_administrative_area",
            "locality", "sub_locality", "postal_code", "name", "thoroughfare",
        ])
    }

    func testCountryIsTrimmedAndUppercased() {
        let f = PlacemarkOverrideFields(country: "  de ")
        XCTAssertEqual(f.wireBody["country"] as? String, "DE")
    }

    func testInitFromLocalPlacemarkMapsAllFields() {
        let local = LocalPlacemark(
            id: "p1",
            country: "DE",
            administrativeArea: "Bayern",
            subAdministrativeArea: "Unterfranken",
            locality: "Würzburg",
            subLocality: nil,
            postalCode: "97070",
            name: nil,
            thoroughfare: "Sanderring",
            geocodingSource: "manual",
            geocodingServiceVersion: nil,
            geocodingDate: nil,
            dedupHash: "h",
            backendUpdatedAt: Date()
        )
        let f = PlacemarkOverrideFields(from: local)
        XCTAssertEqual(f.country, "DE")
        XCTAssertEqual(f.administrativeArea, "Bayern")
        XCTAssertEqual(f.locality, "Würzburg")
        XCTAssertEqual(f.thoroughfare, "Sanderring")
        // nil source fields become empty strings, never "nil".
        XCTAssertEqual(f.subLocality, "")
        XCTAssertEqual(f.name, "")
    }
}

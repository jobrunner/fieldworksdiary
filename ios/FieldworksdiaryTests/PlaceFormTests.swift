@testable import Fieldworksdiary
import FieldworksGeo
import XCTest

/// `PlaceForm` (shared by the sample place editor and the locality
/// override) and the locality override wire body.
final class PlaceFormTests: XCTestCase {
    func testNewForm_HasNoFieldsUntilCountryChosen() {
        var form = PlaceForm(place: nil)
        XCTAssertTrue(form.fields().isEmpty)
        XCTAssertNil(form.place())
        XCTAssertFalse(form.isChanged())
        form.selectCountry("DE")
        XCTAssertFalse(form.fields().isEmpty)
        XCTAssertTrue(form.isChanged(), "a country alone is a place")
        XCTAssertEqual(form.place()?.admin[.country]?.name, "Deutschland")
        XCTAssertEqual(form.place()?.admin[.country]?.level, 2)
    }

    func testUserTypedCountryNameSurvivesCountrySwitch() {
        var form = PlaceForm(place: nil)
        form.selectCountry("DE")
        form.values[AdminTier.country.rawValue] = "BRD"
        form.selectCountry("AT")
        XCTAssertEqual(form.values[AdminTier.country.rawValue], "BRD")
    }

    func testLocalityOverrideBody_IsFlatPlaceBodyWithoutSource() {
        let place = Place(countryISO: "DE", admin: [.municipality: AdminValue(name: "Ochsenfurt", level: 8)])
        let body = PlacemarkClient.placeBody(place, source: nil)
        XCTAssertEqual(body["country_iso"] as? String, "DE")
        XCTAssertEqual(body["admin_municipality"] as? String, "Ochsenfurt")
        XCTAssertEqual(body["admin_municipality_level"] as? Int, 8)
        XCTAssertNil(body["geocoding_source"], "the override endpoint sets manual itself")
        XCTAssertNil(body["country"], "old body key is gone")
    }
}

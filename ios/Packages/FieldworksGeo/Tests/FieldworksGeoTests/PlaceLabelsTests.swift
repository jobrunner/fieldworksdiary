import XCTest
@testable import FieldworksGeo

final class PlaceLabelsTests: XCTestCase {
    func testLabelFallbackChain() throws {
        let known = try XCTUnwrap(AdminLabelTable.shared.term(country: "DE", level: 4))
        let l1 = PlaceLabels.label(country: "DE", tier: .state, level: 4, rawLocalTerm: "Raw")
        XCTAssertEqual(l1.term, known)
        XCTAssertEqual(l1.genericKey, "admin.state")

        let l2 = PlaceLabels.label(country: "ZZ", tier: .region, level: 5, rawLocalTerm: "Raw")
        XCTAssertEqual(l2.term, "Raw")
        XCTAssertEqual(l2.genericKey, "admin.region")

        let l3 = PlaceLabels.label(country: "ZZ", tier: .other, level: 5, rawLocalTerm: nil)
        XCTAssertNil(l3.term)
        XCTAssertEqual(l3.genericKey, "admin.other")
        XCTAssertNil(PlaceLabels.label(country: nil, tier: .country, level: nil, rawLocalTerm: " ").term)
    }

    func testGenericKeys() {
        XCTAssertEqual(PlaceLabels.genericKey(for: .country), "admin.country")
        XCTAssertEqual(PlaceLabels.genericKey(for: .submunicipality), "admin.submunicipality")
        XCTAssertEqual(PlaceLabels.islandKey, "place.island")
        XCTAssertEqual(PlaceLabels.mountainRangeKey, "place.mountain_range")
        XCTAssertEqual(PlaceLabels.mountainKey, "place.mountain")
    }
}

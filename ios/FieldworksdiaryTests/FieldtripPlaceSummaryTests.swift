@testable import Fieldworksdiary
import FieldworksGeo
import XCTest

final class FieldtripPlaceSummaryTests: XCTestCase {
    private func place(_ municipality: String, iso: String = "DE", state: String = "Bayern") -> Place {
        Place(countryISO: iso, admin: [
            .state: AdminValue(name: state, level: 4),
            .municipality: AdminValue(name: municipality, level: 8)
        ])
    }

    private func sample(_ place: Place?, _ mtb: String?, _ name: String? = nil) -> FieldtripPlaceSummary.Sample {
        .init(place: place, mtbSheetNumber: mtb, mtbSheetName: name)
    }

    func testMostFrequentPlaceAndMtbWin() {
        let summary = FieldtripPlaceSummary.summarize([
            sample(place("Würzburg"), "6225", "Würzburg"),
            sample(place("Ochsenfurt"), "6326", "Ochsenfurt"),
            sample(place("Würzburg"), "6225", "Würzburg")
        ])
        XCTAssertEqual(summary.name, "Würzburg")
        XCTAssertEqual(summary.region, "\(PlaceDisplay.countryName("DE")), Bayern")
        XCTAssertEqual(summary.mtb, "MTB 6225 Würzburg")
    }

    func testTieResolvesAlphabetically() {
        let summary = FieldtripPlaceSummary.summarize([
            sample(place("Zell"), nil), sample(place("Aub"), nil)
        ])
        XCTAssertEqual(summary.name, "Aub")
        XCTAssertNil(summary.mtb)
    }

    func testMtbHiddenOutsideGermanyAndEmptyWithoutData() {
        let es = FieldtripPlaceSummary.summarize([sample(place("Garafía", iso: "ES", state: "Canarias"), "1234")])
        XCTAssertNil(es.mtb)
        XCTAssertTrue(FieldtripPlaceSummary.summarize([sample(nil, nil)]).isEmpty)
    }
}

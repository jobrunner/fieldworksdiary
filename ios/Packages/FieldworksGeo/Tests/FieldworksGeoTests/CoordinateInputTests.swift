@testable import FieldworksGeo
import Foundation
import XCTest

final class CoordinateInputTests: XCTestCase {
    private func dict(_ items: [URLQueryItem]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    func testUTMItems() throws {
        let items = try CoordinateInput(system: .etrs89utm32, first: "574400", second: "5503700").queryItems()
        XCTAssertEqual(dict(items), ["srid": "25832", "x": "574400", "y": "5503700"])
    }

    func testCommaDecimal() throws {
        let items = try CoordinateInput(system: .gk3, first: "3574500,5", second: "5505500,25").queryItems()
        XCTAssertEqual(dict(items), ["srid": "31467", "x": "3574500.5", "y": "5505500.25"])
    }

    func testWGS84OrderAndFormats() throws {
        let items = try CoordinateInput(system: .wgs84, first: "49,68123", second: "10,03134").queryItems()
        XCTAssertEqual(items.map(\.name), ["srid", "lon", "lat"])
        XCTAssertEqual(dict(items), ["srid": "4326", "lat": "49.681230", "lon": "10.031340"])
        let dm = try CoordinateInput(system: .wgs84, first: "N 49°40.874'", second: "E 10°1.880'").queryItems()
        XCTAssertEqual(Double(dict(dm)["lat"] ?? "") ?? 0, 49.681233, accuracy: 1e-5)
        XCTAssertEqual(Double(dict(dm)["lon"] ?? "") ?? 0, 10.031333, accuracy: 1e-5)
    }

    func testMGRS() throws {
        let items = try CoordinateInput(system: .mgrs, first: "32u na 74400 03700").queryItems()
        XCTAssertEqual(dict(items), ["mgrs": "32UNA7440003700"])
    }

    func testInvalid() {
        XCTAssertThrowsError(try CoordinateInput(system: .gk2, first: "", second: "1").queryItems())
        XCTAssertThrowsError(try CoordinateInput(system: .gk2, first: "abc", second: "1").queryItems())
        XCTAssertThrowsError(try CoordinateInput(system: .wgs84, first: "x", second: "10").queryItems())
        XCTAssertThrowsError(try CoordinateInput(system: .mgrs, first: "  ").queryItems())
    }

    func testResponseDecodesWGS84() throws {
        let json = #"{"wgs84":{"lat":49.68123,"lon":10.03134}}"#
        let r = try JSONDecoder().decode(OrtusResponse.self, from: Data(json.utf8))
        XCTAssertEqual(r.wgs84?.lat, 49.68123)
        XCTAssertEqual(r.wgs84?.lon, 10.03134)
    }

    func testSystemOrderAndLabels() {
        XCTAssertEqual(InputCoordinateSystem.allCases.first, .wgs84)
        XCTAssertEqual(InputCoordinateSystem.allCases.last, .mgrs)
        XCTAssertNil(InputCoordinateSystem.mgrs.secondLabel)
    }
}

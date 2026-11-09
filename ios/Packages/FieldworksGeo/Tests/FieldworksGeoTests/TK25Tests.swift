import XCTest
@testable import FieldworksGeo

final class TK25Tests: XCTestCase {
    private struct Case: Decodable {
        let lat: Double
        let lon: Double
        let row: Int?
        let col: Int?
        let quadrant: Int?
        let ok: Bool?
    }

    func testTK25SharedCases() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("shared/testdata/tk25_cases.json")
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: url))
        XCTAssertFalse(cases.isEmpty)
        for c in cases {
            let got = TK25.cell(lat: c.lat, lon: c.lon)
            if c.ok == false {
                XCTAssertNil(got, "\(c.lat),\(c.lon)")
            } else {
                let g = try XCTUnwrap(got, "\(c.lat),\(c.lon)")
                XCTAssertEqual(g.row, c.row, "\(c.lat),\(c.lon)")
                XCTAssertEqual(g.col, c.col, "\(c.lat),\(c.lon)")
                XCTAssertEqual(g.quadrant, c.quadrant, "\(c.lat),\(c.lon)")
            }
        }
    }
}

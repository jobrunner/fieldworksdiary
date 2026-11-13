@testable import FieldworksGeo
import XCTest

final class OrtusMapperTests: XCTestCase {
    private let dir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("shared/testdata/ortus")

    private func load(_ name: String) throws -> OrtusResponse {
        try JSONDecoder().decode(OrtusResponse.self, from: Data(contentsOf: dir.appendingPathComponent(name)))
    }

    func testMapDE() throws {
        let q = try load("query_de_ochsenfurt.json")
        let exp = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(contentsOf: dir.appendingPathComponent("expected_de_ochsenfurt.json"))
        ) as? [String: Any])
        let res = try OrtusMapper.map(q, lat: XCTUnwrap(q.wgs84?.lat), lon: XCTUnwrap(q.wgs84?.lon))
        let p = try XCTUnwrap(res.place)
        XCTAssertEqual(p.countryISO, "DE")
        XCTAssertEqual(res.geo.timezone, "Europe/Berlin")
        XCTAssertFalse(res.features.contains { $0.sourceID == "timezones-2026a" })
        let admin = try XCTUnwrap(exp["admin"] as? [String: [String: Any]])
        XCTAssertEqual(p.admin.count, admin.count)
        for (k, v) in admin {
            let got = try XCTUnwrap(AdminTier(rawValue: k).flatMap { p.admin[$0] })
            XCTAssertEqual(got.name, v["name"] as? String)
            XCTAssertEqual(got.level, v["level"] as? Int)
        }
        let g = res.geo
        XCTAssertEqual(g.elevationDEM, 236.0)
        XCTAssertEqual(g.elevationDEMAccuracy, 4.0)
        XCTAssertEqual(g.slopeDeg, 8.4)
        XCTAssertEqual(g.aspectDeg, 202.5)
        XCTAssertEqual(g.aspectCompass, "SSW")
        XCTAssertEqual(g.bearingLabel, "2 km WNW Ochsenfurt")
        XCTAssertEqual(g.bearingDistanceKm, 2.3)
        XCTAssertEqual(g.mtbSheetNumber, "6326")
        XCTAssertEqual(g.mtbSheetName, "Ochsenfurt")
        XCTAssertEqual(g.mtbQuadrant, 1)
        XCTAssertEqual(res.features.count, exp["feature_count"] as? Int)
        XCTAssertEqual(res.features[0].featureID, "0")
        XCTAssertEqual(res.features[1].featureID, "DE6326371")
        XCTAssertEqual(res.features[0].sourceID, "tk25-blattschnitt-de")
        XCTAssertNotNil(res.features[0].licenseJSON)
        XCTAssertNotEqual(res.features[0].licenseJSON, res.features[1].licenseJSON)
        XCTAssertTrue(res.features[0].propertiesJSON.contains("\"blattname\":\"Ochsenfurt\""))
        XCTAssertEqual(p.dedupHash, exp["dedup_hash"] as? String)
        XCTAssertEqual(p.dedupHash, "92ae97bbc5767de89956ba0a3822dd2ad1c3fb942f6c700587266b114de924de")
    }

    func testMapESIsland() throws {
        let q = try load("query_es_lapalma.json")
        let res = try OrtusMapper.map(q, lat: XCTUnwrap(q.wgs84?.lat), lon: XCTUnwrap(q.wgs84?.lon))
        let p = try XCTUnwrap(res.place)
        XCTAssertEqual(p.admin[.state]?.name, "Canarias")
        XCTAssertEqual(p.island, "La Palma")
        XCTAssertEqual(p.mountain, "Pico Bejenado")
        XCTAssertEqual(res.geo.mtbSheetNumber, "")
        XCTAssertEqual(res.geo.mtbQuadrant, 0)
    }

    func testMapSeaNoPlace() throws {
        let res = try OrtusMapper.map(load("query_sea.json"), lat: 40, lon: -25)
        XCTAssertNil(res.place)
        XCTAssertNil(res.geo.elevationDEM)
    }

    func testSeaLevelElevationZero() throws {
        let json = #"{"gazetteer":{"elevation":{"meters":3,"sea_level":true,"accuracy_m":2}}}"#
        let r = try JSONDecoder().decode(OrtusResponse.self, from: Data(json.utf8))
        let res = OrtusMapper.map(r, lat: 0, lon: 0)
        XCTAssertEqual(res.geo.elevationDEM, 0)
        XCTAssertNil(res.place)
    }

    func testUnknownCountryFallback() throws {
        let json = #"""
        {"gazetteer":{"admin":{"country_iso":"ZZ","hierarchy":[
          {"level":8,"name":"Foo","equivalent":"municipality"},
          {"level":7,"name":"Bar","equivalent":"municipality"},
          {"level":6,"name":"Baz","equivalent":"nonsense"},
          {"level":2,"name":"Zedland","equivalent":"country"}]}}}
        """#
        let r = try JSONDecoder().decode(OrtusResponse.self, from: Data(json.utf8))
        let p = try XCTUnwrap(OrtusMapper.map(r, lat: 0, lon: 0).place)
        XCTAssertEqual(p.admin[.municipality]?.name, "Foo")
        XCTAssertEqual(p.admin[.other]?.name, "Baz")
        XCTAssertEqual(p.admin[.country]?.name, "Zedland")
    }

    func testHierarchyEntryWithoutLevelDoesNotFailDecode() throws {
        let json = #"""
        {"gazetteer":{"admin":{"country_iso":"DE","hierarchy":[
          {"name":"Irgendwas"},
          {"level":2,"name":"Deutschland","equivalent":"country"}]}}}
        """#
        let r = try JSONDecoder().decode(OrtusResponse.self, from: Data(json.utf8))
        let p = try XCTUnwrap(OrtusMapper.map(r, lat: 0, lon: 0).place)
        XCTAssertEqual(p.admin[.country]?.name, "Deutschland")
    }

    func testDedupHashNormalization() {
        let a = Place(countryISO: "DE", admin: [.municipality: AdminValue(name: " Würzburg ")])
        let b = Place(countryISO: "de", admin: [.municipality: AdminValue(name: "WÜRZBURG")])
        let c = Place(countryISO: "DE", admin: [.municipality: AdminValue(name: "Wu\u{308}rzburg")])
        XCTAssertEqual(a.dedupHash, b.dedupHash)
        XCTAssertEqual(a.dedupHash, c.dedupHash)
        let d = Place(countryISO: "DE", admin: [.county: AdminValue(name: "Würzburg")])
        XCTAssertNotEqual(a.dedupHash, d.dedupHash)
        XCTAssertNotEqual(Place(countryISO: "DE", island: "x").dedupHash,
                          Place(countryISO: "DE", mountain: "x").dedupHash)
    }

    func testSheetNumber() {
        XCTAssertEqual(OrtusMapper.sheetNumber(["id": .string("6326"), "dtknummer": .string("9999")]), "6326")
        XCTAssertEqual(OrtusMapper.sheetNumber(["dtknummer": .string("6326")]), "6326")
        XCTAssertEqual(OrtusMapper.sheetNumber(["id": .string(" "), "dtknummer": .string("6326")]), "6326")
        XCTAssertEqual(OrtusMapper.sheetNumber(["id": .number(6326)]), "6326")
        XCTAssertEqual(OrtusMapper.sheetNumber(["blattname": .string("x")]), "")
    }
}

import XCTest
@testable import FieldworksGeo

final class AdminLabelTableTests: XCTestCase {
    func testHas77Countries() {
        XCTAssertEqual(AdminLabelTable.shared.countries.count, 77)
    }

    func testColumnDE() {
        let t = AdminLabelTable.shared
        XCTAssertEqual(t.column(country: "DE", level: 8).tier, .municipality)
        XCTAssertTrue(t.column(country: "DE", level: 8).known)
        XCTAssertEqual(t.column(country: "DE", level: 4).tier, .state)
    }

    func testCollision() {
        let t = AdminLabelTable.shared
        XCTAssertEqual(t.column(country: "DE", level: 10).tier, .submunicipality)
        let c = t.column(country: "DE", level: 11)
        XCTAssertNil(c.tier)
        XCTAssertTrue(c.known)
    }

    func testUnknownCountry() {
        let c = AdminLabelTable.shared.column(country: "XX", level: 8)
        XCTAssertNil(c.tier)
        XCTAssertFalse(c.known)
    }

    func testTermAndLevels() {
        let t = AdminLabelTable.shared
        XCTAssertEqual(t.term(country: "DE", level: 4), "Bundesland")
        XCTAssertNil(t.term(country: "XX", level: 4))
        let levels = t.levels(country: "DE")
        XCTAssertEqual(levels.map(\.level), levels.map(\.level).sorted())
        XCTAssertFalse(levels.contains { $0.level == 11 })
        XCTAssertTrue(levels.contains { $0.level == 10 && $0.tier == .submunicipality })
    }

    func testResourceMatchesShared() throws {
        let shared = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("shared/admin-labels/admin_labels.json")
        let bundled = try XCTUnwrap(Bundle.module.url(forResource: "admin_labels", withExtension: "json"))
        XCTAssertEqual(try Data(contentsOf: bundled), try Data(contentsOf: shared))
    }
}

import XCTest
@testable import FieldworksGeo

final class CoordinateConverterTests: XCTestCase {
    private let ne = (lat: 49.681230, lon: 10.031340)
    private let sw = (lat: -33.856784, lon: -70.512345)

    private func f(_ c: (lat: Double, lon: Double), _ fmt: CoordinateDisplayFormat) -> String? {
        CoordinateConverter.format(lat: c.lat, lon: c.lon, as: fmt)
    }

    func testDefaultIsDecimalSign() { XCTAssertEqual(CoordinateDisplayFormat.default, .decimalSign) }

    func testTitlesAreUnique() {
        let titles = CoordinateDisplayFormat.allCases.map(\.title)
        XCTAssertEqual(Set(titles).count, titles.count)
    }

    func testFormatsNorthEast() {
        XCTAssertEqual(f(ne, .decimalSign), "+49.681230 +10.031340")
        XCTAssertEqual(f(ne, .decimalDirection), "N49.681230 E10.031340")
        XCTAssertEqual(f(ne, .degreesSign), "+49.681230° +010.031340°")
        XCTAssertEqual(f(ne, .degreesDirection), "N49.681230° E010.031340°")
        XCTAssertEqual(f(ne, .degreesMinutesSign), "+49°40.87' +010°01.88'")
        XCTAssertEqual(f(ne, .degreesMinutesDirection), "N49°40.87' E010°01.88'")
        XCTAssertEqual(f(ne, .dmsSign), "+49°40'52.4\" +010°01'52.8\"")
        XCTAssertEqual(f(ne, .dmsDirection), "N49°40'52.4\" E010°01'52.8\"")
    }

    func testFormatsSouthWest() {
        XCTAssertEqual(f(sw, .decimalSign), "-33.856784 -70.512345")
        XCTAssertEqual(f(sw, .decimalDirection), "S33.856784 W70.512345")
        XCTAssertEqual(f(sw, .degreesSign), "-33.856784° -070.512345°")
        XCTAssertEqual(f(sw, .degreesDirection), "S33.856784° W070.512345°")
        XCTAssertEqual(f(sw, .degreesMinutesSign), "-33°51.41' -070°30.74'")
        XCTAssertEqual(f(sw, .degreesMinutesDirection), "S33°51.41' W070°30.74'")
        XCTAssertEqual(f(sw, .dmsSign), "-33°51'24.4\" -070°30'44.4\"")
        XCTAssertEqual(f(sw, .dmsDirection), "S33°51'24.4\" W070°30'44.4\"")
    }

    func testMinuteRoundingCarries() {
        XCTAssertEqual(CoordinateConverter.format(lat: 49.99999999, lon: 10, as: .degreesMinutesDirection),
                       "N50°00.00' E010°00.00'")
    }

    func testUTMAndMGRSFormat() {
        XCTAssertEqual(f(ne, .utm), "32U 574400 5503700")
        let mgrs = f(ne, .mgrs)
        XCTAssertTrue(mgrs?.hasPrefix("32U NA 744") == true, mgrs ?? "nil")
        XCTAssertEqual(mgrs?.split(separator: " ").count, 4)
    }

    func testInvalidFormatInputIsNil() {
        XCTAssertNil(CoordinateConverter.format(lat: 91, lon: 0, as: .decimalSign))
        XCTAssertNil(CoordinateConverter.format(lat: .nan, lon: 0, as: .utm))
        XCTAssertNil(CoordinateConverter.toMGRS(lat: 0, lon: 0, precision: 9))
    }

    private func assertNear(_ c: (lat: Double, lon: Double)?, _ e: (lat: Double, lon: Double),
                            accuracy: Double = 1e-5, file: StaticString = #filePath, line: UInt = #line) {
        guard let c else { return XCTFail("nil", file: file, line: line) }
        XCTAssertEqual(c.lat, e.lat, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(c.lon, e.lon, accuracy: accuracy, file: file, line: line)
    }

    func testFromMGRS() {
        assertNear(CoordinateConverter.fromMGRS("32UNA7440003700"), ne)
        assertNear(CoordinateConverter.fromMGRS("32U NA 74400 03700"), ne)
        assertNear(CoordinateConverter.fromMGRS("32una7440003700"), ne)
    }

    func testFromMGRSGarbageIsNil() {
        XCTAssertNil(CoordinateConverter.fromMGRS(""))
        XCTAssertNil(CoordinateConverter.fromMGRS("hello world"))
        XCTAssertNil(CoordinateConverter.fromMGRS("99ZZZ123"))
        XCTAssertNil(CoordinateConverter.fromMGRS("32U NA 744 0370"))
    }

    func testFromUTM() {
        assertNear(CoordinateConverter.fromUTM(zone: 32, northernHemisphere: true, easting: 574400, northing: 5503700), ne)
        XCTAssertNil(CoordinateConverter.fromUTM(zone: 0, northernHemisphere: true, easting: 574400, northing: 5503700))
        XCTAssertNil(CoordinateConverter.fromUTM(zone: 32, northernHemisphere: true, easting: -5, northing: 5503700))
    }

    func testParseGeographic() {
        assertNear(CoordinateConverter.parseGeographic("49,681230 10,031340"), ne, accuracy: 1e-9)
        assertNear(CoordinateConverter.parseGeographic("49.681230, 10.031340"), ne, accuracy: 1e-9)
        assertNear(CoordinateConverter.parseGeographic("49.681230,10.031340"), ne, accuracy: 1e-9)
        assertNear(CoordinateConverter.parseGeographic("N49°40.874' E10°01.880'"), ne, accuracy: 1e-5)
        assertNear(CoordinateConverter.parseGeographic("49°40'52.4\"N 10°1'52.8\"E"), ne, accuracy: 1e-5)
        assertNear(CoordinateConverter.parseGeographic("49°40.874' 10°01.880'"), ne, accuracy: 1e-5)
        assertNear(CoordinateConverter.parseGeographic("-33.856784 -70.512345"), sw, accuracy: 1e-9)
        assertNear(CoordinateConverter.parseGeographic("S33.856784° W070.512345°"), sw, accuracy: 1e-9)
    }

    func testParseGeographicRoundTrips() {
        for fmt in CoordinateDisplayFormat.allCases where ![.utm, .mgrs].contains(fmt) {
            for c in [ne, sw] {
                guard let s = f(c, fmt) else { return XCTFail("format \(fmt)") }
                assertNear(CoordinateConverter.parseGeographic(s), c, accuracy: 1e-4)
            }
        }
    }

    func testParseGeographicRejects() {
        XCTAssertNil(CoordinateConverter.parseGeographic("abc"))
        XCTAssertNil(CoordinateConverter.parseGeographic(""))
        XCTAssertNil(CoordinateConverter.parseGeographic("91 10"))
        XCTAssertNil(CoordinateConverter.parseGeographic("49 181"))
        XCTAssertNil(CoordinateConverter.parseGeographic("49"))
        XCTAssertNil(CoordinateConverter.parseGeographic("49°70' 10°"))
    }

    func testParseComponent() throws {
        let a = try XCTUnwrap(CoordinateConverter.parseGeographicComponent("49°40'52.4\"N", isLatitude: true))
        XCTAssertEqual(a, 49.681222, accuracy: 1e-6)
        XCTAssertEqual(CoordinateConverter.parseGeographicComponent("W10,5", isLatitude: false), -10.5)
        XCTAssertNil(CoordinateConverter.parseGeographicComponent("E10", isLatitude: true))
        XCTAssertNil(CoordinateConverter.parseGeographicComponent("91", isLatitude: true))
    }
}

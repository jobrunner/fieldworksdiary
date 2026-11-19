@testable import LegulusGeo
import XCTest

/// Texte für die Zwischenablage: Koordinate und Höhe in einem festen,
/// vom Anzeigeformat und Gebietsschema unabhängigen Format.
final class ClipboardTextTests: XCTestCase {
    private let ne = (lat: 49.681230, lon: 10.031340)

    func testGeographicFormatsCopyDecimalDegrees() {
        let geographic: [CoordinateDisplayFormat] = [
            .decimalSign, .decimalDirection, .degreesSign, .degreesDirection,
            .degreesMinutesSign, .degreesMinutesDirection, .dmsSign, .dmsDirection
        ]
        for format in geographic {
            XCTAssertEqual(ClipboardText.coordinate(lat: 49.1234, lon: 10.1234, format: format),
                           "49.123400,10.123400", "\(format)")
        }
    }

    func testSouthWestIsNegative() {
        XCTAssertEqual(ClipboardText.coordinate(lat: -33.865143, lon: -151.2099, format: .dmsDirection),
                       "-33.865143,-151.209900")
    }

    func testNegativeZeroIsPlainZero() {
        XCTAssertEqual(ClipboardText.coordinate(lat: 0, lon: -0.0000001, format: .decimalSign),
                       "0.000000,0.000000")
    }

    func testUTMAndMGRSDropWhitespace() {
        XCTAssertEqual(ClipboardText.coordinate(lat: ne.lat, lon: ne.lon, format: .utm), "32U5744005503700")
        let mgrs = ClipboardText.coordinate(lat: ne.lat, lon: ne.lon, format: .mgrs)
        XCTAssertEqual(mgrs?.contains(" "), false)
        XCTAssertEqual(mgrs?.hasPrefix("32UNA744"), true)
        XCTAssertEqual(mgrs?.count, 15)
    }

    func testGridFormatOutOfRangeFallsBackToDecimal() {
        // lat 89 liegt außerhalb des UTM/MGRS-Bereichs (84° N).
        XCTAssertNil(CoordinateConverter.format(lat: 89, lon: 10, as: .utm), "Vorbedingung: UTM kennt 89° N nicht")
        XCTAssertEqual(ClipboardText.coordinate(lat: 89, lon: 10, format: .utm), "89.000000,10.000000")
    }

    func testNonFiniteIsNil() {
        XCTAssertNil(ClipboardText.coordinate(lat: .nan, lon: 0, format: .decimalSign))
        XCTAssertNil(ClipboardText.coordinate(lat: 0, lon: .infinity, format: .mgrs))
    }

    func testOutOfRangeIsNil() {
        XCTAssertNil(ClipboardText.coordinate(lat: 91, lon: 0, format: .decimalSign))
    }

    func testAltitude() {
        XCTAssertEqual(ClipboardText.altitude(meters: 275.6), "276m")
        XCTAssertEqual(ClipboardText.altitude(meters: -3.2), "-3m")
        XCTAssertEqual(ClipboardText.altitude(meters: -0.2), "0m")
    }

    /// Die Anzeige („%.0f m“) rundet halbe Meter zur geraden Zahl; die
    /// Kopie muss denselben Wert liefern.
    func testAltitudeRoundsHalfMetersLikeTheDisplay() {
        for meters in [276.5, 277.5, -2.5, 0.5] {
            XCTAssertEqual(ClipboardText.altitude(meters: meters),
                           String(format: "%.0fm", locale: Locale(identifier: "en_US_POSIX"), meters + 0)
                               .replacingOccurrences(of: "-0m", with: "0m"),
                           "\(meters)")
        }
        XCTAssertEqual(ClipboardText.altitude(meters: 276.5), "276m")
        XCTAssertEqual(ClipboardText.altitude(meters: -2.5), "-2m")
    }
}

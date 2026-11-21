import CoreLocation
import ImageIO
@testable import Legulus
import XCTest

final class PhotoGPSMetadataTests: XCTestCase {
    private func location(lat: Double, lon: Double, altitude: Double = 276, hAcc: Double = 4, vAcc: Double = 6,
                          iso: String = "2026-11-16T22:30:05Z") throws -> CLLocation
    {
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: iso))
        return CLLocation(coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                          altitude: altitude, horizontalAccuracy: hAcc, verticalAccuracy: vAcc, timestamp: date)
    }

    private func value<T>(_ dict: [String: Any], _ key: CFString) -> T? {
        dict[key as String] as? T
    }

    func testNorthEast() throws {
        let gps = try PhotoGPSMetadata.dictionary(for: location(lat: 49.681230, lon: 10.031340))
        XCTAssertEqual(value(gps, kCGImagePropertyGPSLatitude), 49.681230)
        XCTAssertEqual(value(gps, kCGImagePropertyGPSLatitudeRef), "N")
        XCTAssertEqual(value(gps, kCGImagePropertyGPSLongitude), 10.031340)
        XCTAssertEqual(value(gps, kCGImagePropertyGPSLongitudeRef), "E")
        XCTAssertEqual(value(gps, kCGImagePropertyGPSAltitude), 276.0)
        XCTAssertEqual(value(gps, kCGImagePropertyGPSAltitudeRef), 0)
        XCTAssertEqual(value(gps, kCGImagePropertyGPSHPositioningError), 4.0)
    }

    func testSouthWestUsesPositiveValuesAndRefs() throws {
        let gps = try PhotoGPSMetadata.dictionary(for: location(lat: -33.856784, lon: -70.512345))
        XCTAssertEqual(value(gps, kCGImagePropertyGPSLatitude), 33.856784)
        XCTAssertEqual(value(gps, kCGImagePropertyGPSLatitudeRef), "S")
        XCTAssertEqual(value(gps, kCGImagePropertyGPSLongitude), 70.512345)
        XCTAssertEqual(value(gps, kCGImagePropertyGPSLongitudeRef), "W")
    }

    func testBelowSeaLevel() throws {
        let gps = try PhotoGPSMetadata.dictionary(for: location(lat: 31.5, lon: 35.5, altitude: -412))
        XCTAssertEqual(value(gps, kCGImagePropertyGPSAltitude), 412.0)
        XCTAssertEqual(value(gps, kCGImagePropertyGPSAltitudeRef), 1)
    }

    func testInvalidAccuraciesDropTheirFields() throws {
        let gps = try PhotoGPSMetadata.dictionary(for: location(lat: 49, lon: 10, hAcc: -1, vAcc: -1))
        XCTAssertNil(gps[kCGImagePropertyGPSAltitude as String])
        XCTAssertNil(gps[kCGImagePropertyGPSAltitudeRef as String])
        XCTAssertNil(gps[kCGImagePropertyGPSHPositioningError as String])
        XCTAssertNotNil(gps[kCGImagePropertyGPSLatitude as String])
    }

    /// EXIF-GPS-Zeit ist UTC, egal in welcher Zone das Gerät steht.
    func testTimestampIsUTC() throws {
        let gps = try PhotoGPSMetadata.dictionary(for: location(lat: 49, lon: 10))
        XCTAssertEqual(value(gps, kCGImagePropertyGPSDateStamp), "2026:11:16")
        XCTAssertEqual(value(gps, kCGImagePropertyGPSTimeStamp), "22:30:05")
    }
}

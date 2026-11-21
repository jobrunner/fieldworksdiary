import AVFoundation
import CoreLocation
import ImageIO
@testable import Legulus
import XCTest

/// Die Teile der Kamera, die sich ohne Gerät prüfen lassen.
final class CameraSessionLogicTests: XCTestCase {
    /// Das virtuelle Mehrfach-Kameragerät zuerst: nur damit wechseln
    /// Zoom und Nahbereich (Makro) von selbst die Linse.
    func testPreferredDeviceTypes_VirtualDevicesFirst() {
        XCTAssertEqual(CameraSession.preferredDeviceTypes, [
            .builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera
        ])
    }

    func testClampedZoom() {
        XCTAssertEqual(CameraSession.clampedZoom(0.2, min: 1, max: 15), 1)
        XCTAssertEqual(CameraSession.clampedZoom(3, min: 1, max: 15), 3)
        XCTAssertEqual(CameraSession.clampedZoom(20, min: 1, max: 15), 10, "nie über 10-fach")
        XCTAssertEqual(CameraSession.clampedZoom(8, min: 1, max: 5), 5)
        XCTAssertEqual(CameraSession.clampedZoom(.nan, min: 1, max: 5), 1)
    }

    func testPhotoSettings_AreJPEG() {
        let settings = CameraSession.photoSettings(flash: .off, supportedFlash: [.off], location: nil)
        XCTAssertEqual(settings.format?[AVVideoCodecKey] as? String, AVVideoCodecType.jpeg.rawValue)
    }

    func testPhotoSettings_FlashOnlyWhenSupported() {
        XCTAssertEqual(CameraSession.photoSettings(flash: .auto, supportedFlash: [.off, .auto, .on], location: nil).flashMode, .auto)
        XCTAssertEqual(CameraSession.photoSettings(flash: .auto, supportedFlash: [.off], location: nil).flashMode, .off)
        XCTAssertEqual(CameraSession.photoSettings(flash: .off, supportedFlash: [.off, .auto], location: nil).flashMode, .off)
    }

    func testPhotoSettings_CarryThePositionOfTheShot() throws {
        let without = CameraSession.photoSettings(flash: .off, supportedFlash: [.off], location: nil)
        XCTAssertNil(without.metadata[kCGImagePropertyGPSDictionary as String])

        let location = CLLocation(latitude: -33.856784, longitude: 10.031340)
        let with = CameraSession.photoSettings(flash: .off, supportedFlash: [.off], location: location)
        let gps = try XCTUnwrap(with.metadata[kCGImagePropertyGPSDictionary as String] as? [String: Any])
        XCTAssertEqual(gps[kCGImagePropertyGPSLatitudeRef as String] as? String, "S")
        XCTAssertEqual(gps[kCGImagePropertyGPSLongitude as String] as? Double, 10.031340)
    }

    /// On the virtual devices factor 1 is the ultra-wide lens. The
    /// camera opens on the main lens, like the system camera.
    func testInitialZoom_StartsOnTheMainLens() {
        XCTAssertEqual(CameraSession.initialZoom(deviceType: .builtInTripleCamera, switchOverFactors: [2, 6]), 2)
        XCTAssertEqual(CameraSession.initialZoom(deviceType: .builtInDualWideCamera, switchOverFactors: [2]), 2)
        XCTAssertEqual(
            CameraSession.initialZoom(deviceType: .builtInDualCamera, switchOverFactors: [2]),
            1,
            "Weitwinkel + Tele: 1 ist die Hauptlinse"
        )
        XCTAssertEqual(CameraSession.initialZoom(deviceType: .builtInWideAngleCamera, switchOverFactors: []), 1)
        XCTAssertEqual(CameraSession.initialZoom(deviceType: .builtInTripleCamera, switchOverFactors: []), 1)
    }

    func testZoomStep() {
        XCTAssertEqual(CameraSession.zoomStep, 1.5)
        XCTAssertEqual(CameraSession.clampedZoom(2 * CameraSession.zoomStep, min: 1, max: 15), 3)
        XCTAssertEqual(CameraSession.clampedZoom(1 / CameraSession.zoomStep, min: 1, max: 15), 1)
    }

    func testFlashLabel() {
        XCTAssertEqual(CameraSession.flashLabel(.auto), "Blitz: automatisch")
        XCTAssertEqual(CameraSession.flashLabel(.off), "Blitz: aus")
    }
}

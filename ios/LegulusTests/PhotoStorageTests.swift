import ImageIO
@testable import Legulus
import UIKit
import UniformTypeIdentifiers
import XCTest

/// Fotodateien werden unverändert abgelegt; Vorschaubilder entstehen
/// ohne das volle Bild zu dekodieren.
final class PhotoStorageTests: XCTestCase {
    private var sampleID = ""

    override func setUp() {
        super.setUp()
        sampleID = "test-" + UUID().uuidString
    }

    override func tearDown() {
        PhotoStorage.deleteSampleDir(sampleID: sampleID)
        super.tearDown()
    }

    /// JPEG mit EXIF-Orientierung, wie die Kamera es im Hochformat liefert.
    static func jpeg(width: Int, height: Int, orientation: Int = 1) throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { ctx in
            UIColor.systemGreen.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        let cgImage = try XCTUnwrap(image.cgImage)
        let data = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, cgImage, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return data as Data
    }

    func testWriteData_KeepsBytesIdentical() throws {
        let data = try Self.jpeg(width: 64, height: 48)
        let path = try PhotoStorage.write(data: data, sampleID: sampleID, photoID: "p1")
        XCTAssertEqual(path, "photos/\(sampleID)/p1.jpg")
        XCTAssertEqual(try PhotoStorage.readData(relativePath: path), data)
        XCTAssertEqual(PhotoStorage.fileSize(relativePath: path), Int64(data.count))
    }

    func testWriteData_OverwritesExistingFile() throws {
        _ = try PhotoStorage.write(data: Data([1, 2, 3]), sampleID: sampleID, photoID: "p1")
        let second = try Self.jpeg(width: 32, height: 32)
        let path = try PhotoStorage.write(data: second, sampleID: sampleID, photoID: "p1")
        XCTAssertEqual(try PhotoStorage.readData(relativePath: path), second)
    }

    func testThumbnail_IsDownscaledAndUpright() throws {
        // 400 × 300 Pixel, Orientierung 6: aufrecht ist das Bild 300 × 400.
        let data = try Self.jpeg(width: 400, height: 300, orientation: 6)
        let path = try PhotoStorage.write(data: data, sampleID: sampleID, photoID: "p1")
        let thumb = try XCTUnwrap(PhotoStorage.thumbnail(relativePath: path, maxPixel: 100))
        let size = CGSize(width: thumb.size.width * thumb.scale, height: thumb.size.height * thumb.scale)
        XCTAssertLessThanOrEqual(max(size.width, size.height), 100)
        XCTAssertGreaterThan(size.height, size.width, "Hochformat muss aufrecht ankommen")
    }

    func testThumbnail_MissingFileIsNil() {
        XCTAssertNil(PhotoStorage.thumbnail(relativePath: "photos/\(sampleID)/fehlt.jpg", maxPixel: 100))
        XCTAssertNil(PhotoStorage.fileSize(relativePath: "photos/\(sampleID)/fehlt.jpg"))
    }
}

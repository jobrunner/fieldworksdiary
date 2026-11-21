import ImageIO
@testable import Legulus
import UIKit
import UniformTypeIdentifiers
import XCTest

/// Foto-Import beim Nachtragen: JPEG bleibt bytegleich, alles andere
/// wird einmal nach JPEG gewandelt, mit voller Pixelgröße und allen
/// Metadaten.
final class PhotoImportFormatTests: XCTestCase {
    /// Bild im angegebenen Format mit EXIF, TIFF, GPS und Orientierung.
    private func image(type: UTType, width: Int = 403, height: Int = 302) throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { ctx in
            UIColor.systemTeal.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        let cgImage = try XCTUnwrap(rendered.cgImage)
        let data = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        let properties: [CFString: Any] = [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:11:16 09:41:07"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: "Testkamera 17"],
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 49.68123, kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 10.03134, kCGImagePropertyGPSLongitudeRef: "E"
            ]
        ]
        CGImageDestinationAddImage(dest, cgImage, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest), "\(type.identifier) wird auf diesem System nicht geschrieben")
        return data as Data
    }

    private func properties(_ data: Data) throws -> [CFString: Any] {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    }

    private func typeIdentifier(_ data: Data) throws -> String {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(CGImageSourceGetType(source) as String?)
    }

    private func assertMetadataKept(_ data: Data, file: StaticString = #filePath, line: UInt = #line) throws {
        let props = try properties(data)
        XCTAssertEqual(props[kCGImagePropertyPixelWidth] as? Int, 403, file: file, line: line)
        XCTAssertEqual(props[kCGImagePropertyPixelHeight] as? Int, 302, file: file, line: line)
        XCTAssertEqual(props[kCGImagePropertyOrientation] as? Int, 6, file: file, line: line)
        let exif = try XCTUnwrap(props[kCGImagePropertyExifDictionary] as? [CFString: Any], file: file, line: line)
        XCTAssertEqual(exif[kCGImagePropertyExifDateTimeOriginal] as? String, "2026:11:16 09:41:07", file: file, line: line)
        let tiff = try XCTUnwrap(props[kCGImagePropertyTIFFDictionary] as? [CFString: Any], file: file, line: line)
        XCTAssertEqual(tiff[kCGImagePropertyTIFFModel] as? String, "Testkamera 17", file: file, line: line)
        let gps = try XCTUnwrap(props[kCGImagePropertyGPSDictionary] as? [CFString: Any], file: file, line: line)
        XCTAssertEqual(try XCTUnwrap(gps[kCGImagePropertyGPSLatitude] as? Double), 49.68123, accuracy: 0.00001, file: file, line: line)
        XCTAssertEqual(gps[kCGImagePropertyGPSLongitudeRef] as? String, "E", file: file, line: line)
    }

    func testJPEG_IsReturnedByteIdentical() throws {
        let jpeg = try image(type: .jpeg)
        XCTAssertEqual(try PhotoImportFormat.jpegData(from: jpeg), jpeg)
    }

    func testHEIC_BecomesJPEGWithSamePixelSizeAndMetadata() throws {
        let heic = try image(type: .heic)
        XCTAssertEqual(try typeIdentifier(heic), UTType.heic.identifier, "Vorbedingung")
        let converted = try PhotoImportFormat.jpegData(from: heic)
        XCTAssertEqual(try typeIdentifier(converted), UTType.jpeg.identifier)
        try assertMetadataKept(converted)
    }

    func testPNG_BecomesJPEGWithSamePixelSize() throws {
        let png = try image(type: .png)
        let converted = try PhotoImportFormat.jpegData(from: png)
        XCTAssertEqual(try typeIdentifier(converted), UTType.jpeg.identifier)
        let props = try properties(converted)
        XCTAssertEqual(props[kCGImagePropertyPixelWidth] as? Int, 403)
        XCTAssertEqual(props[kCGImagePropertyPixelHeight] as? Int, 302)
    }

    func testPrepared_ConvertsOffTheMainActor() async throws {
        let heic = try image(type: .heic)
        let prepared = await PhotoImportFormat.prepared(heic)
        XCTAssertEqual(try typeIdentifier(prepared), UTType.jpeg.identifier)
    }

    /// Not an image: handed back as it is, the caller's attach step
    /// reports the failure.
    func testPrepared_KeepsUnreadableData() async {
        let garbage = Data([0, 1, 2, 3, 4])
        let prepared = await PhotoImportFormat.prepared(garbage)
        XCTAssertEqual(prepared, garbage)
    }

    func testGarbage_Throws() {
        XCTAssertThrowsError(try PhotoImportFormat.jpegData(from: Data([0, 1, 2, 3, 4])))
        XCTAssertThrowsError(try PhotoImportFormat.jpegData(from: Data()))
    }
}

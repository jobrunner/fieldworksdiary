import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The file format of a photo imported from the library („Probe
/// nachtragen → Aus Foto“). Stored and uploaded photos are JPEG. An
/// imported JPEG is kept byte for byte; any other format (HEIC, PNG, …)
/// is converted once: full pixel size, high quality, all metadata
/// (EXIF, GPS, TIFF, orientation) carried over — so the uploaded file
/// can be worked with like the original.
enum PhotoImportFormat {
    enum FormatError: Error, LocalizedError {
        case notAnImage
        case conversionFailed

        var errorDescription: String? {
            switch self {
            case .notAnImage: "Die Datei ist kein lesbares Bild."
            case .conversionFailed: "Das Foto konnte nicht nach JPEG gewandelt werden."
            }
        }
    }

    /// JPEG quality of the one conversion.
    static let conversionQuality: CGFloat = 0.92

    /// `jpegData(from:)` off the caller's actor: decoding and encoding
    /// a full-size photo takes long enough to stall the UI. Data that
    /// cannot be converted comes back unchanged — the step that stores
    /// the photo reports the failure.
    static func prepared(_ data: Data) async -> Data {
        await Task.detached(priority: .userInitiated) {
            (try? jpegData(from: data)) ?? data
        }.value
    }

    static func jpegData(from data: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let type = CGImageSourceGetType(source) as String?
        else { throw FormatError.notAnImage }
        if type == UTType.jpeg.identifier {
            return data
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw FormatError.conversionFailed }
        // Adding the image from its source keeps the pixels as they are
        // (no resizing, no baked-in rotation) and copies the source's
        // properties; only the quality is ours.
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: conversionQuality]
        CGImageDestinationAddImageFromSource(destination, source, 0, options as CFDictionary)
        guard CGImageDestinationFinalize(destination), output.length > 0 else { throw FormatError.conversionFailed }
        return output as Data
    }
}

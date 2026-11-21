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
    /// a full-size photo takes long enough to stall the UI. nil when
    /// the data cannot be converted or the calling task was cancelled —
    /// the caller goes on without a photo and nobody converts twice.
    static func prepared(_ data: Data) async -> Data? {
        await converter.jpeg(from: data)
    }

    /// One conversion at a time: a cancelled import cannot interrupt
    /// ImageIO, and a retry must not stack a second full-size decode on
    /// top of the one still running. Requests cancelled while they
    /// waited are skipped.
    private actor Converter {
        func jpeg(from data: Data) -> Data? {
            guard !Task.isCancelled else { return nil }
            return try? PhotoImportFormat.jpegData(from: data)
        }
    }

    private static let converter = Converter()

    /// Cheap check on the header, no decoding.
    static func isJPEG(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0
        else { return false }
        return CGImageSourceGetType(source) as String? == UTType.jpeg.identifier
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
        // A HEIC can hold several images; the photo is its primary one
        // (index 0 for formats without that distinction).
        let index = CGImageSourceGetPrimaryImageIndex(source)
        CGImageDestinationAddImageFromSource(destination, source, index, options as CFDictionary)
        guard CGImageDestinationFinalize(destination), output.length > 0 else { throw FormatError.conversionFailed }
        return output as Data
    }
}

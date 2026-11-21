import Foundation
import ImageIO
import UIKit

/// Filesystem layer for sample photos. Photos live under
/// `Documents/photos/<sampleID>/<photoID>.jpg` so they survive an
/// app reinstall is a non-goal (Documents is included in iCloud
/// Backup, which is what we want).
///
/// Files are stored exactly as they come in — the camera's JPEG, or an
/// imported photo (see `PhotoImportFormat`): never resized, never
/// re-encoded here, all metadata stays. Previews for the UI are
/// downsampled on the fly (`thumbnail`).
enum PhotoStorage {
    enum StorageError: Error, LocalizedError {
        case documentsUnreachable
        case writeFailed(String)
        case readFailed(String)

        var errorDescription: String? {
            switch self {
            case .documentsUnreachable: "Documents-Ordner ist nicht erreichbar."
            case let .writeFailed(msg): "Foto konnte nicht gespeichert werden: \(msg)"
            case let .readFailed(msg): "Foto konnte nicht gelesen werden: \(msg)"
            }
        }
    }

    /// Writes finished image data (the camera's JPEG file) unchanged
    /// under `Documents/photos/<sampleID>/<photoID>.jpg`: no re-encoding,
    /// no resizing, all metadata stays. Returns the path relative to
    /// Documents.
    static func write(data: Data, sampleID: String, photoID: String) throws -> String {
        let dir = try sampleDir(sampleID: sampleID)
        let fileURL = dir.appendingPathComponent("\(photoID).jpg")
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw StorageError.writeFailed(error.localizedDescription)
        }
        return "photos/\(sampleID)/\(photoID).jpg"
    }

    /// A preview with at most `maxPixel` on its long edge, upright.
    /// ImageIO downsamples while decoding, so a strip of full-resolution
    /// photos does not hold them all in memory. Nil when the file is
    /// missing or not an image.
    static func thumbnail(relativePath: String, maxPixel: CGFloat) -> UIImage? {
        guard let url = absoluteURL(forRelative: relativePath),
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        return thumbnail(from: source, maxPixel: maxPixel)
    }

    /// `thumbnail(relativePath:maxPixel:)` for image data that is not on
    /// disk (yet).
    static func thumbnail(data: Data, maxPixel: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        return thumbnail(from: source, maxPixel: maxPixel)
    }

    private static func thumbnail(from source: CGImageSource, maxPixel: CGFloat) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }

    /// Size of the stored file in bytes; nil when it is missing.
    static func fileSize(relativePath: String) -> Int64? {
        guard let url = absoluteURL(forRelative: relativePath),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber
        else { return nil }
        return size.int64Value
    }

    /// Returns the absolute URL for a relative path (as stored in
    /// `LocalPhoto.localPath`). Nil if Documents is unreachable.
    static func absoluteURL(forRelative path: String) -> URL? {
        guard let docs = try? documentsURL() else { return nil }
        return docs.appendingPathComponent(path)
    }

    static func readData(relativePath: String) throws -> Data {
        guard let url = absoluteURL(forRelative: relativePath) else {
            throw StorageError.documentsUnreachable
        }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw StorageError.readFailed(error.localizedDescription)
        }
    }

    static func delete(relativePath: String) {
        guard let url = absoluteURL(forRelative: relativePath) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Removes the whole `Documents/photos/<sampleID>/` directory.
    /// Used when the user discards an unsubmitted sample, or when a
    /// sample is deleted.
    static func deleteSampleDir(sampleID: String) {
        guard let docs = try? documentsURL() else { return }
        let dir = docs.appendingPathComponent("photos/\(sampleID)")
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - private

    private static func documentsURL() throws -> URL {
        do {
            return try FileManager.default.url(
                for: .documentDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        } catch {
            throw StorageError.documentsUnreachable
        }
    }

    private static func sampleDir(sampleID: String) throws -> URL {
        let docs = try documentsURL()
        let dir = docs.appendingPathComponent("photos/\(sampleID)")
        if !FileManager.default.fileExists(atPath: dir.path) {
            do {
                try FileManager.default.createDirectory(
                    at: dir,
                    withIntermediateDirectories: true
                )
            } catch {
                throw StorageError.writeFailed(error.localizedDescription)
            }
        }
        return dir
    }
}

import Foundation
import UIKit

/// Filesystem layer for sample photos. Photos live under
/// `Documents/photos/<sampleID>/<photoID>.jpg` so they survive an
/// app reinstall is a non-goal (Documents is included in iCloud
/// Backup, which is what we want).
///
/// Compression policy: JPEG quality 0.85 at max 2400px on the long
/// edge. Yields ~600 KB–1.2 MB per image — small enough for patchy
/// cellular but enough detail for habitat/substrate verification.
struct PhotoStorage {
    static let jpegQuality: CGFloat = 0.85
    static let maxLongEdge: CGFloat = 2400

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

    /// Compresses `image` to JPEG and writes it under
    /// `Documents/photos/<sampleID>/<photoID>.jpg`. Returns the path
    /// relative to Documents (suitable for `LocalPhoto.localPath`).
    static func write(image: UIImage, sampleID: String, photoID: String) throws -> String {
        let resized = resize(image, maxLongEdge: maxLongEdge)
        guard let data = resized.jpegData(compressionQuality: jpegQuality) else {
            throw StorageError.writeFailed("JPEG-Kodierung fehlgeschlagen")
        }
        let dir = try sampleDir(sampleID: sampleID)
        let fileURL = dir.appendingPathComponent("\(photoID).jpg")
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw StorageError.writeFailed(error.localizedDescription)
        }
        return "photos/\(sampleID)/\(photoID).jpg"
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

    private static func resize(_ image: UIImage, maxLongEdge: CGFloat) -> UIImage {
        let size = image.size
        let long = max(size.width, size.height)
        guard long > maxLongEdge else { return image }
        let scale = maxLongEdge / long
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}

import CoreLocation
import CryptoKit
import Foundation
import MapKit
import UIKit

/// Renders + caches small Apple Maps snapshots with a pin in the
/// centre. Used by the sample editor's bottom map preview.
///
/// Caching policy:
///   - In-memory `NSCache` (fast subsequent loads in the same session).
///   - On-disk PNG under `Documents/maps/<sha256>.png`, keyed by the
///     full rendering inputs (coord, span, size, dark mode).
///   - Cache survives across launches; no TTL — once a tile snapshot
///     is rendered for a location it's reusable indefinitely (map
///     style updates only happen on iOS version bumps, which would
///     prompt a fresh render anyway because the system snapshot
///     bytes change).
enum MapSnapshotter {
    /// Memory cache shared across the app. UIImage is reference-typed
    /// so this is a thin O(1) lookup.
    private static let memoryCache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 200
        return c
    }()

    /// Renders (or fetches from cache) a snapshot centred on `coord`.
    /// The image returned already has the pin drawn into it — the
    /// caller can just display it.
    ///
    /// - Parameters:
    ///   - coord: centre of the map.
    ///   - size: target image size in points (caller passes the
    ///     view's pixel size for a 1:1 result).
    ///   - span: latitude span in degrees. ~0.04 ≈ city block + walk.
    ///   - dark: light vs. dark map style.
    static func snapshot(
        at coord: CLLocationCoordinate2D,
        size: CGSize,
        span: Double = 0.04,
        dark: Bool = false
    ) async throws -> UIImage {
        let key = cacheKey(coord: coord, size: size, span: span, dark: dark)

        if let cached = memoryCache.object(forKey: key as NSString) {
            return cached
        }

        if let url = diskURL(for: key),
           FileManager.default.fileExists(atPath: url.path),
           let data = try? Data(contentsOf: url),
           let image = UIImage(data: data)
        {
            memoryCache.setObject(image, forKey: key as NSString)
            return image
        }

        let snapshot = try await renderSnapshot(coord: coord, size: size, span: span, dark: dark)
        let image = drawPin(on: snapshot, coord: coord)
        memoryCache.setObject(image, forKey: key as NSString)
        if let url = diskURL(for: key), let data = image.pngData() {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? data.write(to: url)
        }
        return image
    }

    // MARK: - private

    private static func renderSnapshot(
        coord: CLLocationCoordinate2D,
        size: CGSize,
        span: Double,
        dark: Bool
    ) async throws -> MKMapSnapshotter.Snapshot {
        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(
            center: coord,
            span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span)
        )
        options.size = size
        // UIScreen.main is @MainActor in Swift 6; the rendering itself
        // is fine off the main thread, but we read the scale on
        // whatever actor we already are on. The snapshotter handles
        // the heavy lifting on its own queue.
        options.scale = await MainActor.run { UIScreen.main.scale }
        options.traitCollection = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
        options.mapType = .standard

        let snapshotter = MKMapSnapshotter(options: options)
        return try await snapshotter.start()
    }

    private static func drawPin(on snapshot: MKMapSnapshotter.Snapshot, coord: CLLocationCoordinate2D) -> UIImage {
        let image = snapshot.image
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        return renderer.image { ctx in
            image.draw(at: .zero)
            let point = snapshot.point(for: coord)

            // Outer ring + inner dot — high-contrast pin that reads
            // on both light and dark map tiles.
            let outerRadius: CGFloat = 11
            let innerRadius: CGFloat = 5
            let outer = CGRect(
                x: point.x - outerRadius,
                y: point.y - outerRadius,
                width: outerRadius * 2,
                height: outerRadius * 2
            )
            let inner = CGRect(
                x: point.x - innerRadius,
                y: point.y - innerRadius,
                width: innerRadius * 2,
                height: innerRadius * 2
            )
            UIColor.white.setFill()
            ctx.cgContext.fillEllipse(in: outer)
            UIColor.systemBlue.setFill()
            ctx.cgContext.fillEllipse(in: inner)
        }
    }

    private static func cacheKey(coord: CLLocationCoordinate2D, size: CGSize, span: Double, dark: Bool) -> String {
        let raw = String(
            format: "%.5f|%.5f|%.4f|%.0fx%.0f|%d",
            coord.latitude,
            coord.longitude,
            span,
            size.width,
            size.height,
            dark ? 1 : 0
        )
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func diskURL(for key: String) -> URL? {
        guard let docs = try? FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        return docs.appendingPathComponent("maps/\(key).png")
    }
}

import CoreLocation
import ImageIO

/// GPS block for the EXIF data of a photo taken in the app. The camera
/// does not write a position itself; the app adds the place the photo
/// was taken at (not the sample's stored coordinate).
enum PhotoGPSMetadata {
    /// Content for `kCGImagePropertyGPSDictionary`. EXIF stores positive
    /// values with N/S and E/W references and the time in UTC. Altitude
    /// and accuracy are left out when Core Location marks them invalid
    /// (negative accuracy).
    static func dictionary(for location: CLLocation) -> [String: Any] {
        let coordinate = location.coordinate
        var gps: [String: Any] = [
            kCGImagePropertyGPSLatitude as String: abs(coordinate.latitude),
            kCGImagePropertyGPSLatitudeRef as String: coordinate.latitude < 0 ? "S" : "N",
            kCGImagePropertyGPSLongitude as String: abs(coordinate.longitude),
            kCGImagePropertyGPSLongitudeRef as String: coordinate.longitude < 0 ? "W" : "E"
        ]
        if location.verticalAccuracy >= 0 {
            gps[kCGImagePropertyGPSAltitude as String] = abs(location.altitude)
            gps[kCGImagePropertyGPSAltitudeRef as String] = location.altitude < 0 ? 1 : 0
        }
        if location.horizontalAccuracy >= 0 {
            gps[kCGImagePropertyGPSHPositioningError as String] = location.horizontalAccuracy
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy:MM:dd"
        gps[kCGImagePropertyGPSDateStamp as String] = formatter.string(from: location.timestamp)
        formatter.dateFormat = "HH:mm:ss"
        gps[kCGImagePropertyGPSTimeStamp as String] = formatter.string(from: location.timestamp)
        return gps
    }
}

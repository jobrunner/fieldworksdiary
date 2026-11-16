import Foundation
import ImageIO

/// Position and capture time read from a photo's metadata („Probe
/// nachtragen → Aus Foto“).
struct PhotoMetadata {
    /// WGS84 position from the GPS block, signed by its N/S/E/W refs.
    /// nil without GPS (or when the user removed the location when
    /// picking the photo).
    var coordinate: (lat: Double, lon: Double)?
    /// `DateTimeOriginal`, read with `OffsetTimeOriginal` when present,
    /// otherwise in the reader's `fallbackZone`.
    var capturedAt: Date?
    /// `OffsetTimeOriginal` was present. Without it the capture time is
    /// a wall-clock reading in an unknown zone and is re-read in the
    /// Ortus zone of the coordinate once that is known.
    var hadExplicitOffset: Bool
}

/// Reads `PhotoMetadata` from image data (JPEG, HEIC, …) via ImageIO.
/// Never throws: unreadable or missing metadata yields empty fields.
enum PhotoMetadataReader {
    static func read(_ data: Data, fallbackZone: TimeZone) -> PhotoMetadata {
        var result = PhotoMetadata(coordinate: nil, capturedAt: nil, hadExplicitOffset: false)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return result }

        if let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any] {
            result.coordinate = coordinate(from: gps)
        }
        if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let original = exif[kCGImagePropertyExifDateTimeOriginal] as? String
        {
            let offset = (exif[kCGImagePropertyExifOffsetTimeOriginal] as? String).flatMap(parseOffset)
            let zone = offset.flatMap { TimeZone(secondsFromGMT: $0) } ?? fallbackZone
            if let date = parseExifDate(original, in: zone) {
                result.capturedAt = date
                result.hadExplicitOffset = offset != nil
            }
        }
        return result
    }

    /// The same wall-clock reading in another zone: a capture time read
    /// in `from` (no offset in the photo) re-read in `to`.
    static func reinterpret(_ date: Date, from: TimeZone, to: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = from
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        components.timeZone = to
        calendar.timeZone = to
        return calendar.date(from: components) ?? date
    }

    // MARK: - private

    private static func coordinate(from gps: [CFString: Any]) -> (lat: Double, lon: Double)? {
        guard let lat = number(gps[kCGImagePropertyGPSLatitude]),
              let lon = number(gps[kCGImagePropertyGPSLongitude])
        else { return nil }
        let latRef = (gps[kCGImagePropertyGPSLatitudeRef] as? String)?.uppercased()
        let lonRef = (gps[kCGImagePropertyGPSLongitudeRef] as? String)?.uppercased()
        // ImageIO reports magnitudes; the refs carry the hemisphere. A
        // negative magnitude (some writers) keeps its sign.
        let signedLat = latRef == "S" ? -abs(lat) : lat
        let signedLon = lonRef == "W" ? -abs(lon) : lon
        guard (-90 ... 90).contains(signedLat), (-180 ... 180).contains(signedLon) else { return nil }
        return (signedLat, signedLon)
    }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let d as Double: d
        case let n as NSNumber: n.doubleValue
        case let s as String: Double(s)
        default: nil
        }
    }

    /// `+02:00`, `-03:30`, `+0200` → seconds east of GMT.
    static func parseOffset(_ text: String) -> Int? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard let sign = t.first, sign == "+" || sign == "-" else { return nil }
        let digits = t.dropFirst().filter { $0 != ":" }
        guard digits.count == 4, let hours = Int(digits.prefix(2)), let minutes = Int(digits.suffix(2)),
              hours <= 14, minutes < 60
        else { return nil }
        let seconds = hours * 3600 + minutes * 60
        return sign == "-" ? -seconds : seconds
    }

    /// EXIF `yyyy:MM:dd HH:mm:ss`.
    private static func parseExifDate(_ text: String, in zone: TimeZone) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: text.trimmingCharacters(in: .whitespaces))
    }
}

import Foundation

extension JSONDecoder {
    /// Decoder configured for PocketBase responses. Top-level
    /// datetimes use the PB-flavoured "yyyy-MM-dd HH:mm:ss.SSSZ"
    /// format; the nested `astro` object emits ISO-8601 with offset
    /// from the Go server. The custom date strategy tolerates both.
    static var fieldworks: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let str = try decoder.singleValueContainer().decode(String.self)
            if let date = Self.parseDate(str) { return date }
            throw try DecodingError.dataCorruptedError(
                in: decoder.singleValueContainer(),
                debugDescription: "Unrecognised date string: \(str)"
            )
        }
        return d
    }

    static func parseDate(_ str: String) -> Date? {
        if str.isEmpty { return nil }
        // Astro emits ISO-8601 with timezone offset and fractional s.
        let isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = isoFractional.date(from: str) { return d }
        let isoBasic = ISO8601DateFormatter()
        isoBasic.formatOptions = [.withInternetDateTime]
        if let d = isoBasic.date(from: str) { return d }
        // PocketBase top-level datetime: "2026-05-10 12:30:00.000Z"
        let pbFormatter = DateFormatter()
        pbFormatter.locale = Locale(identifier: "en_US_POSIX")
        pbFormatter.timeZone = TimeZone(identifier: "UTC")
        pbFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS'Z'"
        if let d = pbFormatter.date(from: str) { return d }
        // Without milliseconds, just in case.
        pbFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss'Z'"
        return pbFormatter.date(from: str)
    }
}

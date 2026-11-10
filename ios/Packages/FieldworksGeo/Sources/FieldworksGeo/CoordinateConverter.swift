import CGeotrans
import Foundation

/// Formatieren und Parsen von Koordinaten (WGS84). Rein, ohne UIKit.
/// UTM/MGRS-Umrechnung nutzt die NGA-GEOTRANS-Bibliothek (`CGeotrans`).
/// Alle Funktionen liefern bei ungültiger Eingabe `nil`.
public enum CoordinateConverter {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")

    // MARK: Formatieren

    public static func format(lat: Double, lon: Double, as format: CoordinateDisplayFormat) -> String? {
        guard lat.isFinite, lon.isFinite, abs(lat) <= 90, abs(lon) <= 180 else { return nil }
        switch format {
        case .decimalSign: return geographic(lat, lon, .decimal, direction: false)
        case .decimalDirection: return geographic(lat, lon, .decimal, direction: true)
        case .degreesSign: return geographic(lat, lon, .degrees, direction: false)
        case .degreesDirection: return geographic(lat, lon, .degrees, direction: true)
        case .degreesMinutesSign: return geographic(lat, lon, .minutes, direction: false)
        case .degreesMinutesDirection: return geographic(lat, lon, .minutes, direction: true)
        case .dmsSign: return geographic(lat, lon, .seconds, direction: false)
        case .dmsDirection: return geographic(lat, lon, .seconds, direction: true)
        case .utm: return toUTMString(lat: lat, lon: lon)
        case .mgrs: return toMGRS(lat: lat, lon: lon, precision: 5)
        }
    }

    private enum Style { case decimal, degrees, minutes, seconds }

    private static func geographic(_ lat: Double, _ lon: Double, _ style: Style, direction: Bool) -> String {
        let la = component(lat, isLatitude: true, style, direction: direction)
        let lo = component(lon, isLatitude: false, style, direction: direction)
        return la + " " + lo
    }

    private static func component(_ value: Double, isLatitude: Bool, _ style: Style, direction: Bool) -> String {
        let negative = value < 0
        let a = abs(value)
        let hemi = isLatitude ? (negative ? "S" : "N") : (negative ? "W" : "E")
        let prefix = direction ? hemi : (negative ? "-" : "+")
        let degWidth = isLatitude ? 2 : 3
        let body: String
        switch style {
        case .decimal:
            body = String(format: "%.6f", a)
        case .degrees:
            body = String(format: isLatitude ? "%.6f°" : "%010.6f°", a)
        case .minutes:
            let hundredths = Int((a * 60 * 100).rounded())
            let deg = hundredths / 6000
            let min = Double(hundredths % 6000) / 100
            body = String(format: "%0\(degWidth)d°%05.2f'", deg, min)
        case .seconds:
            let tenths = Int((a * 3600 * 10).rounded())
            let deg = tenths / 36000
            let min = (tenths % 36000) / 600
            let sec = Double(tenths % 600) / 10
            body = String(format: "%0\(degWidth)d°%02d'%04.1f\"", deg, min, sec)
        }
        return prefix + body
    }

    private static func toUTMString(lat: Double, lon: Double) -> String? {
        var zone: Int = 0
        var hemisphere = CChar(0)
        var easting = 0.0
        var northing = 0.0
        let err = Convert_Geodetic_To_UTM(lat * .pi / 180, lon * .pi / 180, &zone, &hemisphere, &easting, &northing)
        guard err == 0 else { return nil }
        var letter: Int32 = 0
        guard Get_Latitude_Letter(lat * .pi / 180, &letter) == 0,
              letter >= 0, Int(letter) < alphabet.count else { return nil }
        return "\(zone)\(alphabet[Int(letter)]) \(Int(easting.rounded())) \(Int(northing.rounded()))"
    }

    /// MGRS mit Leerzeichen, z. B. `32U NA 74400 03700`. `precision` 0...5.
    public static func toMGRS(lat: Double, lon: Double, precision: Int = 5) -> String? {
        guard lat.isFinite, lon.isFinite, (0...5).contains(precision) else { return nil }
        var buffer = [CChar](repeating: 0, count: 32)
        let err = Convert_Geodetic_To_MGRS(lat * .pi / 180, lon * .pi / 180, precision, &buffer)
        guard err == 0 else { return nil }
        let raw = String(cString: buffer)
        // Aufbau: Zone (1-2 Ziffern) + Band + 2 Gitterbuchstaben + 2*precision Ziffern
        let chars = Array(raw)
        guard let firstLetter = chars.firstIndex(where: { $0.isLetter }),
              chars.count >= firstLetter + 3 else { return nil }
        let zone = String(chars[..<firstLetter])
        let band = String(chars[firstLetter])
        let grid = String(chars[(firstLetter + 1)..<(firstLetter + 3)])
        let digits = Array(chars[(firstLetter + 3)...])
        guard digits.count == precision * 2 else { return nil }
        var parts = ["\(zone)\(band)", grid]
        if precision > 0 {
            parts.append(String(digits[..<precision]))
            parts.append(String(digits[precision...]))
        }
        return parts.joined(separator: " ")
    }

    // MARK: Umrechnen

    public static func fromUTM(zone: Int, northernHemisphere: Bool, easting: Double, northing: Double)
        -> (lat: Double, lon: Double)? {
        guard (1...60).contains(zone), easting.isFinite, northing.isFinite else { return nil }
        var lat = 0.0
        var lon = 0.0
        let hemisphere = CChar(UInt8(ascii: northernHemisphere ? "N" : "S"))
        let err = Convert_UTM_To_Geodetic(zone, hemisphere, easting, northing, &lat, &lon)
        guard err == 0 else { return nil }
        return (lat * 180 / .pi, lon * 180 / .pi)
    }

    /// Akzeptiert MGRS mit oder ohne Leerzeichen, Groß-/Kleinschreibung egal.
    public static func fromMGRS(_ text: String) -> (lat: Double, lon: Double)? {
        let cleaned = text.uppercased().filter { !$0.isWhitespace }
        // Zone (optional bei UPS) + Band + 2 Gitterbuchstaben + gerade Ziffernzahl (0...10)
        guard cleaned.range(of: #"^(\d{1,2})?[A-Z]{3}(\d\d){0,5}$"#, options: .regularExpression) != nil
        else { return nil }
        var lat = 0.0
        var lon = 0.0
        var cstr = Array(cleaned.utf8CString)
        let err = Convert_MGRS_To_Geodetic(&cstr, &lat, &lon)
        guard err == 0 else { return nil }
        return (lat * 180 / .pi, lon * 180 / .pi)
    }

    // MARK: Parsen geographischer Eingaben

    /// Liest ein Paar Breite/Länge in Dezimal-, DM- oder DMS-Schreibweise
    /// (mit Vorzeichen oder N/S/E/W, Punkt oder Komma als Dezimaltrenner).
    public static func parseGeographic(_ text: String) -> (lat: Double, lon: Double)? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !t.isEmpty else { return nil }
        guard let (a, b) = splitPair(t) else { return nil }
        // Reihenfolge: erste Hälfte ist Breite, es sei denn, Buchstaben sagen anderes.
        let aIsLonLetter = a.contains("E") || a.contains("W")
        let (latText, lonText) = aIsLonLetter ? (b, a) : (a, b)
        guard let lat = parseGeographicComponent(latText, isLatitude: true),
              let lon = parseGeographicComponent(lonText, isLatitude: false) else { return nil }
        return (lat, lon)
    }

    private static func splitPair(_ t: String) -> (String, String)? {
        let letterIdx = t.indices.filter { "NSEW".contains(t[$0]) }
        if letterIdx.count == 2 {
            if t[t.startIndex...].first.map({ "NSEW".contains($0) }) == true {
                // Präfix-Stil: "N49 E10" – an zweitem Buchstaben trennen
                let i = letterIdx[1]
                return (String(t[..<i]), String(t[i...]))
            }
            let i = t.index(after: letterIdx[0])
            return (String(t[..<i]), String(t[i...]))
        }
        guard letterIdx.isEmpty else { return nil }
        if t.contains(";") {
            let p = t.split(separator: ";", omittingEmptySubsequences: true).map(String.init)
            return p.count == 2 ? (p[0], p[1]) : nil
        }
        // "49.68, 10.03" oder "49.68,10.03" (Komma + Dezimalpunkt)
        if let r = t.range(of: #",\s+"#, options: .regularExpression) {
            return (String(t[..<r.lowerBound]), String(t[r.upperBound...]))
        }
        if t.contains("."), t.filter({ $0 == "," }).count == 1, !t.contains(where: { $0.isWhitespace }) {
            let p = t.split(separator: ",").map(String.init)
            return p.count == 2 ? (p[0], p[1]) : nil
        }
        let tokens = t.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard [2, 4, 6].contains(tokens.count) else { return nil }
        let h = tokens.count / 2
        return (tokens[..<h].joined(separator: " "), tokens[h...].joined(separator: " "))
    }

    /// Liest eine einzelne Koordinatenkomponente (Grad, Grad+Minuten oder Grad+Minuten+Sekunden).
    public static func parseGeographicComponent(_ text: String, isLatitude: Bool) -> Double? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !t.isEmpty else { return nil }
        var hemiSign: Double?
        let allowed: Set<Character> = isLatitude ? ["N", "S"] : ["E", "W"]
        for ch in t where "NSEW".contains(ch) {
            guard allowed.contains(ch), hemiSign == nil else { return nil }
            hemiSign = (ch == "S" || ch == "W") ? -1 : 1
        }
        t.removeAll { "NSEW".contains($0) }
        t = t.trimmingCharacters(in: .whitespaces)
        var explicitSign: Double?
        if t.hasPrefix("-") { explicitSign = -1; t.removeFirst() }
        else if t.hasPrefix("+") { explicitSign = 1; t.removeFirst() }
        if hemiSign != nil, explicitSign == -1 { return nil }
        // Zahlen extrahieren; alles andere darf nur Trenner/Einheitenzeichen sein.
        let allowedSeparators = Set("°'\"′″ºd:_ ·")
        var numbers: [Double] = []
        var current = ""
        for ch in t {
            if ch.isASCII, ch.isNumber || ch == "." || ch == "," {
                current.append(ch == "," ? "." : ch)
            } else if allowedSeparators.contains(ch) || ch == "\u{2019}" {
                if !current.isEmpty { guard let v = Double(current) else { return nil }; numbers.append(v); current = "" }
            } else {
                return nil
            }
        }
        if !current.isEmpty { guard let v = Double(current) else { return nil }; numbers.append(v) }
        guard (1...3).contains(numbers.count) else { return nil }
        if numbers.count >= 2 { guard numbers[1] < 60 else { return nil } }
        if numbers.count == 3 { guard numbers[2] < 60, numbers[1] == numbers[1].rounded() else { return nil } }
        var value = numbers[0]
        if numbers.count >= 2 { value += numbers[1] / 60 }
        if numbers.count == 3 { value += numbers[2] / 3600 }
        let sign = hemiSign ?? explicitSign ?? 1
        let result = sign * value
        guard abs(result) <= (isLatitude ? 90 : 180) else { return nil }
        return result
    }
}

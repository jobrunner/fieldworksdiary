import Foundation

/// Texte für die Zwischenablage. Anders als die Anzeige sind sie zum
/// Einfügen in andere Apps gedacht: ohne Leerzeichen und unabhängig vom
/// Gebietsschema (Dezimalpunkt).
public enum ClipboardText {
    private static let posix = Locale(identifier: "en_US_POSIX")

    /// UTM und MGRS wie angezeigt, aber ohne Leerzeichen
    /// („32UNA6938014686“). Alle geographischen Formate als Dezimalgrad
    /// mit Vorzeichen und 6 Nachkommastellen („49.123456,10.123456“),
    /// ebenso UTM/MGRS außerhalb ihres Gültigkeitsbereichs. `nil` bei
    /// ungültiger Koordinate.
    public static func coordinate(lat: Double, lon: Double, format: CoordinateDisplayFormat) -> String? {
        guard lat.isFinite, lon.isFinite, abs(lat) <= 90, abs(lon) <= 180 else { return nil }
        switch format {
        case .utm, .mgrs:
            if let grid = CoordinateConverter.format(lat: lat, lon: lon, as: format) {
                return grid.filter { !$0.isWhitespace }
            }
            return decimal(lat, lon)
        case .decimalSign, .decimalDirection, .degreesSign, .degreesDirection,
             .degreesMinutesSign, .degreesMinutesDirection, .dmsSign, .dmsDirection:
            return decimal(lat, lon)
        }
    }

    /// Höhe in ganzen Metern ohne Leerzeichen („276m“).
    public static func altitude(meters: Double) -> String {
        // `+ 0` macht aus einer gerundeten -0 eine 0.
        String(format: "%.0fm", locale: posix, meters.rounded(.toNearestOrEven) + 0)
    }

    private static func decimal(_ lat: Double, _ lon: Double) -> String {
        String(format: "%.6f,%.6f", locale: posix, sixDecimals(lat), sixDecimals(lon))
    }

    /// Rundet auf 6 Nachkommastellen; `+ 0` verhindert „-0.000000“.
    private static func sixDecimals(_ value: Double) -> Double {
        (value * 1_000_000).rounded() / 1_000_000 + 0
    }
}

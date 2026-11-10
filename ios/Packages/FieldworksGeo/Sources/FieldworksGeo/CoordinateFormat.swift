import Foundation

/// Schreibweise, in der Koordinaten angezeigt werden (Einstellung "Koordinatenformat").
/// Gespeichert wird immer WGS84 dezimal; das Format betrifft nur die Darstellung.
public enum CoordinateDisplayFormat: String, CaseIterable, Codable, Sendable {
    case decimalSign, decimalDirection
    case degreesSign, degreesDirection
    case degreesMinutesSign, degreesMinutesDirection
    case dmsSign, dmsDirection
    case utm, mgrs

    public static let `default`: CoordinateDisplayFormat = .decimalSign

    /// Deutscher Name für Einstellung und Beschriftung.
    public var title: String {
        switch self {
        case .decimalSign: return "Dezimalgrad (±)"
        case .decimalDirection: return "Dezimalgrad (N/S/E/W)"
        case .degreesSign: return "Grad mit ° (±)"
        case .degreesDirection: return "Grad mit ° (N/S/E/W)"
        case .degreesMinutesSign: return "Grad, Dezimalminuten (±)"
        case .degreesMinutesDirection: return "Grad, Dezimalminuten (N/S/E/W)"
        case .dmsSign: return "Grad, Minuten, Sekunden (±)"
        case .dmsDirection: return "Grad, Minuten, Sekunden (N/S/E/W)"
        case .utm: return "UTM"
        case .mgrs: return "MGRS"
        }
    }
}

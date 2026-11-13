import Foundation

/// Coordinate systems the user may type a position in. Only WGS84 is
/// ever stored; everything else is converted by Ortus. A new projection
/// is one more case.
public enum InputCoordinateSystem: String, CaseIterable, Identifiable, Sendable {
    case wgs84 = "4326"
    case webMercator = "3857"
    case etrs89utm32 = "25832"
    case etrs89utm33 = "25833"
    case gk2 = "31466"
    case gk3 = "31467"
    case mgrs

    public var id: String {
        rawValue
    }

    public var title: String {
        switch self {
        case .wgs84: "WGS 84 (EPSG:4326) - GPS"
        case .webMercator: "Web Mercator (EPSG:3857)"
        case .etrs89utm32: "ETRS89 / UTM Zone 32N (EPSG:25832)"
        case .etrs89utm33: "ETRS89 / UTM Zone 33N (EPSG:25833)"
        case .gk2: "DHDN / Gauß-Krüger Zone 2 (EPSG:31466)"
        case .gk3: "DHDN / Gauß-Krüger Zone 3 (EPSG:31467)"
        case .mgrs: "MGRS (Military Grid Reference System)"
        }
    }

    public var firstLabel: String {
        switch self {
        case .wgs84: "Breitengrad"
        case .webMercator: "X"
        case .etrs89utm32, .etrs89utm33, .gk2, .gk3: "Rechtswert"
        case .mgrs: "MGRS"
        }
    }

    /// nil for MGRS (single field).
    public var secondLabel: String? {
        switch self {
        case .wgs84: "Längengrad"
        case .webMercator: "Y"
        case .etrs89utm32, .etrs89utm33, .gk2, .gk3: "Hochwert"
        case .mgrs: nil
        }
    }

    public var placeholder: String {
        switch self {
        case .wgs84: "49.681230"
        case .webMercator: "1116000"
        case .etrs89utm32: "574400"
        case .etrs89utm33: "574400"
        case .gk2: "2574500"
        case .gk3: "3574500"
        case .mgrs: "32U NA 01234 56789"
        }
    }
}

public enum CoordinateInputError: Error, Equatable, Sendable {
    case invalidNumber
}

/// Raw user input for a position in one `InputCoordinateSystem`.
/// MGRS uses `first` only.
public struct CoordinateInput: Equatable, Sendable {
    public var system: InputCoordinateSystem
    public var first: String
    public var second: String

    public init(system: InputCoordinateSystem, first: String = "", second: String = "") {
        self.system = system
        self.first = first
        self.second = second
    }

    /// Ortus query parameters for this input. Throws
    /// `CoordinateInputError.invalidNumber` for empty or unparsable fields.
    public func queryItems() throws -> [URLQueryItem] {
        switch system {
        case .wgs84:
            guard let lat = CoordinateConverter.parseGeographicComponent(first, isLatitude: true),
                  let lon = CoordinateConverter.parseGeographicComponent(second, isLatitude: false)
            else { throw CoordinateInputError.invalidNumber }
            return [
                URLQueryItem(name: "srid", value: system.rawValue),
                URLQueryItem(name: "lon", value: String(format: "%.6f", lon)),
                URLQueryItem(name: "lat", value: String(format: "%.6f", lat))
            ]
        case .mgrs:
            let text = first.filter { !$0.isWhitespace }.uppercased()
            guard !text.isEmpty else { throw CoordinateInputError.invalidNumber }
            return [URLQueryItem(name: "mgrs", value: text)]
        default:
            guard let x = Self.number(first), let y = Self.number(second) else {
                throw CoordinateInputError.invalidNumber
            }
            return [
                URLQueryItem(name: "srid", value: system.rawValue),
                URLQueryItem(name: "x", value: x),
                URLQueryItem(name: "y", value: y)
            ]
        }
    }

    /// Normalised numeric text (comma to point) or nil if not a finite number.
    private static func number(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard !t.isEmpty, let v = Double(t), v.isFinite else { return nil }
        return t
    }
}

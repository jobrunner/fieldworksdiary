import Foundation

/// Minimal JSON tree for Ortus values whose shape is not fixed (feature
/// ids, feature properties, license blocks).
public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    /// Compact JSON text with sorted keys (deterministic).
    var jsonString: String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? enc.encode(self) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Text form of a number without a trailing ".0" for integral values.
    static func numberString(_ n: Double) -> String {
        if n == n.rounded(), abs(n) < 1e15 { return String(Int(n)) }
        return String(n)
    }
}

/// Subset of Ortus' `GET /api/v1/query` response we consume. Mirrors Go
/// `services.OrtusResponse`; unknown fields are ignored.
public struct OrtusResponse: Decodable, Sendable {
    public struct Coordinate: Decodable, Sendable { public var lon: Double; public var lat: Double }

    public struct Feature: Decodable, Sendable {
        public var id: JSONValue?
        public var layer: String?
        public var properties: [String: JSONValue]?
    }

    public struct SourceResult: Decodable, Sendable {
        public var sourceID: String?
        public var sourceName: String?
        public var features: [Feature]?
        public var license: JSONValue?
        enum CodingKeys: String, CodingKey {
            case sourceID = "source_id", sourceName = "source_name", features, license
        }
    }

    public struct AdminUnit: Decodable, Sendable {
        public var level: Int
        public var name: String?
        public var nameNative: String?
        public var equivalent: String?
        public var localTerm: String?
        enum CodingKeys: String, CodingKey {
            case level, name, nameNative = "name_native", equivalent, localTerm = "local_term"
        }

        /// A missing `level` decodes as 0 (as in Go) instead of failing the
        /// whole response; level 0 maps to no column.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            level = try c.decodeIfPresent(Int.self, forKey: .level) ?? 0
            name = try c.decodeIfPresent(String.self, forKey: .name)
            nameNative = try c.decodeIfPresent(String.self, forKey: .nameNative)
            equivalent = try c.decodeIfPresent(String.self, forKey: .equivalent)
            localTerm = try c.decodeIfPresent(String.self, forKey: .localTerm)
        }
    }

    public struct Admin: Decodable, Sendable {
        public var countryISO: String?
        public var hierarchy: [AdminUnit]?
        enum CodingKeys: String, CodingKey { case countryISO = "country_iso", hierarchy }
    }

    public struct Named: Decodable, Sendable {
        public var name: String?
        public var nameNative: String?
        enum CodingKeys: String, CodingKey { case name, nameNative = "name_native" }
    }

    public struct Mountains: Decodable, Sendable {
        public var mountain: Named?
        public var range: Named?
    }

    public struct Bearing: Decodable, Sendable {
        public var label: String?
        public var reference: String?
        public var compass: String?
        public var distanceKm: Double?
        public var inside: Bool?
        enum CodingKeys: String, CodingKey {
            case label, reference, compass, distanceKm = "distance_km", inside
        }
    }

    public struct Exposure: Decodable, Sendable {
        public var slopeDeg: Double?
        public var aspectDeg: Double?
        public var aspectCompass: String?
        public var flat: Bool?
        enum CodingKeys: String, CodingKey {
            case slopeDeg = "slope_deg", aspectDeg = "aspect_deg", aspectCompass = "aspect_compass", flat
        }
    }

    public struct Elevation: Decodable, Sendable {
        public var meters: Double?
        public var accuracyM: Double?
        public var seaLevel: Bool?
        enum CodingKeys: String, CodingKey { case meters, accuracyM = "accuracy_m", seaLevel = "sea_level" }
    }

    public struct Gazetteer: Decodable, Sendable {
        public var admin: Admin?
        public var islands: [Named]?
        public var mountains: Mountains?
        public var bearing: Bearing?
        public var exposure: Exposure?
        public var elevation: Elevation?
    }

    public var wgs84: Coordinate?
    public var results: [SourceResult]?
    public var gazetteer: Gazetteer?
}

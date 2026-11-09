import CryptoKit
import Foundation

/// One stored admin unit.
public struct AdminValue: Codable, Equatable, Sendable {
    public var name: String
    public var native: String
    public var level: Int

    public init(name: String, native: String = "", level: Int = 0) {
        self.name = name
        self.native = native
        self.level = level
    }
}

/// Shared (deduplicated) part of a location. Mirrors Go `geoplace.Place`.
public struct Place: Codable, Equatable, Sendable {
    public var countryISO: String
    public var admin: [AdminTier: AdminValue]
    public var island: String
    public var mountainRange: String
    public var mountain: String

    public init(countryISO: String, admin: [AdminTier: AdminValue] = [:],
                island: String = "", mountainRange: String = "", mountain: String = "") {
        self.countryISO = countryISO
        self.admin = admin
        self.island = island
        self.mountainRange = mountainRange
        self.mountain = mountain
    }

    /// Lowercase hex SHA-256 over the "|"-joined country ISO, then name,
    /// native and level for every tier in `AdminTier.allCases` order (absent
    /// tier: "", "", "0"), then island, mountain range, mountain. Must equal
    /// Go `Place.DedupHash`.
    public var dedupHash: String {
        var parts = [Self.normalize(countryISO)]
        for tier in AdminTier.allCases {
            let v = admin[tier] ?? AdminValue(name: "", native: "", level: 0)
            parts.append(Self.normalize(v.name))
            parts.append(Self.normalize(v.native))
            parts.append(String(v.level))
        }
        parts.append(Self.normalize(island))
        parts.append(Self.normalize(mountainRange))
        parts.append(Self.normalize(mountain))
        let digest = SHA256.hash(data: Data(parts.joined(separator: "|").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Trim, NFC, lowercase. Parity caveat: Go `strings.ToLower` and Swift
    /// `lowercased()` may differ for exotic characters (e.g. "İ"); both are
    /// locale-independent and agree on everything we expect in place names.
    private static func normalize(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
            .lowercased()
    }
}

/// Per-sample geo values. Mirrors Go `geoplace.SampleGeo`.
public struct SampleGeo: Equatable, Sendable {
    public var elevationDEM: Double?
    public var elevationDEMAccuracy: Double?
    public var slopeDeg: Double?
    public var aspectDeg: Double?
    public var aspectCompass: String = ""
    public var terrainFlat: Bool = false

    public var bearingLabel: String = ""
    public var bearingReference: String = ""
    public var bearingCompass: String = ""
    public var bearingDistanceKm: Double?
    public var bearingInside: Bool = false

    public var mtbSheetNumber: String = ""
    public var mtbSheetName: String = ""
    /// 0 means none.
    public var mtbQuadrant: Int = 0

    public init() {}
}

/// One Ortus source feature at the query point.
public struct OrtusFeature: Codable, Equatable, Sendable {
    public var sourceID: String
    public var sourceName: String
    public var layer: String
    public var featureID: String
    public var propertiesJSON: String
    public var licenseJSON: String?

    public init(sourceID: String, sourceName: String, layer: String, featureID: String,
                propertiesJSON: String, licenseJSON: String?) {
        self.sourceID = sourceID
        self.sourceName = sourceName
        self.layer = layer
        self.featureID = featureID
        self.propertiesJSON = propertiesJSON
        self.licenseJSON = licenseJSON
    }
}

/// Mapped Ortus response. `place` is nil when Ortus has no admin coverage.
public struct OrtusResult: Sendable {
    public var place: Place?
    public var geo: SampleGeo
    public var features: [OrtusFeature]
}

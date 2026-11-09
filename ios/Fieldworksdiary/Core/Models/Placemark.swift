import FieldworksGeo
import Foundation

/// Parsed reverse-geocoding result. Localities reference these; the
/// table is deduplicated by `dedupHash` server-side so multiple
/// localities can share the same address record.
///
/// The wire format mirrors the Phase-R3 PocketBase schema:
///
///   - `country` (ISO 3166-1 alpha-2)
///   - `administrative_area`, `sub_administrative_area`
///   - `locality`, `sub_locality`
///   - `postal_code`, `name`, `thoroughfare`
///   - `geocoding_source` (`backend_service` | `manual`; legacy
///     `backend-service` is still decoded)
///   - `geocoding_service_version`, `geocoding_date`
///   - `dedup_hash`
///   - Phase O: `country_iso`, `admin_<tier>` / `_level` / `_native`
///     per `AdminTier`, `island`, `mountain_range`, `mountain`, `owner`
///
/// The client never writes placemark records directly (CreateRule is
/// nil); it asks `POST /api/placemarks/resolve` to look one up or
/// create it, and decodes the returned record.
struct Placemark: Decodable, Identifiable, Equatable {
    let id: String
    let country: String
    let administrativeArea: String?
    let subAdministrativeArea: String?
    let locality: String?
    let subLocality: String?
    let postalCode: String?
    let name: String?
    let thoroughfare: String?
    let geocodingSource: GeocodingSource
    let geocodingServiceVersion: String?
    let geocodingDate: Date?
    let dedupHash: String
    // Phase O — Ortus place columns. Empty on legacy rows.
    let countryISO: String
    let admin: [AdminTier: AdminValue]
    let island: String
    let mountainRange: String
    let mountain: String
    /// Owning user for `manual` rows; nil for shared rows.
    let owner: String?

    /// The deduplicated place the record describes.
    var place: Place {
        Place(countryISO: countryISO, admin: admin, island: island,
              mountainRange: mountainRange, mountain: mountain)
    }

    /// Where the placemark came from. `manual` placemarks are
    /// sacrosanct — the auto-geocode hook must skip them.
    ///
    /// Phase O renamed the wire value `backend-service` →
    /// `backend_service`. Decoding accepts both spellings (old
    /// servers, cached rows); encoding always writes the new one.
    enum GeocodingSource: String, Codable, Equatable {
        case backendService = "backend_service"
        case manual

        init(wire: String?) {
            switch wire {
            case "manual": self = .manual
            default: self = .backendService
            }
        }

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self.init(wire: raw)
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, country, locality, name, thoroughfare, island, mountain, owner
        case countryISO = "country_iso"
        case mountainRange = "mountain_range"
        case administrativeArea = "administrative_area"
        case subAdministrativeArea = "sub_administrative_area"
        case subLocality = "sub_locality"
        case postalCode = "postal_code"
        case geocodingSource = "geocoding_source"
        case geocodingServiceVersion = "geocoding_service_version"
        case geocodingDate = "geocoding_date"
        case dedupHash = "dedup_hash"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        country = (try? c.decode(String.self, forKey: .country)) ?? ""
        let admin = (try? c.decode(String.self, forKey: .administrativeArea)) ?? ""
        administrativeArea = admin.isEmpty ? nil : admin
        let subAdmin = (try? c.decode(String.self, forKey: .subAdministrativeArea)) ?? ""
        subAdministrativeArea = subAdmin.isEmpty ? nil : subAdmin
        let loc = (try? c.decode(String.self, forKey: .locality)) ?? ""
        locality = loc.isEmpty ? nil : loc
        let subLoc = (try? c.decode(String.self, forKey: .subLocality)) ?? ""
        subLocality = subLoc.isEmpty ? nil : subLoc
        let pc = (try? c.decode(String.self, forKey: .postalCode)) ?? ""
        postalCode = pc.isEmpty ? nil : pc
        let n = (try? c.decode(String.self, forKey: .name)) ?? ""
        name = n.isEmpty ? nil : n
        let th = (try? c.decode(String.self, forKey: .thoroughfare)) ?? ""
        thoroughfare = th.isEmpty ? nil : th
        geocodingSource = GeocodingSource(wire: try? c.decode(String.self, forKey: .geocodingSource))
        let ver = (try? c.decode(String.self, forKey: .geocodingServiceVersion)) ?? ""
        geocodingServiceVersion = ver.isEmpty ? nil : ver
        geocodingDate = try? c.decode(Date.self, forKey: .geocodingDate)
        dedupHash = (try? c.decode(String.self, forKey: .dedupHash)) ?? ""
        countryISO = (try? c.decode(String.self, forKey: .countryISO)) ?? ""
        island = (try? c.decode(String.self, forKey: .island)) ?? ""
        mountainRange = (try? c.decode(String.self, forKey: .mountainRange)) ?? ""
        mountain = (try? c.decode(String.self, forKey: .mountain)) ?? ""
        let ownerID = (try? c.decode(String.self, forKey: .owner)) ?? ""
        owner = ownerID.isEmpty ? nil : ownerID
        // Tier columns are dynamic (`admin_<tier>`, `_level`,
        // `_native`); same presence rule as Go `PlaceFromRecord`.
        let dyn = try decoder.container(keyedBy: AnyCodingKey.self)
        var tiers: [AdminTier: AdminValue] = [:]
        for tier in AdminTier.allCases {
            let base = tier.rawValue
            let value = AdminValue(
                name: dyn.string(base),
                native: dyn.string(base + "_native"),
                level: dyn.int(base + "_level")
            )
            if !value.name.isEmpty || !value.native.isEmpty || value.level != 0 {
                tiers[tier] = value
            }
        }
        self.admin = tiers
    }
}

/// String-keyed coding key for the per-tier placemark columns.
struct AnyCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue _: Int) { nil }
}

private extension KeyedDecodingContainer where K == AnyCodingKey {
    func string(_ key: String) -> String {
        (try? decode(String.self, forKey: AnyCodingKey(stringValue: key))) ?? ""
    }

    /// PocketBase numbers arrive as JSON numbers (possibly 1.0).
    func int(_ key: String) -> Int {
        (try? decode(Double.self, forKey: AnyCodingKey(stringValue: key))).map { Int($0) } ?? 0
    }
}

struct PlacemarkListResponse: Decodable {
    let items: [Placemark]
    let totalItems: Int?
    let totalPages: Int?
}

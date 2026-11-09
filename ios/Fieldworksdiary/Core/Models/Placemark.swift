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
///
/// We never *write* placemarks from the client (the backend hook
/// owns them); we only decode them when they arrive attached to a
/// Locality.
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
        case id, country, locality, name, thoroughfare
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
    }
}

struct PlacemarkListResponse: Decodable {
    let items: [Placemark]
    let totalItems: Int?
    let totalPages: Int?
}

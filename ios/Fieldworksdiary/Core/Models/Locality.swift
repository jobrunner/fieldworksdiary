import Foundation

/// Network shape of a Locality record. Mirrors the Phase-1 schema in
/// `backend/migrations/1700000001_init_app_collections.go`.
struct Locality: Decodable, Identifiable, Equatable {
    let id: String
    let name: String
    let centroidLat: Double?
    let centroidLon: Double?
    let radiusM: Double?
    let notes: String

    enum CodingKeys: String, CodingKey {
        case id, name, notes
        case centroidLat = "centroid_lat"
        case centroidLon = "centroid_lon"
        case radiusM     = "radius_m"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        // PB returns 0 for empty number fields; treat that as nil so
        // the UI can render "—" instead of a misleading 0,0 pin.
        let lat = try? c.decode(Double.self, forKey: .centroidLat)
        let lon = try? c.decode(Double.self, forKey: .centroidLon)
        centroidLat = (lat == 0 ? nil : lat)
        centroidLon = (lon == 0 ? nil : lon)
        let r = try? c.decode(Double.self, forKey: .radiusM)
        radiusM = (r == 0 ? nil : r)
        notes = (try? c.decode(String.self, forKey: .notes)) ?? ""
    }
}

struct LocalityListResponse: Decodable {
    let items: [Locality]
    let totalItems: Int?
    let totalPages: Int?
}

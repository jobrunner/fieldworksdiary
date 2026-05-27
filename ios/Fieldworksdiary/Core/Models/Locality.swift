import Foundation

/// Network shape of a Locality record. Mirrors the Phase-1 schema
/// plus the R3 extensions (explicit lat/lon, accuracy, location
/// source, placemark relation, sync fields).
///
/// The legacy `centroid_*` columns stay readable for backwards
/// compatibility while clients move over to `latitude`/`longitude`.
struct Locality: Decodable, Identifiable, Equatable {
    let id: String
    /// Sammler-vergebener Name ("Am Wasser", "Waldstück", …) — UI-
    /// only, may be empty on rows the client never named.
    let name: String
    /// Canonical point location (Spec §2). Required-at-use, optional
    /// at the wire level so legacy rows that only had `centroid_*`
    /// still decode.
    let latitude: Double?
    let longitude: Double?
    let altitude: Double?
    let horizontalAccuracy: Double?
    let verticalAccuracy: Double?
    /// Where the coordinate came from. Drives whether downstream
    /// code may overwrite it.
    let locationSource: LocationSource
    /// Project-local "Fundort"-Nummer. Not unique.
    let locationNumber: String?
    /// Placemark id (PocketBase relation) — the parsed reverse-
    /// geocoding result for this point. Empty wire-string ⇒ nil.
    let placemark: String?
    /// Observed scatter radius (in metres). Empirical, may be 0.
    let radiusM: Double?
    let notes: String
    /// Monotone sync counter, default 1.
    let version: Int
    let clientUuid: String?
    let clientUpdatedAt: Date?
    /// Server-side fusion flagged this locality as a possible
    /// duplicate that a human should look at (Spec §5.2 / R6.1).
    let needsHumanReview: Bool
    /// Legacy centroid columns — read for backwards compat, will be
    /// dropped after the data migration in R10.
    let centroidLat: Double?
    let centroidLon: Double?

    enum CodingKeys: String, CodingKey {
        case id, name, notes, version, latitude, longitude, altitude, placemark
        case horizontalAccuracy = "horizontal_accuracy"
        case verticalAccuracy = "vertical_accuracy"
        case locationSource = "location_source"
        case locationNumber = "location_number"
        case radiusM = "radius_m"
        case clientUuid = "client_uuid"
        case clientUpdatedAt = "client_updated_at"
        case needsHumanReview = "needs_human_review"
        case centroidLat = "centroid_lat"
        case centroidLon = "centroid_lon"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = (try? c.decode(String.self, forKey: .name)) ?? ""

        // PB returns 0 for empty number fields; treat that as nil so
        // the UI can render "—" instead of a misleading 0,0 pin.
        let cLat = try? c.decode(Double.self, forKey: .centroidLat)
        let cLon = try? c.decode(Double.self, forKey: .centroidLon)
        centroidLat = (cLat == 0 ? nil : cLat)
        centroidLon = (cLon == 0 ? nil : cLon)

        // Prefer the new columns; fall back to centroid_* for legacy
        // rows that didn't get touched by the data backfill yet.
        let newLat = try? c.decode(Double.self, forKey: .latitude)
        let newLon = try? c.decode(Double.self, forKey: .longitude)
        latitude = (newLat == 0 ? nil : newLat) ?? centroidLat
        longitude = (newLon == 0 ? nil : newLon) ?? centroidLon

        let alt = try? c.decode(Double.self, forKey: .altitude)
        altitude = (alt == 0 ? nil : alt)
        let hAcc = try? c.decode(Double.self, forKey: .horizontalAccuracy)
        horizontalAccuracy = (hAcc == 0 ? nil : hAcc)
        let vAcc = try? c.decode(Double.self, forKey: .verticalAccuracy)
        verticalAccuracy = (vAcc == 0 ? nil : vAcc)

        locationSource = LocationSource(wire: try? c.decode(String.self, forKey: .locationSource))
        let num = (try? c.decode(String.self, forKey: .locationNumber)) ?? ""
        locationNumber = num.isEmpty ? nil : num
        let pm = (try? c.decode(String.self, forKey: .placemark)) ?? ""
        placemark = pm.isEmpty ? nil : pm

        let r = try? c.decode(Double.self, forKey: .radiusM)
        radiusM = (r == 0 ? nil : r)
        notes = (try? c.decode(String.self, forKey: .notes)) ?? ""
        version = (try? c.decode(Int.self, forKey: .version)) ?? 1
        let cu = (try? c.decode(String.self, forKey: .clientUuid)) ?? ""
        clientUuid = cu.isEmpty ? nil : cu
        clientUpdatedAt = try? c.decode(Date.self, forKey: .clientUpdatedAt)
        needsHumanReview = (try? c.decode(Bool.self, forKey: .needsHumanReview)) ?? false
    }
}

struct LocalityListResponse: Decodable {
    let items: [Locality]
    let totalItems: Int?
    let totalPages: Int?
}

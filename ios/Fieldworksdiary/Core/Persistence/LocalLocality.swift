import Foundation
import GRDB

struct LocalLocality: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Equatable {
    var id: String
    var name: String
    /// Canonical point location (Spec §2). Optional in the local
    /// schema so legacy rows that only had `centroid_*` still decode.
    var latitude: Double?
    var longitude: Double?
    var altitude: Double?
    var horizontalAccuracy: Double?
    var verticalAccuracy: Double?
    /// `LocationSource.rawValue` (Int). 0 = user (default).
    var locationSource: Int
    var locationNumber: String?
    /// Placemark id (PocketBase relation).
    var placemark: String?
    var radiusM: Double?
    var notes: String
    var version: Int
    var clientUuid: String?
    var clientUpdatedAt: Date?
    /// Server-side fusion flag (Spec §5.2 / R6.1) — drives the
    /// "möglicherweise doppelt" review surface in the list.
    var needsHumanReview: Bool
    /// Legacy centroid columns — read for backwards compat until the
    /// data migration in R10 drops them.
    var centroidLat: Double?
    var centroidLon: Double?
    var backendUpdatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, name, notes, version
        case latitude, longitude, altitude, placemark
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
        case backendUpdatedAt = "backend_updated_at"
    }

    static let databaseTableName = "local_localities"
}

extension LocalLocality {
    init(from remote: Locality) {
        id = remote.id
        name = remote.name
        latitude = remote.latitude
        longitude = remote.longitude
        altitude = remote.altitude
        horizontalAccuracy = remote.horizontalAccuracy
        verticalAccuracy = remote.verticalAccuracy
        locationSource = remote.locationSource.rawValue
        locationNumber = remote.locationNumber
        placemark = remote.placemark
        radiusM = remote.radiusM
        notes = remote.notes
        version = remote.version
        clientUuid = remote.clientUuid
        clientUpdatedAt = remote.clientUpdatedAt
        needsHumanReview = remote.needsHumanReview
        centroidLat = remote.centroidLat
        centroidLon = remote.centroidLon
        backendUpdatedAt = Date()
    }
}

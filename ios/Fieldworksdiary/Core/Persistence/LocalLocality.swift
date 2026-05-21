import Foundation
import GRDB

struct LocalLocality: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Equatable {
    var id: String
    var name: String
    var centroidLat: Double?
    var centroidLon: Double?
    var radiusM: Double?
    var notes: String
    var backendUpdatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, name, notes
        case centroidLat       = "centroid_lat"
        case centroidLon       = "centroid_lon"
        case radiusM           = "radius_m"
        case backendUpdatedAt  = "backend_updated_at"
    }

    static let databaseTableName = "local_localities"
}

extension LocalLocality {
    init(from remote: Locality) {
        self.id = remote.id
        self.name = remote.name
        self.centroidLat = remote.centroidLat
        self.centroidLon = remote.centroidLon
        self.radiusM = remote.radiusM
        self.notes = remote.notes
        self.backendUpdatedAt = Date()
    }
}

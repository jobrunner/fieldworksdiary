import Foundation
import GRDB

/// Local mirror of a `Placemark`. Placemarks are write-only from
/// the backend's perspective (the geocoding hook creates them); the
/// client just caches them so the UI can render a locality without
/// an extra network round-trip.
struct LocalPlacemark: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Equatable {
    var id: String
    var country: String
    var administrativeArea: String?
    var subAdministrativeArea: String?
    var locality: String?
    var subLocality: String?
    var postalCode: String?
    var name: String?
    var thoroughfare: String?
    /// `manual` or `backend-service` — see `Placemark.GeocodingSource`.
    var geocodingSource: String
    var geocodingServiceVersion: String?
    var geocodingDate: Date?
    var dedupHash: String
    var backendUpdatedAt: Date

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
        case backendUpdatedAt = "backend_updated_at"
    }

    static let databaseTableName = "local_placemarks"
}

extension LocalPlacemark {
    init(from remote: Placemark) {
        id = remote.id
        country = remote.country
        administrativeArea = remote.administrativeArea
        subAdministrativeArea = remote.subAdministrativeArea
        locality = remote.locality
        subLocality = remote.subLocality
        postalCode = remote.postalCode
        name = remote.name
        thoroughfare = remote.thoroughfare
        geocodingSource = remote.geocodingSource.rawValue
        geocodingServiceVersion = remote.geocodingServiceVersion
        geocodingDate = remote.geocodingDate
        dedupHash = remote.dedupHash
        backendUpdatedAt = Date()
    }
}

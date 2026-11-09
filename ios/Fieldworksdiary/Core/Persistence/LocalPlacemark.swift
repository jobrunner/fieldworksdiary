import FieldworksGeo
import Foundation
import GRDB

/// Local mirror of a `Placemark`. Placemarks are written by the
/// backend (geocoding hook) or — since Phase O2 — created locally
/// from an Ortus response via `LocalPlacemarkStore.lookupOrCreate`.
///
/// Row mapping is hand-written (not `Codable`) because the Ortus place
/// data lives in flat per-tier columns (`admin_<tier>`,
/// `admin_<tier>_level`, `admin_<tier>_native`, mirroring the backend
/// schema) but is exposed as `admin: [AdminTier: AdminValue]`.
struct LocalPlacemark: FetchableRecord, MutablePersistableRecord, Identifiable, Equatable {
    var id: String
    /// Legacy country column (NOT NULL). Mirrors `countryISO` for
    /// rows created from Ortus, like the backend's `ApplyPlace`.
    var country: String
    var administrativeArea: String?
    var subAdministrativeArea: String?
    var locality: String?
    var subLocality: String?
    var postalCode: String?
    var name: String?
    var thoroughfare: String?
    /// `manual` or `backend_service` — see `Placemark.GeocodingSource`.
    var geocodingSource: String
    var geocodingServiceVersion: String?
    var geocodingDate: Date?
    var dedupHash: String
    var backendUpdatedAt: Date

    // MARK: Phase O2 — Ortus place columns

    var countryISO: String = ""
    var admin: [AdminTier: AdminValue] = [:]
    var island: String = ""
    var mountainRange: String = ""
    var mountain: String = ""
    /// PocketBase user id for manual rows; nil for shared rows.
    var owner: String?
    /// PocketBase id once known. Rows pulled from the server use the
    /// backend id as `id` too; locally created rows have a UUID `id`
    /// and get `backendId` set after sync.
    var backendId: String?

    static let databaseTableName = "local_placemarks"

    /// The deduplicated place this row describes.
    var place: Place {
        Place(countryISO: countryISO, admin: admin, island: island,
              mountainRange: mountainRange, mountain: mountain)
    }

    enum Columns {
        static let id = "id"
        static let country = "country"
        static let administrativeArea = "administrative_area"
        static let subAdministrativeArea = "sub_administrative_area"
        static let locality = "locality"
        static let subLocality = "sub_locality"
        static let postalCode = "postal_code"
        static let name = "name"
        static let thoroughfare = "thoroughfare"
        static let geocodingSource = "geocoding_source"
        static let geocodingServiceVersion = "geocoding_service_version"
        static let geocodingDate = "geocoding_date"
        static let dedupHash = "dedup_hash"
        static let backendUpdatedAt = "backend_updated_at"
        static let countryISO = "country_iso"
        static let island = "island"
        static let mountainRange = "mountain_range"
        static let mountain = "mountain"
        static let owner = "owner"
        static let backendId = "backend_id"
    }
}

extension LocalPlacemark {
    init(row: Row) throws {
        id = row[Columns.id]
        country = row[Columns.country]
        administrativeArea = row[Columns.administrativeArea]
        subAdministrativeArea = row[Columns.subAdministrativeArea]
        locality = row[Columns.locality]
        subLocality = row[Columns.subLocality]
        postalCode = row[Columns.postalCode]
        name = row[Columns.name]
        thoroughfare = row[Columns.thoroughfare]
        geocodingSource = row[Columns.geocodingSource]
        geocodingServiceVersion = row[Columns.geocodingServiceVersion]
        geocodingDate = row[Columns.geocodingDate]
        dedupHash = row[Columns.dedupHash]
        backendUpdatedAt = row[Columns.backendUpdatedAt]
        countryISO = row[Columns.countryISO] ?? ""
        var admin: [AdminTier: AdminValue] = [:]
        for tier in AdminTier.allCases {
            let value = AdminValue(
                name: row[tier.rawValue] ?? "",
                native: row["\(tier.rawValue)_native"] ?? "",
                level: row["\(tier.rawValue)_level"] ?? 0
            )
            // Same presence rule as Go `PlaceFromRecord`.
            if !value.name.isEmpty || !value.native.isEmpty || value.level != 0 {
                admin[tier] = value
            }
        }
        self.admin = admin
        island = row[Columns.island] ?? ""
        mountainRange = row[Columns.mountainRange] ?? ""
        mountain = row[Columns.mountain] ?? ""
        owner = row[Columns.owner]
        backendId = row[Columns.backendId]
    }

    func encode(to container: inout PersistenceContainer) throws {
        container[Columns.id] = id
        container[Columns.country] = country
        container[Columns.administrativeArea] = administrativeArea
        container[Columns.subAdministrativeArea] = subAdministrativeArea
        container[Columns.locality] = locality
        container[Columns.subLocality] = subLocality
        container[Columns.postalCode] = postalCode
        container[Columns.name] = name
        container[Columns.thoroughfare] = thoroughfare
        container[Columns.geocodingSource] = geocodingSource
        container[Columns.geocodingServiceVersion] = geocodingServiceVersion
        container[Columns.geocodingDate] = geocodingDate
        container[Columns.dedupHash] = dedupHash
        container[Columns.backendUpdatedAt] = backendUpdatedAt
        container[Columns.countryISO] = countryISO
        // Absent tiers are stored as "" / 0 like the backend's
        // `ApplyPlace`, so a later sync round-trip compares equal.
        for tier in AdminTier.allCases {
            let value = admin[tier] ?? AdminValue(name: "", native: "", level: 0)
            container[tier.rawValue] = value.name
            container["\(tier.rawValue)_native"] = value.native
            container["\(tier.rawValue)_level"] = value.level
        }
        container[Columns.island] = island
        container[Columns.mountainRange] = mountainRange
        container[Columns.mountain] = mountain
        container[Columns.owner] = owner
        container[Columns.backendId] = backendId
    }
}

extension LocalPlacemark {
    /// Cache row for a placemark fetched from the backend. Ortus place
    /// columns stay empty until Task 16 extends the `Placemark` wire
    /// model.
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
        backendId = remote.id
    }

    /// New local row for an Ortus place. `country` mirrors the ISO
    /// code (legacy NOT NULL column), as the backend does.
    init(id: String, place: Place, source: Placemark.GeocodingSource, now: Date = Date()) {
        self.id = id
        country = place.countryISO
        geocodingSource = source.rawValue
        geocodingDate = now
        dedupHash = place.dedupHash
        backendUpdatedAt = now
        countryISO = place.countryISO
        admin = place.admin
        island = place.island
        mountainRange = place.mountainRange
        mountain = place.mountain
    }
}

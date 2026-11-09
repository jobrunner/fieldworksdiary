import Foundation
import GRDB

enum SyncStatus: String, Codable, DatabaseValueConvertible {
    case pending // not yet pushed
    case syncing // push in flight
    case synced // backend confirmed
    case failed // last attempt errored, will be retried
}

/// Provenance of `LocalSample.elevation`. Raw values are the
/// PocketBase select values on `samples.elevation_source`.
enum ElevationSource: String, Codable, DatabaseValueConvertible {
    case locationService = "location_service"
    case backendService = "backend_service"
    case manual
}

/// Provenance of `LocalSample.timezone`. Raw values are the
/// PocketBase select values on `samples.timezone_source`.
enum TimezoneSource: String, Codable, DatabaseValueConvertible {
    case device
    case locationService = "location_service"
    case manual
}

/// State of a sample's place data (`samples.location_status`).
/// `pending` until the backend (or the offline inheritance from an
/// earlier sample of the same day) has filled it in.
enum LocationStatus: String, Codable, DatabaseValueConvertible {
    case pending
    case inherited
    case manual
    case backendService = "backend_service"
}

/// Local mirror of a Sample. R3 renamed the user-facing columns to
/// match the Spec; the historical names live on in the V1–V9 GRDB
/// migrations and the V10 rename. SQLite preserves data through
/// `ALTER TABLE RENAME COLUMN`.
struct LocalSample: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Equatable {
    var id: String // client-side UUID, also `client_uuid` on the wire
    var backendId: String? // PocketBase id, set on first successful push
    var sampleID: String // provisional or backend-confirmed
    var backendCode: String? // set if server relabelled (rare)
    var originalCode: String? // = `sampleID` at push-time when relabelled
    var userId: String
    var collectingDay: String // YYYY-MM-DD in user TZ
    var latitude: Double?
    var longitude: Double?
    var horizontalAccuracy: Double?
    var verticalAccuracy: Double?
    /// Metres above sea level. Was `altitude` until Phase O2; the
    /// legacy column stays in SQLite until O3 but is no longer read.
    var elevation: Double?
    var beginDate: Date
    var endDate: Date?
    var isAllDay: Bool
    /// IANA identifier of the zone `beginDate` is read in.
    var timezone: String
    var timezoneSource: TimezoneSource?
    var notes: String
    var marked: Bool
    var fieldtrip: String? // backend fieldtrip id, set after sync
    var locality: String? // backend locality id, set after sync/fusion
    /// Provenance of the coordinate. Persisted as the raw Int.
    var locationSource: Int
    var version: Int
    var adminUnitsLocality: String?
    var adminUnitsCountry: String?
    var mtbSheetNumber: String?
    var mtbSheetName: String?
    var syncStatus: SyncStatus
    var syncError: String?
    var createdAt: Date
    var updatedAt: Date

    // MARK: Phase O2 — Ortus location data (server-filled)

    var elevationSource: ElevationSource?
    var locationStatus: LocationStatus = .pending
    /// Placemark id (backend id once synced, local UUID before).
    var placemark: String?
    var placemarkSuggestion: String?
    /// TK25 quadrant 1–4; nil or 0 means none.
    var mtbQuadrant: Int?
    var slopeDeg: Double?
    var aspectDeg: Double?
    var aspectCompass: String?
    var terrainFlat: Bool = false
    var bearingLabel: String?
    var bearingReference: String?
    var bearingDistanceKm: Double?
    var bearingCompass: String?
    var bearingInside: Bool = false

    enum CodingKeys: String, CodingKey {
        case id
        case backendId = "backend_id"
        case sampleID = "sample_id"
        case backendCode = "backend_code"
        case originalCode = "original_code"
        case userId = "user_id"
        case collectingDay = "collecting_day"
        case latitude, longitude, elevation
        case horizontalAccuracy = "horizontal_accuracy"
        case verticalAccuracy = "vertical_accuracy"
        case beginDate = "begin_date"
        case endDate = "end_date"
        case isAllDay = "is_all_day"
        case timezone
        case timezoneSource = "timezone_source"
        case notes, marked, fieldtrip, locality, version
        case locationSource = "location_source"
        case adminUnitsLocality = "admin_units_locality"
        case adminUnitsCountry = "admin_units_country"
        case mtbSheetNumber = "mtb_sheet_number"
        case mtbSheetName = "mtb_sheet_name"
        case syncStatus = "sync_status"
        case syncError = "sync_error"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case elevationSource = "elevation_source"
        case locationStatus = "location_status"
        case placemark
        case placemarkSuggestion = "placemark_suggestion"
        case mtbQuadrant = "mtb_quadrant"
        case slopeDeg = "slope_deg"
        case aspectDeg = "aspect_deg"
        case aspectCompass = "aspect_compass"
        case terrainFlat = "terrain_flat"
        case bearingLabel = "bearing_label"
        case bearingReference = "bearing_reference"
        case bearingDistanceKm = "bearing_distance_km"
        case bearingCompass = "bearing_compass"
        case bearingInside = "bearing_inside"
    }

    static let databaseTableName = "local_samples"
}

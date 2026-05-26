import Foundation
import GRDB

enum SyncStatus: String, Codable, DatabaseValueConvertible {
    case pending // not yet pushed
    case syncing // push in flight
    case synced // backend confirmed
    case failed // last attempt errored, will be retried
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
    var altitude: Double?
    var beginDate: Date
    var endDate: Date?
    var isAllDay: Bool
    var timeZone: String
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

    enum CodingKeys: String, CodingKey {
        case id
        case backendId = "backend_id"
        case sampleID = "sample_id"
        case backendCode = "backend_code"
        case originalCode = "original_code"
        case userId = "user_id"
        case collectingDay = "collecting_day"
        case latitude, longitude, altitude
        case horizontalAccuracy = "horizontal_accuracy"
        case verticalAccuracy = "vertical_accuracy"
        case beginDate = "begin_date"
        case endDate = "end_date"
        case isAllDay = "is_all_day"
        case timeZone = "time_zone"
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
    }

    static let databaseTableName = "local_samples"
}

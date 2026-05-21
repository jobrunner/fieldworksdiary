import Foundation
import GRDB

enum SyncStatus: String, Codable, DatabaseValueConvertible {
    case pending // not yet pushed
    case syncing // push in flight
    case synced // backend confirmed
    case failed // last attempt errored, will be retried
}

struct LocalSample: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Equatable {
    var id: String // client-side UUID, also `client_uuid` on the wire
    var backendId: String? // PocketBase id, set on first successful push
    var code: String // provisional or backend-confirmed
    var backendCode: String? // set if server relabelled (rare)
    var originalCode: String? // = `code` at push-time when relabelled
    var userId: String
    var collectingDay: String // YYYY-MM-DD in user TZ
    var lat: Double
    var lon: Double
    var accuracyM: Double?
    var altitudeM: Double?
    var collectedFrom: Date
    var notes: String
    var marked: Bool
    var excursion: String? // backend excursion id, set after sync
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
        case code
        case backendCode = "backend_code"
        case originalCode = "original_code"
        case userId = "user_id"
        case collectingDay = "collecting_day"
        case lat, lon
        case accuracyM = "accuracy_m"
        case altitudeM = "altitude_m"
        case collectedFrom = "collected_from"
        case notes
        case marked
        case excursion
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

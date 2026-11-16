import Foundation
import GRDB

/// One photo attached to a `LocalSample`. The image bytes live on the
/// filesystem (Documents/photos/<sample_id>/<photo_id>.jpg) — this row
/// is just the index plus the sync state machine.
struct LocalPhoto: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Equatable {
    var id: String // client UUID, also `client_uuid` on the wire
    var sampleId: String // FK to local_samples.id (client UUID)
    var localPath: String // relative to Documents/
    var backendId: String? // PocketBase record id, set after upload
    var syncStatus: SyncStatus
    var syncError: String?
    var clientUuid: String
    var clientUpdatedAt: Date
    var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case sampleId = "sample_id"
        case localPath = "local_path"
        case backendId = "backend_id"
        case syncStatus = "sync_status"
        case syncError = "sync_error"
        case clientUuid = "client_uuid"
        case clientUpdatedAt = "client_updated_at"
        case createdAt = "created_at"
    }

    static let databaseTableName = "local_photos"
}

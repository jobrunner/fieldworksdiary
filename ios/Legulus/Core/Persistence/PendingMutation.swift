import Foundation
import GRDB

/// A queued write the `SyncRunner` will replay against the backend
/// once the network is up. Spec-aligned (R5.2):
/// `pending_mutations` is the single source of truth for "what we
/// owe the server" — the old `syncStatus` column on `Local*` becomes
/// purely informational once the SyncRunner moves over.
struct PendingMutation: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Equatable {
    enum EntityType: String, Codable, DatabaseValueConvertible {
        case sample
        case fieldtrip
        case locality
        case samplePhoto = "sample_photo"
        case determination
        case placemark
    }

    enum Operation: String, Codable, DatabaseValueConvertible {
        case create
        case update
        case delete
    }

    var id: String // UUID, opaque to the backend
    var entityType: EntityType
    /// Backend record id. Nil for `create` (we don't know the id
    /// until the response comes back), set otherwise.
    var entityId: String?
    var op: Operation
    /// JSON-encoded request payload, including `version` when the
    /// op is `update`.
    var payloadJson: Data
    var createdAt: Date
    var attempts: Int
    var lastAttemptAt: Date?
    var lastError: String?

    enum CodingKeys: String, CodingKey {
        case id
        case entityType = "entity_type"
        case entityId = "entity_id"
        case op
        case payloadJson = "payload_json"
        case createdAt = "created_at"
        case attempts
        case lastAttemptAt = "last_attempt_at"
        case lastError = "last_error"
    }

    static let databaseTableName = "pending_mutations"

    /// `attempts` value of a parked mutation: the SyncRunner gave up
    /// on it (repeated 409) but keeps it — with its payload flags —
    /// until the user taps „Erneut senden“ or a later update of the
    /// same sample succeeds. Parked rows are never picked up by a pass.
    static let parkedAttempts = -1

    var isParked: Bool {
        attempts < 0
    }
}

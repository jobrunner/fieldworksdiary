import Foundation
import GRDB

/// CRUD wrapper around the `pending_mutations` table. The SyncRunner
/// owns the lifecycle — `enqueue` on a local write, `dequeue` after
/// a successful push, `recordFailure` on a network error.
///
/// The retry-order is implicit in the table's secondary index on
/// (entity_type, created_at), but the SyncRunner enforces FK-order
/// (Placemark → Locality → Fieldtrip → Sample → SamplePhoto →
/// Determination, Spec §4.2) by reading per-type buckets.
final class PendingMutationsStore {
    let database: Database

    init(database: Database) {
        self.database = database
    }

    /// Drop a new mutation onto the queue. Use a fresh UUID per call;
    /// `entityId` may be nil if this is a `create` and the backend id
    /// isn't known yet.
    func enqueue(
        entityType: PendingMutation.EntityType,
        entityId: String?,
        op: PendingMutation.Operation,
        payload: Data
    ) throws -> PendingMutation {
        var mutation = PendingMutation(
            id: UUID().uuidString,
            entityType: entityType,
            entityId: entityId,
            op: op,
            payloadJson: payload,
            createdAt: Date(),
            attempts: 0,
            lastAttemptAt: nil,
            lastError: nil
        )
        try database.writer.write { db in
            try mutation.insert(db)
        }
        return mutation
    }

    /// Read the queue in FK-safe order — Placemark first, Sample last
    /// — and within each bucket by `created_at` ascending.
    func fetchAllOrdered() throws -> [PendingMutation] {
        try database.reader.read { db in
            try PendingMutation
                .order(Column("entity_type"), Column("created_at"))
                .fetchAll(db)
                .sorted { lhs, rhs in
                    let l = Self.dispatchOrder.firstIndex(of: lhs.entityType) ?? .max
                    let r = Self.dispatchOrder.firstIndex(of: rhs.entityType) ?? .max
                    if l != r { return l < r }
                    return lhs.createdAt < rhs.createdAt
                }
        }
    }

    /// Items for a single entity type, oldest first. Used by the
    /// SyncRunner pass that walks one bucket at a time.
    func fetch(entityType: PendingMutation.EntityType) throws -> [PendingMutation] {
        try database.reader.read { db in
            try PendingMutation
                .filter(Column("entity_type") == entityType.rawValue)
                .order(Column("created_at"))
                .fetchAll(db)
        }
    }

    /// Remove a mutation after the server confirms it. Called by the
    /// SyncRunner once a push returns 2xx.
    func dequeue(_ id: String) throws {
        _ = try database.writer.write { db in
            try PendingMutation.deleteOne(db, key: id)
        }
    }

    /// Increment `attempts`, stamp `last_attempt_at`, store the
    /// error string. Keeps the row in the queue for the next retry
    /// pass.
    func recordFailure(_ id: String, error: String) throws {
        try database.writer.write { db in
            try db.execute(
                sql: """
                UPDATE pending_mutations
                SET attempts = attempts + 1,
                    last_attempt_at = ?,
                    last_error = ?
                WHERE id = ?
                """,
                arguments: [Date(), error, id]
            )
        }
    }

    /// Replace the payload for a still-queued mutation. Used after a
    /// 409 pull-refresh — we keep the row alive but rewrite the body
    /// with the freshly-pulled `version` and any user-edits.
    func updatePayload(_ id: String, payload: Data, entityId: String?) throws {
        try database.writer.write { db in
            try db.execute(
                sql: """
                UPDATE pending_mutations
                SET payload_json = ?, entity_id = ?
                WHERE id = ?
                """,
                arguments: [payload, entityId, id]
            )
        }
    }

    func count() throws -> Int {
        try database.reader.read { db in
            try PendingMutation.fetchCount(db)
        }
    }

    /// Reset the queue on logout — different users must not share
    /// pending writes.
    func reset() throws {
        try database.writer.write { db in
            try db.execute(sql: "DELETE FROM pending_mutations")
        }
    }

    /// FK-safe order in which the SyncRunner replays buckets. Spec
    /// §4.2: Placemark before Locality (Locality references it),
    /// Locality before Fieldtrip (Fieldtrip references it), and so on.
    /// Determinations and SamplePhotos sit at the end because both
    /// reference a Sample.
    private static let dispatchOrder: [PendingMutation.EntityType] = [
        .placemark,
        .locality,
        .fieldtrip,
        .sample,
        .samplePhoto,
        .determination
    ]
}

import Foundation
import GRDB

/// CRUD for `local_photos`. Mirrors `LocalSampleStore` in shape but
/// stays smaller: photos don't need a sequence counter, just an index
/// that can survive an upload retry.
final class LocalPhotoStore {
    let database: Database

    init(database: Database) {
        self.database = database
    }

    func insert(_ photo: LocalPhoto) throws {
        try database.writer.write { db in
            var copy = photo
            try copy.insert(db)
        }
    }

    func update(_ photo: LocalPhoto) throws {
        try database.writer.write { db in
            try photo.update(db)
        }
    }

    func delete(id: String) throws {
        try database.writer.write { db in
            _ = try LocalPhoto.deleteOne(db, key: id)
        }
    }

    /// All photos newest-first. Backs the top-level Photos gallery.
    func fetchAll() throws -> [LocalPhoto] {
        try database.reader.read { db in
            try LocalPhoto
                .order(Column("created_at").desc)
                .fetchAll(db)
        }
    }

    func fetchBySample(_ sampleID: String) throws -> [LocalPhoto] {
        try database.reader.read { db in
            try LocalPhoto
                .filter(Column("sample_id") == sampleID)
                .order(Column("created_at"))
                .fetchAll(db)
        }
    }

    /// Photos that still need uploading (pending or failed).
    func fetchPending() throws -> [LocalPhoto] {
        try database.reader.read { db in
            try LocalPhoto
                .filter(Column("sync_status") == SyncStatus.pending.rawValue ||
                    Column("sync_status") == SyncStatus.failed.rawValue)
                .order(Column("created_at"))
                .fetchAll(db)
        }
    }

    func count() throws -> Int {
        try database.reader.read { db in
            try LocalPhoto.fetchCount(db)
        }
    }

    /// Wipes the index. Filesystem cleanup is the caller's responsibility
    /// (PhotoStorage.purgeAll); we don't reach into the FS from here so
    /// the unit-test path stays pure SQL.
    func reset() throws {
        try database.writer.write { db in
            try db.execute(sql: "DELETE FROM local_photos")
        }
    }
}

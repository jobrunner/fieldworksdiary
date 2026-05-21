import Foundation
import GRDB

final class LocalLocalityStore {
    let database: Database

    init(database: Database) {
        self.database = database
    }

    func upsert(_ remote: [Locality]) throws {
        try database.writer.write { db in
            for r in remote {
                var local = LocalLocality(from: r)
                try local.save(db)
            }
        }
    }

    func upsertOne(_ remote: Locality) throws {
        try database.writer.write { db in
            var local = LocalLocality(from: remote)
            try local.save(db)
        }
    }

    func fetchById(_ id: String) throws -> LocalLocality? {
        try database.reader.read { db in
            try LocalLocality.fetchOne(db, key: id)
        }
    }

    /// AsyncSequence over the full sorted list.
    func observeAll() -> AsyncValueObservation<[LocalLocality]> {
        AsyncValueObservation(observation: ValueObservation.tracking { db in
            try LocalLocality.order(Column("name")).fetchAll(db)
        }, reader: database.reader)
    }

    func count() throws -> Int {
        try database.reader.read { db in
            try LocalLocality.fetchCount(db)
        }
    }

    /// Empties the table. Called on logout/user switch.
    func reset() throws {
        try database.writer.write { db in
            try db.execute(sql: "DELETE FROM local_localities")
        }
    }
}

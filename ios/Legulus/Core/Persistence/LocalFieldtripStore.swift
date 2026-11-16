import Foundation
import GRDB

final class LocalFieldtripStore {
    let database: Database

    init(database: Database) {
        self.database = database
    }

    /// Upserts a batch of fieldtrips from the backend. Existing rows
    /// are overwritten — the server is the source of truth for these.
    func upsert(_ remote: [Fieldtrip]) throws {
        try database.writer.write { db in
            for r in remote {
                var local = LocalFieldtrip(from: r)
                try local.save(db)
            }
        }
    }

    func fetchById(_ id: String) throws -> LocalFieldtrip? {
        try database.reader.read { db in
            try LocalFieldtrip.fetchOne(db, key: id)
        }
    }

    /// Fieldtrip for a given collecting day ("YYYY-MM-DD"). Used on
    /// the home dashboard to surface "today's active fieldtrip".
    func fetchByCollectingDay(_ day: String) throws -> LocalFieldtrip? {
        try database.reader.read { db in
            try LocalFieldtrip
                .filter(Column("collecting_day") == day)
                .fetchOne(db)
        }
    }

    func count() throws -> Int {
        try database.reader.read { db in
            try LocalFieldtrip.fetchCount(db)
        }
    }

    /// AsyncSequence over the full sorted list. Yields a new array
    /// every time something changes in `local_fieldtrips`.
    func observeAll() -> AsyncValueObservation<[LocalFieldtrip]> {
        AsyncValueObservation(observation: ValueObservation.tracking { db in
            try LocalFieldtrip
                .order(Column("collecting_day").desc, Column("begin_date").desc)
                .fetchAll(db)
        }, reader: database.reader)
    }

    /// Empties the table. Called on logout/user switch — the next
    /// hydrate cycle will repopulate from the new user's data.
    func reset() throws {
        try database.writer.write { db in
            try db.execute(sql: "DELETE FROM local_fieldtrips")
        }
    }
}

import Foundation
import GRDB

final class LocalExcursionStore {
    let database: Database

    init(database: Database) {
        self.database = database
    }

    /// Upserts a batch of excursions from the backend. Existing rows
    /// are overwritten — the server is the source of truth for these.
    func upsert(_ remote: [Excursion]) throws {
        try database.writer.write { db in
            for r in remote {
                var local = LocalExcursion(from: r)
                try local.save(db)
            }
        }
    }

    func fetchById(_ id: String) throws -> LocalExcursion? {
        try database.reader.read { db in
            try LocalExcursion.fetchOne(db, key: id)
        }
    }

    /// Excursion for a given collecting day ("YYYY-MM-DD"). Used on
    /// the home dashboard to surface "today's active fieldtrip".
    func fetchByCollectingDay(_ day: String) throws -> LocalExcursion? {
        try database.reader.read { db in
            try LocalExcursion
                .filter(Column("collecting_day") == day)
                .fetchOne(db)
        }
    }

    func count() throws -> Int {
        try database.reader.read { db in
            try LocalExcursion.fetchCount(db)
        }
    }

    /// AsyncSequence over the full sorted list. Yields a new array
    /// every time something changes in `local_excursions`.
    func observeAll() -> AsyncValueObservation<[LocalExcursion]> {
        AsyncValueObservation(observation: ValueObservation.tracking { db in
            try LocalExcursion
                .order(Column("collecting_day").desc, Column("started_at").desc)
                .fetchAll(db)
        }, reader: database.reader)
    }

    /// Empties the table. Called on logout/user switch — the next
    /// hydrate cycle will repopulate from the new user's data.
    func reset() throws {
        try database.writer.write { db in
            try db.execute(sql: "DELETE FROM local_excursions")
        }
    }
}

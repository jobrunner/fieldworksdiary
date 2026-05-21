import Foundation
import GRDB

/// Single owner of the SQLite file. Created once at app launch via
/// the static factory; pass `Database.shared.writer` / `.reader` to
/// stores that need it.
final class Database {
    let writer: DatabaseWriter

    /// File-backed database for production use.
    convenience init() throws {
        let fm = FileManager.default
        let dir = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let path = dir.appendingPathComponent("fieldworksdiary.sqlite").path
        try self.init(path: path)
    }

    /// Explicit-path init — used by tests to point at an in-memory
    /// or temporary DB.
    init(path: String) throws {
        var config = Configuration()
        config.label = "Fieldworksdiary.\(path.split(separator: "/").last ?? "main")"
        let pool = try DatabasePool(path: path, configuration: config)
        try Database.runMigrations(pool)
        self.writer = pool
    }

    /// In-memory init for tests.
    init(inMemory _: Void = ()) throws {
        var config = Configuration()
        config.label = "Fieldworksdiary.memory"
        let queue = try DatabaseQueue(configuration: config)
        try Database.runMigrations(queue)
        self.writer = queue
    }

    var reader: DatabaseReader { writer }

    private static func runMigrations(_ writer: DatabaseWriter) throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_local_samples_and_sequences") { db in
            try db.create(table: "local_samples") { t in
                t.column("id", .text).primaryKey()
                t.column("backend_id", .text)
                t.column("code", .text).notNull()
                t.column("backend_code", .text)
                t.column("original_code", .text)
                t.column("user_id", .text).notNull()
                t.column("collecting_day", .text).notNull()
                t.column("lat", .double).notNull()
                t.column("lon", .double).notNull()
                t.column("accuracy_m", .double)
                t.column("altitude_m", .double)
                t.column("collected_from", .datetime).notNull()
                t.column("excursion", .text)
                t.column("admin_units_locality", .text)
                t.column("admin_units_country", .text)
                t.column("mtb_sheet_number", .text)
                t.column("mtb_sheet_name", .text)
                t.column("sync_status", .text).notNull()
                t.column("sync_error", .text)
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
            }
            try db.create(indexOn: "local_samples", columns: ["sync_status"])
            try db.create(indexOn: "local_samples", columns: ["collecting_day"])

            try db.create(table: "local_sequences") { t in
                t.column("user_id", .text).notNull()
                t.column("collecting_day", .text).notNull()
                t.column("last_seq", .integer).notNull()
                t.primaryKey(["user_id", "collecting_day"])
            }
        }

        migrator.registerMigration("v2_local_excursions") { db in
            try db.create(table: "local_excursions") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull().defaults(to: "")
                t.column("collecting_day", .text).notNull()
                t.column("night_excursion", .boolean).notNull().defaults(to: false)
                t.column("started_at", .datetime)
                t.column("ended_at", .datetime)
                t.column("centroid_lat", .double)
                t.column("centroid_lon", .double)
                // Encoded sub-objects kept as JSON so we can hydrate
                // them back through the same decoder the network path
                // uses, without re-modelling each nested field in SQL.
                t.column("admin_units_json", .text)
                t.column("mtb_json", .text)
                t.column("astro_json", .text)
                t.column("backend_updated_at", .datetime).notNull()
            }
            try db.create(indexOn: "local_excursions", columns: ["collecting_day"])
        }

        migrator.registerMigration("v3_local_localities") { db in
            try db.create(table: "local_localities") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull().defaults(to: "")
                t.column("centroid_lat", .double)
                t.column("centroid_lon", .double)
                t.column("radius_m", .double)
                t.column("notes", .text).notNull().defaults(to: "")
                t.column("backend_updated_at", .datetime).notNull()
            }
            try db.create(indexOn: "local_localities", columns: ["name"])
        }

        migrator.registerMigration("v4_excursions_locality_columns") { db in
            try db.alter(table: "local_excursions") { t in
                t.add(column: "locality", .text)
                t.add(column: "suggested_locality", .text)
            }
        }

        migrator.registerMigration("v5_excursions_filter_columns") { db in
            try db.alter(table: "local_excursions") { t in
                t.add(column: "day_of_year", .integer)
                t.add(column: "country", .text)
                t.add(column: "admin_area", .text)
            }
            try db.create(indexOn: "local_excursions", columns: ["day_of_year"])
            try db.create(indexOn: "local_excursions", columns: ["country"])
        }

        migrator.registerMigration("v6_excursions_permit_columns") { db in
            try db.alter(table: "local_excursions") { t in
                t.add(column: "permit_number", .text)
                t.add(column: "permit_pdf_file", .text)
            }
        }

        try migrator.migrate(writer)
    }
}

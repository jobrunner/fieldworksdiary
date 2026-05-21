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
        try Self.runMigrations(pool)
        writer = pool
    }

    /// In-memory init for tests — `LocalSampleStoreTests` und
    /// `SyncRunnerTests` greifen darauf zu, um ohne Filesystem-Setup
    /// gegen eine echte GRDB-DB zu testen.
    init(inMemory _: Void = ()) throws {
        var config = Configuration()
        config.label = "Fieldworksdiary.memory"
        let queue = try DatabaseQueue(configuration: config)
        try Self.runMigrations(queue)
        writer = queue
    }

    var reader: DatabaseReader {
        writer
    }

    private static func runMigrations(_ writer: DatabaseWriter) throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_local_samples_and_sequences", migrate: migrateV1)
        migrator.registerMigration("v2_local_excursions", migrate: migrateV2)
        migrator.registerMigration("v3_local_localities", migrate: migrateV3)
        migrator.registerMigration("v4_excursions_locality_columns", migrate: migrateV4)
        migrator.registerMigration("v5_excursions_filter_columns", migrate: migrateV5)
        migrator.registerMigration("v6_excursions_permit_columns", migrate: migrateV6)
        migrator.registerMigration("v7_local_photos_and_sample_notes", migrate: migrateV7)
        migrator.registerMigration("v8_local_samples_marked", migrate: migrateV8)
        try migrator.migrate(writer)
    }

    private static func migrateV1(_ db: GRDB.Database) throws {
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

    private static func migrateV2(_ db: GRDB.Database) throws {
        try db.create(table: "local_excursions") { t in
            t.column("id", .text).primaryKey()
            t.column("name", .text).notNull().defaults(to: "")
            t.column("collecting_day", .text).notNull()
            t.column("night_excursion", .boolean).notNull().defaults(to: false)
            t.column("started_at", .datetime)
            t.column("ended_at", .datetime)
            t.column("centroid_lat", .double)
            t.column("centroid_lon", .double)
            // Encoded sub-objects kept as JSON so we can hydrate them
            // back through the same decoder the network path uses,
            // without re-modelling each nested field in SQL.
            t.column("admin_units_json", .text)
            t.column("mtb_json", .text)
            t.column("astro_json", .text)
            t.column("backend_updated_at", .datetime).notNull()
        }
        try db.create(indexOn: "local_excursions", columns: ["collecting_day"])
    }

    private static func migrateV3(_ db: GRDB.Database) throws {
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

    private static func migrateV4(_ db: GRDB.Database) throws {
        try db.alter(table: "local_excursions") { t in
            t.add(column: "locality", .text)
            t.add(column: "suggested_locality", .text)
        }
    }

    private static func migrateV5(_ db: GRDB.Database) throws {
        try db.alter(table: "local_excursions") { t in
            t.add(column: "day_of_year", .integer)
            t.add(column: "country", .text)
            t.add(column: "admin_area", .text)
        }
        try db.create(indexOn: "local_excursions", columns: ["day_of_year"])
        try db.create(indexOn: "local_excursions", columns: ["country"])
    }

    private static func migrateV6(_ db: GRDB.Database) throws {
        try db.alter(table: "local_excursions") { t in
            t.add(column: "permit_number", .text)
            t.add(column: "permit_pdf_file", .text)
        }
    }

    // Phase 14: photos attached to samples, plus free-text notes on the
    // sample itself. Photos live in their own table so an upload can be
    // retried independently of the sample push.
    private static func migrateV7(_ db: GRDB.Database) throws {
        try db.alter(table: "local_samples") { t in
            t.add(column: "notes", .text).notNull().defaults(to: "")
        }

        try db.create(table: "local_photos") { t in
            t.column("id", .text).primaryKey()
            t.column("sample_id", .text).notNull()
            t.column("local_path", .text).notNull()
            t.column("backend_id", .text)
            t.column("sync_status", .text).notNull().defaults(to: "pending")
            t.column("sync_error", .text)
            t.column("client_uuid", .text).notNull()
            t.column("client_updated_at", .datetime).notNull()
            t.column("created_at", .datetime).notNull()
        }
        try db.create(indexOn: "local_photos", columns: ["sample_id"])
        try db.create(indexOn: "local_photos", columns: ["sync_status"])
    }

    // Phase 14b: user-facing star flag for samples. Defaults to false
    // for all existing rows.
    private static func migrateV8(_ db: GRDB.Database) throws {
        try db.alter(table: "local_samples") { t in
            t.add(column: "marked", .boolean).notNull().defaults(to: false)
        }
        try db.create(indexOn: "local_samples", columns: ["marked"])
    }
}

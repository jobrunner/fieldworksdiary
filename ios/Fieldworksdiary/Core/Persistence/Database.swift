import FieldworksGeo
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
        try makeMigrator().migrate(writer)
    }

    /// The full migration list. Internal (not private) so tests can
    /// migrate a raw queue up to an intermediate version, seed legacy
    /// rows, and then run the rest (`DatabaseMigrationV13Tests`).
    static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_local_samples_and_sequences", migrate: migrateV1)
        migrator.registerMigration("v2_local_excursions", migrate: migrateV2)
        migrator.registerMigration("v3_local_localities", migrate: migrateV3)
        migrator.registerMigration("v4_excursions_locality_columns", migrate: migrateV4)
        migrator.registerMigration("v5_excursions_filter_columns", migrate: migrateV5)
        migrator.registerMigration("v6_excursions_permit_columns", migrate: migrateV6)
        migrator.registerMigration("v7_local_photos_and_sample_notes", migrate: migrateV7)
        migrator.registerMigration("v8_local_samples_marked", migrate: migrateV8)
        migrator.registerMigration("v9_rename_excursions_to_fieldtrips", migrate: migrateV9)
        migrator.registerMigration("v10_spec_alignment_r3", migrate: migrateV10)
        migrator.registerMigration("v11_pending_mutations_outbox", migrate: migrateV11)
        migrator.registerMigration("v12_localities_needs_human_review", migrate: migrateV12)
        migrator.registerMigration("v13_ortus_location", migrate: migrateV13)
        return migrator
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

    /// Phase 14: photos attached to samples, plus free-text notes on the
    /// sample itself. Photos live in their own table so an upload can be
    /// retried independently of the sample push.
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

    /// Phase 14b: user-facing star flag for samples. Defaults to false
    /// for all existing rows.
    private static func migrateV8(_ db: GRDB.Database) throws {
        try db.alter(table: "local_samples") { t in
            t.add(column: "marked", .boolean).notNull().defaults(to: false)
        }
        try db.create(indexOn: "local_samples", columns: ["marked"])
    }

    /// Phase R2 (refactor): Excursion → Fieldtrip everywhere it shows
    /// up in code. SQLite keeps the data — we only rename the table
    /// and two columns. Historical migration names (`v2_local_excursions`,
    /// `v4_excursions_locality_columns`, …) stay as-is to preserve the
    /// schema-version log on existing devices.
    private static func migrateV9(_ db: GRDB.Database) throws {
        try db.rename(table: "local_excursions", to: "local_fieldtrips")
        try db.alter(table: "local_fieldtrips") { t in
            t.rename(column: "night_excursion", to: "night_fieldtrip")
        }
        try db.alter(table: "local_samples") { t in
            t.rename(column: "excursion", to: "fieldtrip")
        }
    }

    /// Phase R3 (refactor): Spec-Alignment. Same shape as the
    /// PocketBase migrations 1700000015–1700000018:
    ///
    /// 1. New `local_placemarks` table — cached parsed reverse-
    ///    geocoding results, deduplicated by content hash.
    /// 2. `local_samples` column renames + new sync-related cols.
    /// 3. `local_fieldtrips` column renames + notes/version.
    /// 4. `local_localities` gains explicit point-location columns
    ///    plus sync fields; the legacy `centroid_*` cols stay
    ///    readable until the data migration in R10.
    private static func migrateV10(_ db: GRDB.Database) throws {
        // 1. local_placemarks
        try db.create(table: "local_placemarks") { t in
            t.column("id", .text).primaryKey()
            t.column("country", .text).notNull()
            t.column("administrative_area", .text)
            t.column("sub_administrative_area", .text)
            t.column("locality", .text)
            t.column("sub_locality", .text)
            t.column("postal_code", .text)
            t.column("name", .text)
            t.column("thoroughfare", .text)
            t.column("geocoding_source", .text).notNull().defaults(to: "backend-service")
            t.column("geocoding_service_version", .text)
            t.column("geocoding_date", .datetime)
            t.column("dedup_hash", .text).notNull()
            t.column("backend_updated_at", .datetime).notNull()
        }
        try db.create(indexOn: "local_placemarks", columns: ["dedup_hash"], options: .unique)

        // 2. local_samples — rename existing columns and add new.
        try db.alter(table: "local_samples") { t in
            t.rename(column: "code", to: "sample_id")
            t.rename(column: "lat", to: "latitude")
            t.rename(column: "lon", to: "longitude")
            t.rename(column: "accuracy_m", to: "horizontal_accuracy")
            t.rename(column: "altitude_m", to: "altitude")
            t.rename(column: "collected_from", to: "begin_date")
            t.add(column: "end_date", .datetime)
            t.add(column: "is_all_day", .boolean).notNull().defaults(to: false)
            t.add(column: "time_zone", .text).notNull().defaults(to: "Europe/Berlin")
            t.add(column: "vertical_accuracy", .double)
            t.add(column: "location_source", .integer).notNull().defaults(to: 0)
            t.add(column: "locality", .text)
            t.add(column: "version", .integer).notNull().defaults(to: 1)
        }

        // 3. local_fieldtrips — name/started_at/ended_at renames,
        //    plus notes + version.
        try db.alter(table: "local_fieldtrips") { t in
            t.rename(column: "name", to: "title")
            t.rename(column: "started_at", to: "begin_date")
            t.rename(column: "ended_at", to: "end_date")
            t.add(column: "notes", .text).notNull().defaults(to: "")
            t.add(column: "version", .integer).notNull().defaults(to: 1)
        }

        // 4. local_localities — explicit coords + sync fields. Legacy
        //    centroid_* stays read-only for now.
        try db.alter(table: "local_localities") { t in
            t.add(column: "latitude", .double)
            t.add(column: "longitude", .double)
            t.add(column: "altitude", .double)
            t.add(column: "horizontal_accuracy", .double)
            t.add(column: "vertical_accuracy", .double)
            t.add(column: "location_source", .integer).notNull().defaults(to: 0)
            t.add(column: "location_number", .text)
            t.add(column: "placemark", .text)
            t.add(column: "version", .integer).notNull().defaults(to: 1)
            t.add(column: "client_uuid", .text)
            t.add(column: "client_updated_at", .datetime)
        }
        try db.execute(sql: """
            UPDATE local_localities
            SET latitude = centroid_lat,
                longitude = centroid_lon
            WHERE latitude IS NULL
        """)
        try db.create(indexOn: "local_localities", columns: ["latitude", "longitude"])
    }

    /// Phase R5.2: outbox table. Every locally-initiated write that
    /// needs to go up to the backend lands here first — replaces the
    /// implicit "sync state lives on the Local* row itself" pattern
    /// from Phase 1.
    ///
    /// The row carries enough to replay the request once the network
    /// returns: `entity_type` + `op` pick the client method,
    /// `payload_json` is the encoded body, `entity_id` is the backend
    /// id (nil for `create`). `attempts` / `last_attempt_at` /
    /// `last_error` drive the retry/backoff logic in the SyncRunner.
    ///
    /// `entity_type` is the singular collection noun ("sample",
    /// "fieldtrip", "locality", "sample_photo", "determination",
    /// "placemark"). The dispatch table in `SyncRunner` maps it back
    /// to the concrete PocketBase client.
    private static func migrateV11(_ db: GRDB.Database) throws {
        try db.create(table: "pending_mutations") { t in
            t.column("id", .text).primaryKey()
            t.column("entity_type", .text).notNull()
            t.column("entity_id", .text)
            t.column("op", .text).notNull()
            t.column("payload_json", .blob).notNull()
            t.column("created_at", .datetime).notNull()
            t.column("attempts", .integer).notNull().defaults(to: 0)
            t.column("last_attempt_at", .datetime)
            t.column("last_error", .text)
        }
        try db.create(
            indexOn: "pending_mutations",
            columns: ["entity_type", "created_at"]
        )
    }

    /// Phase R8c: surface the server-side fusion flag locally. The
    /// PocketBase migration 1700000019 added `needs_human_review` on
    /// localities (R6.1); this is the matching client column so the
    /// list can show a "möglicherweise doppelt" review section.
    /// Defaults to false for all existing rows.
    private static func migrateV12(_ db: GRDB.Database) throws {
        try db.alter(table: "local_localities") { t in
            t.add(column: "needs_human_review", .boolean).notNull().defaults(to: false)
        }
        try db.create(indexOn: "local_localities", columns: ["needs_human_review"])
    }

    /// Phase O2: Ortus location data. Mirrors the PocketBase
    /// migrations 1700000023–1700000025 so the sync mapping stays 1:1.
    ///
    /// 1. `local_samples`: `elevation` (copied from the legacy
    ///    `altitude`, which stays readable until O3), provenance +
    ///    status, placemark relations, MTB quadrant, DEM / terrain /
    ///    bearing columns.
    /// 2. `local_placemarks`: flat per-tier admin columns, owner,
    ///    backend id; `geocoding_source` renamed to `backend_service`;
    ///    the UNIQUE index on `dedup_hash` becomes a non-unique
    ///    composite (dedup_hash, geocoding_source) — dedup is
    ///    `LocalPlacemarkStore.lookupOrCreate`'s job, like on the
    ///    backend.
    /// 3. `local_sample_features`: Ortus source features per sample.
    private static func migrateV13(_ db: GRDB.Database) throws {
        // 1. local_samples
        try db.alter(table: "local_samples") { t in
            t.add(column: "elevation", .double)
            t.add(column: "elevation_source", .text)
            t.add(column: "location_status", .text).notNull().defaults(to: "pending")
            t.add(column: "placemark", .text)
            t.add(column: "placemark_suggestion", .text)
            t.add(column: "mtb_quadrant", .integer)
            t.add(column: "elevation_dem", .double)
            t.add(column: "elevation_dem_accuracy", .double)
            t.add(column: "slope_deg", .double)
            t.add(column: "aspect_deg", .double)
            t.add(column: "aspect_compass", .text)
            t.add(column: "terrain_flat", .boolean).notNull().defaults(to: false)
            t.add(column: "bearing_label", .text)
            t.add(column: "bearing_reference", .text)
            t.add(column: "bearing_distance_km", .double)
            t.add(column: "bearing_compass", .text)
            t.add(column: "bearing_inside", .boolean).notNull().defaults(to: false)
        }
        try db.execute(sql: "UPDATE local_samples SET elevation = altitude")
        try db.execute(sql: """
            UPDATE local_samples SET elevation_source = 'location_service'
            WHERE elevation IS NOT NULL AND elevation != 0
        """)
        try db.create(indexOn: "local_samples", columns: ["collecting_day", "placemark"])

        // 2. local_placemarks
        try db.alter(table: "local_placemarks") { t in
            t.add(column: "country_iso", .text)
            for tier in AdminTier.allCases {
                t.add(column: tier.rawValue, .text)
                t.add(column: "\(tier.rawValue)_level", .integer)
                t.add(column: "\(tier.rawValue)_native", .text)
            }
            t.add(column: "island", .text)
            t.add(column: "mountain_range", .text)
            t.add(column: "mountain", .text)
            t.add(column: "owner", .text)
            t.add(column: "backend_id", .text)
        }
        try db.execute(sql: """
            UPDATE local_placemarks SET geocoding_source = 'backend_service'
            WHERE geocoding_source = 'backend-service'
        """)
        // Every pre-v13 row was pulled from the server, so its id is
        // the backend id. Without this, `backendPlacemark` would treat
        // such a row as unresolvable and downgrade the sample's status.
        try db.execute(sql: "UPDATE local_placemarks SET backend_id = id WHERE backend_id IS NULL")
        try db.drop(indexOn: "local_placemarks", columns: ["dedup_hash"])
        try db.create(indexOn: "local_placemarks", columns: ["dedup_hash", "geocoding_source"])

        // 3. local_sample_features
        try db.create(table: "local_sample_features") { t in
            t.column("id", .text).primaryKey()
            t.column("sample_id", .text).notNull()
            t.column("source_id", .text).notNull()
            t.column("source_name", .text).notNull().defaults(to: "")
            t.column("layer", .text).notNull().defaults(to: "")
            t.column("feature_id", .text).notNull().defaults(to: "")
            t.column("properties_json", .text).notNull().defaults(to: "{}")
            t.column("license_json", .text)
            t.column("fetched_at", .datetime).notNull()
        }
        try db.create(indexOn: "local_sample_features", columns: ["sample_id", "source_id"])
    }
}

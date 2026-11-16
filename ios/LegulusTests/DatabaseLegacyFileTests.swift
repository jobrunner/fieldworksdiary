import GRDB
@testable import Legulus
import XCTest

/// Pins the takeover of the database file from before the rename:
/// rows written under the old file name are still there when the app
/// opens the current one.
final class DatabaseLegacyFileTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DatabaseLegacyFileTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func path(_ name: String) -> String {
        dir.appendingPathComponent(name).path
    }

    private func writeMarker(_ value: String, to name: String) throws {
        let queue = try DatabaseQueue(path: path(name))
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE marker (value TEXT NOT NULL)")
            try db.execute(sql: "INSERT INTO marker (value) VALUES (?)", arguments: [value])
        }
    }

    private func readMarker(from name: String) throws -> String? {
        let queue = try DatabaseQueue(path: path(name))
        return try queue.read { db in try String.fetchOne(db, sql: "SELECT value FROM marker") }
    }

    func testAdopt_MovesLegacyFileAndKeepsItsRows() throws {
        try writeMarker("legacy", to: Database.legacyFileName)

        Database.adoptLegacyFile(in: dir)

        XCTAssertFalse(FileManager.default.fileExists(atPath: path(Database.legacyFileName)))
        XCTAssertEqual(try readMarker(from: Database.fileName), "legacy")
    }

    func testAdopt_MovesWalSidecarWithUncheckpointedRows() throws {
        // A pool writes in WAL mode; the row lives in the -wal file
        // until a checkpoint. Copy the files while the pool is open,
        // as they would lie on disk after the app was killed.
        let source = dir.appendingPathComponent("source.sqlite").path
        let pool = try DatabasePool(path: source)
        try pool.write { db in
            try db.execute(sql: "CREATE TABLE marker (value TEXT NOT NULL)")
            try db.execute(sql: "INSERT INTO marker (value) VALUES ('wal')")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: source + "-wal"))
        for suffix in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: source + suffix) {
            try FileManager.default.copyItem(atPath: source + suffix, toPath: path(Database.legacyFileName) + suffix)
        }
        try pool.close()

        Database.adoptLegacyFile(in: dir)

        XCTAssertFalse(FileManager.default.fileExists(atPath: path(Database.legacyFileName) + "-wal"))
        XCTAssertEqual(try readMarker(from: Database.fileName), "wal")
    }

    func testAdopt_KeepsExistingCurrentFile() throws {
        try writeMarker("legacy", to: Database.legacyFileName)
        try writeMarker("current", to: Database.fileName)

        Database.adoptLegacyFile(in: dir)

        XCTAssertEqual(try readMarker(from: Database.fileName), "current")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path(Database.legacyFileName)))
    }

    func testAdopt_WithoutLegacyFileDoesNothing() {
        Database.adoptLegacyFile(in: dir)

        XCTAssertFalse(FileManager.default.fileExists(atPath: path(Database.fileName)))
    }
}

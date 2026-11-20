import GRDB
@testable import Legulus
import XCTest

/// Jedes Konto hat seine eigene lokale Datenbank. Die bisherige eine
/// Datenbank geht an das Konto, dessen Proben darin liegen.
final class AccountStorageTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = fm.temporaryDirectory.appendingPathComponent("account-storage-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
        try super.tearDownWithError()
    }

    private func legacyURL() -> URL {
        root.appendingPathComponent(Database.fileName)
    }

    /// A database at the old single location with samples of `owners`.
    private func makeLegacy(owners: [String]) throws {
        let database = try Database(path: legacyURL().path)
        try database.writer.write { db in
            for (index, owner) in owners.enumerated() {
                try db.execute(sql: """
                INSERT INTO local_samples
                  (id, sample_id, user_id, collecting_day, begin_date, sync_status, created_at, updated_at)
                VALUES (?, ?, ?, '2026-05-19', '2026-05-19 12:00:00.000', 'pending',
                        '2026-05-19 12:00:00.000', '2026-05-19 12:00:00.000')
                """, arguments: ["s\(index)", "260519/\(index)", owner])
            }
        }
    }

    private func sampleCount(at url: URL) throws -> Int {
        let database = try Database(path: url.path)
        return try database.reader.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM local_samples") ?? -1 }
    }

    func testDatabaseURL_IsPerAccount() {
        let a = AccountStorage.databaseURL(accountID: "usera0000000001", in: root)
        let b = AccountStorage.databaseURL(accountID: "userb0000000002", in: root)
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a.lastPathComponent, Database.fileName)
        XCTAssertEqual(a.deletingLastPathComponent().lastPathComponent, "usera0000000001")
        XCTAssertEqual(a.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent, "accounts")
    }

    /// An id is used as a directory name only when it is harmless.
    func testDirectoryName_NeverLeavesTheAccountsFolder() {
        XCTAssertEqual(AccountStorage.directoryName(for: "usera0000000001"), "usera0000000001")
        for hostile in ["../../etc", "a/b", "", ".", "..", "x y", "ü"] {
            let name = AccountStorage.directoryName(for: hostile)
            XCTAssertFalse(name.isEmpty, hostile)
            XCTAssertNil(
                name.rangeOfCharacter(from: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-")).inverted),
                "\(hostile) → \(name)"
            )
        }
        XCTAssertNotEqual(AccountStorage.directoryName(for: "a/b"), AccountStorage.directoryName(for: "a b"))
    }

    func testLegacyOwner_IsTheUserOfTheSamples() throws {
        try makeLegacy(owners: ["usera0000000001", "usera0000000001", "userb0000000002"])
        XCTAssertEqual(AccountStorage.legacyOwner(of: legacyURL()), "usera0000000001")
    }

    func testLegacyOwner_NilWithoutSamplesOrFile() throws {
        XCTAssertNil(AccountStorage.legacyOwner(of: legacyURL()))
        try makeLegacy(owners: [])
        XCTAssertNil(AccountStorage.legacyOwner(of: legacyURL()))
    }

    private func rows(_ table: String, at url: URL, where condition: String = "1") throws -> [String] {
        let database = try Database(path: url.path)
        return try database.reader.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM \(table) WHERE \(condition) ORDER BY id")
        }
    }

    private func urlOf(_ account: String) -> URL {
        AccountStorage.databaseURL(accountID: account, in: root)
    }

    /// The case that leaked data: the device holds samples of A, B
    /// signs in. The old database goes to A, B starts empty.
    func testAdoptLegacy_GoesToTheOwnerOfItsSamplesNotToTheUserSigningIn() throws {
        try makeLegacy(owners: ["usera0000000001", "usera0000000001"])
        AccountStorage.adoptLegacyDatabase(signedInAccountID: "userb0000000002", in: root)

        XCTAssertFalse(fm.fileExists(atPath: legacyURL().path), "die alte Datei ist umgezogen")
        XCTAssertEqual(try sampleCount(at: urlOf("usera0000000001")), 2)
        XCTAssertFalse(fm.fileExists(atPath: urlOf("userb0000000002").path))
    }

    /// The old database of a device two accounts used holds samples of
    /// both. Each account gets a database with its own samples only —
    /// nobody sees or uploads the other's.
    func testAdoptLegacy_SplitsADatabaseWithSamplesOfSeveralAccounts() throws {
        try makeLegacy(owners: ["usera0000000001", "usera0000000001", "userb0000000002"])
        // s0, s1 belong to A, s2 to B. Dependents and outbox of each.
        let legacy = try Database(path: legacyURL().path)
        try legacy.writer.write { db in
            for sample in ["s0", "s2"] {
                try db.execute(sql: """
                INSERT INTO local_photos (id, sample_id, local_path, sync_status, client_uuid, client_updated_at, created_at)
                VALUES (?, ?, 'photos/x.jpg', 'pending', ?, '2026-05-19 12:00:00.000', '2026-05-19 12:00:00.000')
                """, arguments: ["photo-\(sample)", sample, "photo-\(sample)"])
                try db.execute(sql: """
                INSERT INTO pending_mutations (id, entity_type, entity_id, op, payload_json, created_at, attempts)
                VALUES (?, 'sample', ?, 'create', x'', '2026-05-19 12:00:00.000', 0)
                """, arguments: ["m-\(sample)", sample])
            }
            // A delete of an already pushed photo: cannot be attributed,
            // stays with the main owner.
            try db.execute(sql: """
            INSERT INTO pending_mutations (id, entity_type, entity_id, op, payload_json, created_at, attempts)
            VALUES ('m-photo', 'sample_photo', 'pbphoto0000001', 'delete', x'7b7d', '2026-05-19 12:00:00.000', 0)
            """)
        }

        AccountStorage.adoptLegacyDatabase(signedInAccountID: "userb0000000002", in: root)

        let a = urlOf("usera0000000001"), b = urlOf("userb0000000002")
        XCTAssertEqual(try rows("local_samples", at: a), ["s0", "s1"])
        XCTAssertEqual(try rows("local_samples", at: b), ["s2"])
        XCTAssertEqual(try rows("local_photos", at: a), ["photo-s0"])
        XCTAssertEqual(try rows("local_photos", at: b), ["photo-s2"])
        XCTAssertEqual(try rows("pending_mutations", at: a), ["m-photo", "m-s0"])
        XCTAssertEqual(try rows("pending_mutations", at: b), ["m-s2"], "B bekommt nur die eigene Outbox")
        XCTAssertFalse(fm.fileExists(atPath: legacyURL().path))
    }

    /// Cached rows of the main owner (fieldtrips, localities) must not
    /// show up for the other account.
    func testAdoptLegacy_OtherAccountsGetNoCachedRowsOfTheMainOwner() throws {
        try makeLegacy(owners: ["usera0000000001", "usera0000000001", "userb0000000002"])
        let legacy = try Database(path: legacyURL().path)
        let table = try legacy.reader.read { db in
            try db.tableExists("local_fieldtrips") ? "local_fieldtrips" : "local_excursions"
        }
        let before = try legacy.writer.write { db -> Int in
            // One row with a placeholder in every column that needs a value.
            let required = try db.columns(in: table).filter { $0.isNotNull && $0.defaultValueSQL == nil }.map(\.name)
            let placeholders = required.map { _ in "'x'" }.joined(separator: ", ")
            try db.execute(sql: "INSERT INTO \(table) (\(required.joined(separator: ", "))) VALUES (\(placeholders))")
            return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
        }
        XCTAssertEqual(before, 1, "Vorbedingung")
        AccountStorage.adoptLegacyDatabase(signedInAccountID: nil, in: root)
        func count(_ url: URL) throws -> Int {
            try Database(path: url.path).reader.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? -1 }
        }
        XCTAssertEqual(try count(urlOf("usera0000000001")), 1)
        XCTAssertEqual(try count(urlOf("userb0000000002")), 0)
    }

    /// Committed rows that still sit in the WAL file move along.
    func testAdoptLegacy_TakesRowsStillInTheWriteAheadLog() throws {
        let legacy = try Database(path: legacyURL().path)
        try legacy.writer.write { db in
            try db.execute(sql: """
            INSERT INTO local_samples
              (id, sample_id, user_id, collecting_day, begin_date, sync_status, created_at, updated_at)
            VALUES ('wal1', '260519/9', 'usera0000000001', '2026-05-19', '2026-05-19 12:00:00.000', 'pending',
                    '2026-05-19 12:00:00.000', '2026-05-19 12:00:00.000')
            """)
        }
        // `legacy` stays open: nothing has been checkpointed.
        XCTAssertTrue(fm.fileExists(atPath: legacyURL().path + "-wal"), "Vorbedingung: WAL vorhanden")
        AccountStorage.adoptLegacyDatabase(signedInAccountID: nil, in: root)
        XCTAssertEqual(try rows("local_samples", at: urlOf("usera0000000001")), ["wal1"])
        _ = legacy
    }

    /// A leftover of an interrupted run is not mistaken for a database.
    func testAdoptLegacy_IgnoresAStagingLeftover() throws {
        try makeLegacy(owners: ["usera0000000001"])
        let target = urlOf("usera0000000001")
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("kaputt".utf8).write(to: URL(fileURLWithPath: target.path + AccountStorage.stagingSuffix))
        AccountStorage.adoptLegacyDatabase(signedInAccountID: nil, in: root)
        XCTAssertEqual(try rows("local_samples", at: target), ["s0"])
        XCTAssertFalse(fm.fileExists(atPath: target.path + AccountStorage.stagingSuffix))
    }

    /// A database without samples is a cache: it goes to whoever is
    /// signed in, as before.
    func testAdoptLegacy_WithoutSamplesGoesToTheSignedInUser() throws {
        try makeLegacy(owners: [])
        AccountStorage.adoptLegacyDatabase(signedInAccountID: "userb0000000002", in: root)
        XCTAssertFalse(fm.fileExists(atPath: legacyURL().path))
        XCTAssertTrue(fm.fileExists(atPath: AccountStorage.databaseURL(accountID: "userb0000000002", in: root).path))
    }

    /// Signed out and nothing in it to tell the owner: left where it
    /// is, for the next start.
    func testAdoptLegacy_UnknownOwnerAndSignedOutStays() throws {
        try makeLegacy(owners: [])
        AccountStorage.adoptLegacyDatabase(signedInAccountID: nil, in: root)
        XCTAssertTrue(fm.fileExists(atPath: legacyURL().path))
    }

    func testAdoptLegacy_SignedOutButOwnerKnownMoves() throws {
        try makeLegacy(owners: ["usera0000000001"])
        AccountStorage.adoptLegacyDatabase(signedInAccountID: nil, in: root)
        XCTAssertEqual(try sampleCount(at: AccountStorage.databaseURL(accountID: "usera0000000001", in: root)), 1)
    }

    /// Never overwrite an account's database with the legacy one.
    func testAdoptLegacy_KeepsAnExistingAccountDatabase() throws {
        let target = AccountStorage.databaseURL(accountID: "usera0000000001", in: root)
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = try Database(path: target.path)
        try makeLegacy(owners: ["usera0000000001"])

        AccountStorage.adoptLegacyDatabase(signedInAccountID: "usera0000000001", in: root)

        XCTAssertEqual(try sampleCount(at: target), 0, "die vorhandene Datenbank des Kontos bleibt")
        XCTAssertTrue(fm.fileExists(atPath: legacyURL().path), "die alte Datei bleibt liegen, nichts geht verloren")
    }

    func testAdoptLegacy_NoLegacyFileIsANoOp() {
        AccountStorage.adoptLegacyDatabase(signedInAccountID: "usera0000000001", in: root)
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("accounts").path))
    }
}

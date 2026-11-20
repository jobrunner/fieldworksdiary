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

    /// The case that leaked data: the device holds samples of A, B
    /// signs in. The old database goes to A, B starts empty.
    func testAdoptLegacy_GoesToTheOwnerOfItsSamplesNotToTheUserSigningIn() throws {
        try makeLegacy(owners: ["usera0000000001", "usera0000000001"])
        AccountStorage.adoptLegacyDatabase(signedInAccountID: "userb0000000002", in: root)

        XCTAssertFalse(fm.fileExists(atPath: legacyURL().path), "die alte Datei ist umgezogen")
        XCTAssertEqual(try sampleCount(at: AccountStorage.databaseURL(accountID: "usera0000000001", in: root)), 2)
        XCTAssertFalse(fm.fileExists(atPath: AccountStorage.databaseURL(accountID: "userb0000000002", in: root).path))
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

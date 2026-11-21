import CryptoKit
import Foundation
import GRDB

/// Where the local data of an account lives. Every account has its own
/// database under `Application Support/accounts/<id>/`, so the data of
/// two accounts on one device can never mix: signing out deletes
/// nothing, signing in as someone else opens another database.
enum AccountStorage {
    static let accountsFolder = "accounts"

    /// The folder name for an account id. PocketBase ids are 15
    /// alphanumeric characters and are used as they are; anything else
    /// is replaced by a hash, so an id can never point outside the
    /// accounts folder.
    static func directoryName(for accountID: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        if !accountID.isEmpty, accountID.unicodeScalars.allSatisfy(allowed.contains) {
            return accountID
        }
        let digest = SHA256.hash(data: Data(accountID.utf8))
        return "h-" + digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    static func databaseURL(accountID: String, in appSupport: URL) -> URL {
        appSupport
            .appendingPathComponent(accountsFolder, isDirectory: true)
            .appendingPathComponent(directoryName(for: accountID), isDirectory: true)
            .appendingPathComponent(Database.fileName)
    }

    /// Suffix of a database copy that is still being prepared.
    static let stagingSuffix = ".staging"

    /// The accounts whose samples the single database of earlier app
    /// versions holds, the one with the most samples first. Empty when
    /// the file is missing or holds no attributable samples.
    static func legacyOwners(of legacyDatabase: URL) -> [String] {
        guard FileManager.default.fileExists(atPath: legacyDatabase.path),
              let queue = try? DatabaseQueue(path: legacyDatabase.path)
        else { return [] }
        return (try? queue.read { db in
            guard try db.tableExists("local_samples") else { return [] }
            return try String.fetchAll(db, sql: """
            SELECT user_id FROM local_samples
            WHERE user_id IS NOT NULL AND user_id != '' AND user_id != 'default'
            GROUP BY user_id ORDER BY COUNT(*) DESC, user_id
            """)
        }) ?? []
    }

    /// True while the legacy database still holds samples of this account
    /// that have not been handed over (the copy failed, e.g. for lack of
    /// space). Opening a fresh database for the account then would hide
    /// them for good: the new file blocks every later attempt.
    static func legacyDataPending(for accountID: String, in appSupport: URL, fileManager fm: FileManager = .default) -> Bool {
        let legacy = appSupport.appendingPathComponent(Database.fileName)
        guard legacyOwners(of: legacy).contains(accountID) else { return false }
        return !fm.fileExists(atPath: databaseURL(accountID: accountID, in: appSupport).path)
    }

    /// The main owner of the legacy database, see `legacyOwners`.
    static func legacyOwner(of legacyDatabase: URL) -> String? {
        legacyOwners(of: legacyDatabase).first
    }

    /// Hands the single database of earlier app versions over to the
    /// accounts it belongs to.
    ///
    /// Every account with samples in it gets its own copy, reduced to
    /// its own samples, their photos, features and outbox entries. A
    /// device two accounts used can hold samples of both; nobody may see
    /// or upload the other's. The account with the most samples is the
    /// main owner and also keeps what cannot be attributed (samples
    /// without a user, cached fieldtrips and localities, other outbox
    /// entries). Without any samples the file is a cache and goes to the
    /// signed-in account; without that it stays for the next start.
    ///
    /// Each copy is made with SQLite's backup (it includes what still
    /// sits in the write-ahead log), prepared under a staging name and
    /// published with one rename. The legacy file is removed only when
    /// every owner has a database; an account that already had one keeps
    /// it, and the legacy file then stays untouched.
    static func adoptLegacyDatabase(signedInAccountID: String?, in appSupport: URL, fileManager fm: FileManager = .default) {
        let legacy = appSupport.appendingPathComponent(Database.fileName)
        guard fm.fileExists(atPath: legacy.path) else { return }
        var owners = legacyOwners(of: legacy)
        let mainOwner = owners.first
        if owners.isEmpty, let signedInAccountID {
            owners = [signedInAccountID]
        }
        guard !owners.isEmpty else { return }

        var everyOwnerServed = true
        for owner in owners {
            let target = databaseURL(accountID: owner, in: appSupport)
            if fm.fileExists(atPath: target.path) {
                // Never replace an account's database; keep the legacy
                // file so nothing in it is lost.
                Log.persistence.notice("legacy database kept: an account already has one")
                everyOwnerServed = false
                continue
            }
            do {
                try publishCopy(
                    of: legacy,
                    to: target,
                    keeping: owner,
                    isMainOwner: owner == mainOwner || mainOwner == nil,
                    fileManager: fm
                )
            } catch {
                Log.persistence.error("handing over the legacy database failed: \(error.localizedDescription)")
                everyOwnerServed = false
            }
        }
        guard everyOwnerServed else { return }
        for suffix in ["-wal", "-shm", ""] {
            try? fm.removeItem(at: URL(fileURLWithPath: legacy.path + suffix))
        }
        Log.persistence.notice("legacy database handed over to \(owners.count, privacy: .public) account(s)")
    }

    /// Backs `legacy` up into a staging file next to `target`, reduces
    /// it to the data of `owner` and renames it into place.
    private static func publishCopy(
        of legacy: URL, to target: URL, keeping owner: String, isMainOwner: Bool, fileManager fm: FileManager
    ) throws {
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staging = URL(fileURLWithPath: target.path + stagingSuffix)
        for suffix in ["", "-wal", "-shm", "-journal"] {
            try? fm.removeItem(at: URL(fileURLWithPath: staging.path + suffix))
        }
        do {
            // A plain rollback-journal file: nothing but the one file to
            // rename afterwards.
            let source = try DatabaseQueue(path: legacy.path)
            let copy = try DatabaseQueue(path: staging.path)
            try source.backup(to: copy)
            try copy.writeWithoutTransaction { db in
                try db.execute(sql: "PRAGMA journal_mode = DELETE")
            }
            try copy.write { db in try prune(db, keeping: owner, isMainOwner: isMainOwner) }
            try copy.close()
            try source.close()
        }
        try fm.moveItem(at: staging, to: target)
    }

    /// Removes from a copy of the legacy database what does not belong
    /// to `owner`.
    private static func prune(_ db: GRDB.Database, keeping owner: String, isMainOwner: Bool) throws {
        guard try db.tableExists("local_samples") else { return }
        // The main owner keeps samples nobody is named for; the others
        // keep strictly their own.
        let foreign = isMainOwner
            ? "user_id IS NOT NULL AND user_id != '' AND user_id != 'default' AND user_id != ?"
            : "user_id IS NULL OR user_id != ?"
        let foreignIDs = "SELECT id FROM local_samples WHERE \(foreign)"
        for table in ["local_photos", "local_sample_features"] where try db.tableExists(table) {
            try db.execute(sql: "DELETE FROM \(table) WHERE sample_id IN (\(foreignIDs))", arguments: [owner])
        }
        if try db.tableExists("pending_mutations") {
            // Creates and updates of a sample carry its local id.
            try db.execute(sql: """
            DELETE FROM pending_mutations
            WHERE entity_type = 'sample' AND op IN ('create', 'update') AND entity_id IN (\(foreignIDs))
            """, arguments: [owner])
            if !isMainOwner {
                // Everything else in the outbox (deletes by backend id,
                // localities, photos) cannot be attributed and stays with
                // the main owner.
                try db.execute(sql: """
                DELETE FROM pending_mutations
                WHERE NOT (entity_type = 'sample' AND op IN ('create', 'update'))
                """)
            }
        }
        try db.execute(sql: "DELETE FROM local_samples WHERE \(foreign)", arguments: [owner])
        if try db.tableExists("local_placemarks"),
           try db.columns(in: "local_placemarks").contains(where: { $0.name == "owner" })
        {
            // Places entered by hand are private to their owner; the
            // shared ones (backend_service) stay in every copy. A manual
            // place without owner stays with the main owner, and with
            // any account whose remaining samples still point at it.
            let ownerless = isMainOwner ? "" : """
             OR ((owner IS NULL OR owner = '')
                 AND id NOT IN (SELECT placemark FROM local_samples WHERE placemark IS NOT NULL))
            """
            try db.execute(sql: """
            DELETE FROM local_placemarks
            WHERE geocoding_source = 'manual'
              AND ((owner IS NOT NULL AND owner != '' AND owner != ?)\(ownerless))
            """, arguments: [owner])
        }
        if !isMainOwner {
            // Cached server rows of the main owner; this account pulls
            // its own on first sync.
            for table in ["local_fieldtrips", "local_excursions", "local_localities"] where try db.tableExists(table) {
                try db.execute(sql: "DELETE FROM \(table)")
            }
        }
    }
}

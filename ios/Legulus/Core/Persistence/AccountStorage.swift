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

    /// The account the single database of earlier app versions belongs
    /// to: the user most of its samples were created by. Nil when the
    /// file is missing or holds no samples.
    static func legacyOwner(of legacyDatabase: URL) -> String? {
        guard FileManager.default.fileExists(atPath: legacyDatabase.path) else { return nil }
        var configuration = Configuration()
        configuration.readonly = true
        guard let queue = try? DatabaseQueue(path: legacyDatabase.path, configuration: configuration) else { return nil }
        return try? queue.read { db in
            guard try db.tableExists("local_samples") else { return nil }
            return try String.fetchOne(db, sql: """
            SELECT user_id FROM local_samples
            WHERE user_id IS NOT NULL AND user_id != '' AND user_id != 'default'
            GROUP BY user_id ORDER BY COUNT(*) DESC, user_id LIMIT 1
            """)
        }
    }

    /// Moves the single database of earlier app versions into the folder
    /// of the account it belongs to: the owner of its samples, or — when
    /// it holds none and is just a cache — the signed-in account. With
    /// neither it stays where it is. An account that already has a
    /// database keeps it; the legacy file is then left untouched.
    static func adoptLegacyDatabase(signedInAccountID: String?, in appSupport: URL, fileManager fm: FileManager = .default) {
        let legacy = appSupport.appendingPathComponent(Database.fileName)
        guard fm.fileExists(atPath: legacy.path), let owner = legacyOwner(of: legacy) ?? signedInAccountID else { return }
        let target = databaseURL(accountID: owner, in: appSupport)
        guard !fm.fileExists(atPath: target.path) else {
            Log.persistence.notice("legacy database kept: its account already has one")
            return
        }
        do {
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Sidecars first, the main file last: an interrupted move is
            // repeated on the next launch.
            for suffix in ["-wal", "-shm", ""] {
                let source = URL(fileURLWithPath: legacy.path + suffix)
                guard fm.fileExists(atPath: source.path) else { continue }
                try fm.moveItem(at: source, to: URL(fileURLWithPath: target.path + suffix))
            }
            Log.persistence.notice("legacy database moved to its account")
        } catch {
            Log.persistence.error("moving the legacy database failed: \(error.localizedDescription)")
        }
    }
}

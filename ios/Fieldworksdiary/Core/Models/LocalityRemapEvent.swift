import Foundation

/// Server-emitted event that a Locality merged into another one
/// (Spec §5.3). The client polls `/api/collections/locality_remap_events/records`
/// and applies each event idempotently: update `local_samples` to
/// point at `newLocalityID`, drop the old locality row, and surface
/// a UI notification.
struct LocalityRemapEvent: Decodable, Identifiable, Equatable {
    let id: String
    let owner: String
    let oldLocalityID: String
    let newLocalityID: String
    let reason: Reason
    let affectedSampleIds: [String]
    /// PocketBase auto-`created` timestamp. Used as the polling
    /// cursor — the next pull asks for `created > {lastSeen}`.
    let created: Date

    /// Why the merge happened. The UI may surface different copy
    /// per reason, but the apply-logic is identical.
    enum Reason: String, Decodable, Equatable {
        case mergedWithExisting = "merged_with_existing"
        case duplicateCleanup = "duplicate_cleanup"

        init(wire: String?) {
            switch wire {
            case "duplicate_cleanup": self = .duplicateCleanup
            default: self = .mergedWithExisting
            }
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, owner, reason, created
        case oldLocalityID = "old_locality_id"
        case newLocalityID = "new_locality_id"
        case affectedSampleIds = "affected_sample_ids"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        owner = try c.decode(String.self, forKey: .owner)
        oldLocalityID = try c.decode(String.self, forKey: .oldLocalityID)
        newLocalityID = try c.decode(String.self, forKey: .newLocalityID)
        reason = Reason(wire: try? c.decode(String.self, forKey: .reason))
        created = (try? c.decode(Date.self, forKey: .created)) ?? Date()
        // PocketBase JSON fields ship as opaque strings; the
        // backend writes a JSON array. Decode it lazily so a
        // malformed body doesn't kill the entire event stream.
        if let raw = try? c.decode(String.self, forKey: .affectedSampleIds),
           let data = raw.data(using: .utf8),
           let parsed = try? JSONDecoder().decode([String].self, from: data)
        {
            affectedSampleIds = parsed
        } else if let direct = try? c.decode([String].self, forKey: .affectedSampleIds) {
            // Belt-and-braces: tolerate a backend tweak that one
            // day stops wrapping the array as a string.
            affectedSampleIds = direct
        } else {
            affectedSampleIds = []
        }
    }
}

struct LocalityRemapEventListResponse: Decodable {
    let items: [LocalityRemapEvent]
}

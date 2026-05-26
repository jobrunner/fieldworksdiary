import Foundation

/// Provenance of a coordinate. Drives whether downstream code may
/// overwrite it: a `.user`-entered coordinate sticks even when a
/// later GPS fix arrives; a `.locationService` coordinate may be
/// refined; a `.sample`/`.locality` value was derived from another
/// record and gets recomputed when its source changes.
///
/// Wire format is a PocketBase select-string; locally we keep the
/// raw enum so switches stay exhaustive. The raw `Int` is what
/// GRDB persists.
enum LocationSource: Int, Codable, Equatable, CaseIterable {
    case user = 0
    case locationService = 1
    case sample = 2
    case locality = 3

    /// PocketBase select-field encoding. Matches the schema-level
    /// `Values: []string{"user", "location_service", "sample",
    /// "locality"}`.
    var wireValue: String {
        switch self {
        case .user: "user"
        case .locationService: "location_service"
        case .sample: "sample"
        case .locality: "locality"
        }
    }

    /// Inverse of `wireValue`. Falls back to `.user` for unknown
    /// or absent values — the safest default for a legacy row that
    /// predates the source concept entirely.
    init(wire: String?) {
        switch wire {
        case "location_service": self = .locationService
        case "sample": self = .sample
        case "locality": self = .locality
        default: self = .user
        }
    }
}

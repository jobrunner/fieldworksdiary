import Foundation

/// Label for a place field: country-specific term (if known) plus the
/// generic localization key used as fallback.
public struct PlaceFieldLabel: Equatable, Sendable {
    public var term: String?
    public var genericKey: String
}

public enum PlaceLabels {
    /// Fallback chain: table term for (country, level), then `rawLocalTerm`,
    /// then `term == nil` (generic key only).
    public static func label(country: String?, tier: AdminTier, level: Int?, rawLocalTerm: String?,
                             table: AdminLabelTable = .shared) -> PlaceFieldLabel {
        var term: String?
        if let country, let level { term = table.term(country: country, level: level) }
        if term == nil, let raw = rawLocalTerm?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            term = raw
        }
        return PlaceFieldLabel(term: term, genericKey: genericKey(for: tier))
    }

    public static func genericKey(for tier: AdminTier) -> String {
        "admin." + String(tier.rawValue.dropFirst("admin_".count))
    }

    public static let islandKey = "place.island"
    public static let mountainRangeKey = "place.mountain_range"
    public static let mountainKey = "place.mountain"
}

import Foundation

/// Name of a flat admin column on a locality or sample.
public enum AdminTier: String, CaseIterable, Codable, Sendable {
    case country = "admin_country"
    case state = "admin_state"
    case region = "admin_region"
    case province = "admin_province"
    case county = "admin_county"
    case district = "admin_district"
    case municipality = "admin_municipality"
    case borough = "admin_borough"
    case parish = "admin_parish"
    case submunicipality = "admin_submunicipality"
    case other = "admin_other"
}

/// Maps (country ISO, OSM admin level) to a flat `admin_*` column and a
/// country-specific term. Mirrors the Go package `adminlabels`; the canonical
/// JSON lives in `shared/admin-labels/` and is copied here by
/// `scripts/sync-admin-labels.sh`.
public struct AdminLabelTable: Sendable {
    private struct LevelEntry: Decodable, Sendable {
        let column: String?
        let term: String
    }

    private struct CountryEntry: Decodable, Sendable {
        let name: String
        let levels: [String: LevelEntry]
    }

    private struct Root: Decodable, Sendable {
        let countries: [String: CountryEntry]
    }

    private let countryTable: [String: CountryEntry]

    /// Table loaded from the bundled resource. Empty if the resource is
    /// missing or broken (callers then see every pair as unknown).
    public static let shared: AdminLabelTable = {
        guard let url = Bundle.module.url(forResource: "admin_labels", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let root = try? JSONDecoder().decode(Root.self, from: data)
        else { return AdminLabelTable(countryTable: [:]) }
        return AdminLabelTable(countryTable: root.countries)
    }()

    private init(countryTable: [String: CountryEntry]) {
        self.countryTable = countryTable
    }

    private func entry(_ country: String, _ level: Int) -> LevelEntry? {
        countryTable[country]?.levels[String(level)]
    }

    /// Column for (country, level). `known == false`: the pair is unknown.
    /// `known == true` with `tier == nil`: known but not stored.
    public func column(country: String, level: Int) -> (tier: AdminTier?, known: Bool) {
        guard let e = entry(country, level) else { return (nil, false) }
        return (e.column.flatMap(AdminTier.init(rawValue:)), true)
    }

    /// Country-specific term, or nil if unknown.
    public func term(country: String, level: Int) -> String? {
        entry(country, level)?.term
    }

    /// Stored levels of a country, sorted by level.
    public func levels(country: String) -> [(level: Int, tier: AdminTier, term: String)] {
        guard let c = countryTable[country] else { return [] }
        return c.levels.compactMap { key, e in
            guard let level = Int(key), let col = e.column, let tier = AdminTier(rawValue: col)
            else { return nil }
            return (level: level, tier: tier, term: e.term)
        }.sorted { $0.level < $1.level }
    }

    /// All countries, sorted by ISO code.
    public var countries: [(iso: String, name: String)] {
        countryTable.map { (iso: $0.key, name: $0.value.name) }.sorted { $0.iso < $1.iso }
    }
}

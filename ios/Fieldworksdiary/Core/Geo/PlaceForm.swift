import FieldworksGeo
import Foundation

/// Editable state of a place (country + per-field text) shared by the
/// sample place editor and the locality override sheet.
///
/// The country is chosen first; only that country's stored levels
/// (`AdminLabelTable.levels(country:)`) plus island / mountain range /
/// mountain are offered. Values of levels the chosen country doesn't
/// have stay in `values` (so switching back restores them) but are not
/// part of `place()`.
struct PlaceForm: Equatable {
    struct Field: Identifiable, Equatable {
        /// `admin_<tier>` or one of the landscape ids below.
        let id: String
        let tier: AdminTier?
        let level: Int?
        /// Country-specific term, nil for landscape fields.
        let term: String?
        let genericLabel: String

        var displayTerm: String {
            term ?? genericLabel
        }
    }

    static let islandID = "island"
    static let mountainRangeID = "mountain_range"
    static let mountainID = "mountain"

    /// ISO 3166-1 alpha-2, empty until chosen.
    private(set) var countryISO: String
    var values: [String: String]
    /// The place the form was opened with (natives are kept from it).
    let original: Place?

    init(place: Place?) {
        original = place
        countryISO = place?.countryISO ?? ""
        var values: [String: String] = [:]
        if let place {
            for (tier, value) in place.admin {
                values[tier.rawValue] = value.name.isEmpty ? value.native : value.name
            }
            values[Self.islandID] = place.island
            values[Self.mountainRangeID] = place.mountainRange
            values[Self.mountainID] = place.mountain
        }
        self.values = values
    }

    /// Switches the country. The country tier is prefilled with the
    /// German country name unless the user typed something else.
    mutating func selectCountry(_ iso: String, table: AdminLabelTable = .shared) {
        let previous = countryISO
        countryISO = iso
        let key = AdminTier.country.rawValue
        let current = values[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let previousDefault = previous.isEmpty ? "" : PlaceDisplay.countryName(previous, table: table)
        let originalCountry = original?.admin[.country]?.name ?? ""
        if current.isEmpty || current == previousDefault || (iso != previous && current == originalCountry) {
            values[key] = iso.isEmpty ? "" : PlaceDisplay.countryName(iso, table: table)
        }
    }

    /// Fields for the chosen country, in level order, then landscape.
    func fields(table: AdminLabelTable = .shared) -> [Field] {
        guard !countryISO.isEmpty else { return [] }
        let admin = table.levels(country: countryISO).map { entry in
            Field(id: entry.tier.rawValue, tier: entry.tier, level: entry.level, term: entry.term,
                  genericLabel: PlaceDisplay.genericLabel(PlaceLabels.genericKey(for: entry.tier)))
        }
        let landscape = [
            Field(id: Self.islandID, tier: nil, level: nil, term: nil,
                  genericLabel: PlaceDisplay.genericLabel(PlaceLabels.islandKey)),
            Field(id: Self.mountainRangeID, tier: nil, level: nil, term: nil,
                  genericLabel: PlaceDisplay.genericLabel(PlaceLabels.mountainRangeKey)),
            Field(id: Self.mountainID, tier: nil, level: nil, term: nil,
                  genericLabel: PlaceDisplay.genericLabel(PlaceLabels.mountainKey))
        ]
        return admin + landscape
    }

    /// The place described by the visible fields; nil without country.
    func place(table: AdminLabelTable = .shared) -> Place? {
        guard countryISO.count == 2 else { return nil }
        var admin: [AdminTier: AdminValue] = [:]
        for field in fields(table: table) {
            guard let tier = field.tier, let level = field.level else { continue }
            let name = trimmed(field.id)
            guard !name.isEmpty else { continue }
            var native = ""
            if let original, original.countryISO == countryISO, let old = original.admin[tier],
               old.name == name || (old.name.isEmpty && old.native == name)
            {
                native = old.native
            }
            admin[tier] = AdminValue(name: name, native: native, level: level)
        }
        return Place(countryISO: countryISO, admin: admin, island: trimmed(Self.islandID),
                     mountainRange: trimmed(Self.mountainRangeID), mountain: trimmed(Self.mountainID))
    }

    /// True when `place()` differs from the place the form opened with.
    func isChanged(table: AdminLabelTable = .shared) -> Bool {
        guard let place = place(table: table) else { return false }
        guard let original else { return true }
        return place.dedupHash != original.dedupHash
    }

    private func trimmed(_ id: String) -> String {
        values[id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

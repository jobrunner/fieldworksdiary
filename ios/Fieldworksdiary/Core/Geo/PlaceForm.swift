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
    /// Field values the form was opened with; "changed" is decided
    /// against these, not via the dedup hash (a place may carry tiers
    /// the label table doesn't list, which the form can't show).
    private let initialValues: [String: String]

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
        initialValues = values
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
    ///
    /// With the country unchanged, tiers of the original place that the
    /// form doesn't show (levels outside the label table, `admin_other`
    /// with an Ortus level, countries the table doesn't know) are kept
    /// as they are, and an untouched field keeps its original value
    /// (name, native and level).
    func place(table: AdminLabelTable = .shared) -> Place? {
        guard countryISO.count == 2 else { return nil }
        let sameCountry = original?.countryISO == countryISO
        var admin: [AdminTier: AdminValue] = sameCountry ? (original?.admin ?? [:]) : [:]
        for field in fields(table: table) {
            guard let tier = field.tier, let level = field.level else { continue }
            let name = trimmed(field.id)
            if sameCountry, name == initialTrimmed(field.id), let old = original?.admin[tier] {
                admin[tier] = old
                continue
            }
            guard !name.isEmpty else {
                admin[tier] = nil
                continue
            }
            admin[tier] = AdminValue(name: name, native: "", level: level)
        }
        return Place(countryISO: countryISO, admin: admin, island: trimmed(Self.islandID),
                     mountainRange: trimmed(Self.mountainRangeID), mountain: trimmed(Self.mountainID))
    }

    /// True when the user changed the country or a visible field
    /// (compared with the values the form opened with).
    func isChanged(table: AdminLabelTable = .shared) -> Bool {
        guard countryISO.count == 2 else { return false }
        guard let original, original.countryISO == countryISO else { return true }
        return fields(table: table).contains { trimmed($0.id) != initialTrimmed($0.id) }
    }

    private func trimmed(_ id: String) -> String {
        values[id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func initialTrimmed(_ id: String) -> String {
        initialValues[id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

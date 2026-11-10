import FieldworksGeo
import Foundation

/// One visible place field: the country-specific term (nil when the
/// table knows none), the generic type in German and the value.
struct PlaceFieldItem: Identifiable, Equatable {
    /// `admin_<tier>` or `island` / `mountain_range` / `mountain`.
    let id: String
    let term: String?
    let genericLabel: String
    let value: String

    /// What the row shows on top: the local term, else the generic type.
    var displayTerm: String {
        term ?? genericLabel
    }
}

/// Display rules for Ortus place data (Phase O2). Pure functions so
/// lists, the editor, the filter and the tests share one definition.
enum PlaceDisplay {
    /// German text of a generic key (`admin.*`, `place.*`) from
    /// `Localizable.xcstrings`. Falls back to the key itself.
    static func genericLabel(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: key, table: nil)
    }

    /// Visible fields of `place` in level order (lowest OSM level =
    /// broadest unit first), then island, mountain range, mountain.
    /// Empty fields are left out.
    static func fields(_ place: Place, table: AdminLabelTable = .shared) -> [PlaceFieldItem] {
        let tierOrder = AdminTier.allCases
        let admin = place.admin
            .compactMap { tier, value -> (AdminTier, AdminValue, String)? in
                let text = displayValue(value)
                return text.isEmpty ? nil : (tier, value, text)
            }
            .sorted { lhs, rhs in
                let l = lhs.1.level == 0 ? Int.max : lhs.1.level
                let r = rhs.1.level == 0 ? Int.max : rhs.1.level
                if l != r { return l < r }
                return (tierOrder.firstIndex(of: lhs.0) ?? 0) < (tierOrder.firstIndex(of: rhs.0) ?? 0)
            }
            .map { tier, value, text -> PlaceFieldItem in
                let label = PlaceLabels.label(
                    country: place.countryISO.isEmpty ? nil : place.countryISO,
                    tier: tier,
                    level: value.level == 0 ? nil : value.level,
                    rawLocalTerm: nil,
                    table: table
                )
                return PlaceFieldItem(id: tier.rawValue, term: label.term,
                                      genericLabel: genericLabel(label.genericKey), value: text)
            }
        let landscape: [(String, String, String)] = [
            (PlaceForm.islandID, PlaceLabels.islandKey, place.island),
            (PlaceForm.mountainRangeID, PlaceLabels.mountainRangeKey, place.mountainRange),
            (PlaceForm.mountainID, PlaceLabels.mountainKey, place.mountain)
        ]
        let extra = landscape.compactMap { id, key, value -> PlaceFieldItem? in
            let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : PlaceFieldItem(id: id, term: nil, genericLabel: genericLabel(key), value: text)
        }
        return admin + extra
    }

    /// Gazetteer line of the sample view (Phase N): the German country
    /// name first, then the admin levels from broad to narrow, values
    /// only, comma-separated; empty levels are skipped. Landscape fields
    /// (island, mountain) are not part of it. nil when nothing is set.
    static func gazetteerLine(_ place: Place?, table: AdminLabelTable = .shared) -> String? {
        guard let place else { return nil }
        var parts: [String] = []
        if !place.countryISO.isEmpty {
            parts.append(countryName(place.countryISO, table: table))
        } else if let country = place.admin[.country] {
            let text = displayValue(country)
            if !text.isEmpty { parts.append(text) }
        }
        var levels = place
        levels.admin[.country] = nil
        levels.island = ""
        levels.mountainRange = ""
        levels.mountain = ""
        parts += fields(levels, table: table).map(\.value)
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// One terrain line below the gazetteer line: „Peilung“,
    /// „Exposition“, „Hangneigung“, or a label-less „eben“.
    struct DetailLine: Identifiable, Equatable {
        let label: String?
        let value: String
        var id: String {
            label ?? value
        }
    }

    /// Bearing, aspect and slope of a sample, only the present ones.
    /// Flat terrain shows „eben“ instead of aspect and slope.
    static func detailLines(_ sample: LocalSample) -> [DetailLine] {
        detailLines(bearingLabel: sample.bearingLabel, aspectCompass: sample.aspectCompass,
                    aspectDeg: sample.aspectDeg, slopeDeg: sample.slopeDeg, terrainFlat: sample.terrainFlat)
    }

    static func detailLines(bearingLabel: String?, aspectCompass: String?, aspectDeg: Double?,
                            slopeDeg: Double?, terrainFlat: Bool) -> [DetailLine]
    {
        var lines: [DetailLine] = []
        if let bearing = bearingLabel?.trimmingCharacters(in: .whitespacesAndNewlines), !bearing.isEmpty {
            lines.append(DetailLine(label: "Peilung", value: bearing))
        }
        if terrainFlat {
            lines.append(DetailLine(label: nil, value: "eben"))
            return lines
        }
        let compass = aspectCompass?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let degrees = aspectDeg.map { "\(Int($0.rounded()))°" }
        switch (compass.isEmpty ? nil : compass, degrees) {
        case let (compass?, degrees?): lines.append(DetailLine(label: "Exposition", value: "\(compass) (\(degrees))"))
        case let (compass?, nil): lines.append(DetailLine(label: "Exposition", value: compass))
        case let (nil, degrees?): lines.append(DetailLine(label: "Exposition", value: degrees))
        case (nil, nil): break
        }
        if let slope = slopeDeg {
            lines.append(DetailLine(label: "Hangneigung", value: "\(Int(slope.rounded()))°"))
        }
        return lines
    }

    /// Coordinate in the chosen display format plus the format's name
    /// for the caption below. Falls back to signed decimal degrees when
    /// the format can't express the point (e.g. UTM near the poles).
    static func coordinate(latitude: Double, longitude: Double,
                           format: CoordinateDisplayFormat) -> (text: String, caption: String)
    {
        if let text = CoordinateConverter.format(lat: latitude, lon: longitude, as: format) {
            return (text, format.title)
        }
        let fallback = CoordinateDisplayFormat.decimalSign
        let text = CoordinateConverter.format(lat: latitude, lon: longitude, as: fallback)
            ?? String(format: "%.6f, %.6f", latitude, longitude)
        return (text, fallback.title)
    }

    /// Name for list rows: the municipality, else the next higher
    /// filled level (district, county, … up to the country).
    static func shortName(_ place: Place?) -> String? {
        guard let place else { return nil }
        let upward: [AdminTier] = [.municipality, .district, .county, .province, .region, .state, .country]
        for tier in upward {
            if let value = place.admin[tier] {
                let text = displayValue(value)
                if !text.isEmpty { return text }
            }
        }
        return nil
    }

    /// "MTB 6326/1 Ochsenfurt". Only for German samples (the backend
    /// fills MTB only in DE); nil without a sheet number.
    static func mtbText(number: String?, name: String?, quadrant: Int?, countryISO: String?) -> String? {
        guard let number, !number.isEmpty else { return nil }
        if let countryISO, !countryISO.isEmpty, countryISO != "DE" { return nil }
        var text = "MTB \(number)"
        if let quadrant, quadrant > 0 { text += "/\(quadrant)" }
        if let name, !name.isEmpty { text += " \(name)" }
        return text
    }

    /// German country name for an ISO 3166-1 alpha-2 code.
    static func countryName(_ iso: String, table: AdminLabelTable = .shared) -> String {
        if let name = Locale(identifier: "de_DE").localizedString(forRegionCode: iso), !name.isEmpty {
            return name
        }
        return table.countries.first { $0.iso == iso }?.name ?? iso
    }

    /// Case- and diacritic-insensitive substring search over every
    /// place field (all admin names and native names, island, mountain
    /// range, mountain, the German country name). A blank query matches.
    static func matches(_ place: Place, query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        var haystack = place.admin.values.flatMap { [$0.name, $0.native] }
        haystack += [place.island, place.mountainRange, place.mountain]
        if !place.countryISO.isEmpty { haystack.append(countryName(place.countryISO)) }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return haystack.contains { $0.range(of: needle, options: options, locale: Locale(identifier: "de_DE")) != nil }
    }

    private static func displayValue(_ value: AdminValue) -> String {
        let name = value.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? value.native.trimmingCharacters(in: .whitespacesAndNewlines) : name
    }
}

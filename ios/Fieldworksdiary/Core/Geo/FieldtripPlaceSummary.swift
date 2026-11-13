import FieldworksGeo
import Foundation

/// Place line of a fieldtrip, derived on-device from its samples (the
/// fieldtrip record itself carries no place data since Phase O3).
///
/// Use for the fieldtrip list row and the detail header. Pure
/// aggregation, no database access: callers read samples and cached
/// places once per list and pass them in.
struct FieldtripPlaceSummary: Equatable {
    /// Most frequent short place name (municipality, else the next
    /// level, see `PlaceDisplay.shortName`).
    let name: String?
    /// "Deutschland, Bayern" of the place `name` comes from.
    let region: String?
    /// "MTB 6326 Ochsenfurt" of the most frequent sheet (DE only).
    let mtb: String?

    var isEmpty: Bool {
        name == nil && region == nil && mtb == nil
    }

    /// One sample of a fieldtrip with the place columns the summary needs.
    struct Sample {
        let place: Place?
        let mtbSheetNumber: String?
        let mtbSheetName: String?
    }

    /// Summary of one fieldtrip's samples. Ties resolve alphabetically,
    /// so the result is stable.
    static func summarize(_ samples: [Sample]) -> FieldtripPlaceSummary {
        var nameCounts: [String: Int] = [:]
        var placeByName: [String: Place] = [:]
        var mtbCounts: [String: Int] = [:]
        var mtbNames: [String: String] = [:]
        var mtbCountry: [String: String] = [:]
        for sample in samples {
            if let place = sample.place, let name = PlaceDisplay.shortName(place) {
                nameCounts[name, default: 0] += 1
                if placeByName[name] == nil { placeByName[name] = place }
            }
            if let number = sample.mtbSheetNumber, !number.isEmpty {
                mtbCounts[number, default: 0] += 1
                if let n = sample.mtbSheetName, !n.isEmpty, mtbNames[number] == nil { mtbNames[number] = n }
                if mtbCountry[number] == nil { mtbCountry[number] = sample.place?.countryISO }
            }
        }
        let name = mostFrequent(nameCounts)
        var region: String?
        if let name, let place = placeByName[name] {
            var parts: [String] = []
            if !place.countryISO.isEmpty { parts.append(PlaceDisplay.countryName(place.countryISO)) }
            if let state = place.admin[.state] {
                let text = state.name.isEmpty ? state.native : state.name
                if !text.isEmpty, text != name { parts.append(text) }
            }
            region = parts.isEmpty ? nil : parts.joined(separator: ", ")
        }
        var mtb: String?
        if let number = mostFrequent(mtbCounts) {
            mtb = PlaceDisplay.mtbText(number: number, name: mtbNames[number],
                                       quadrant: nil, countryISO: mtbCountry[number])
        }
        return FieldtripPlaceSummary(name: name, region: region, mtb: mtb)
    }

    /// Summaries per fieldtrip id for all local samples at once.
    static func index(
        samples: [LocalSample],
        placemarks: [String: LocalPlacemark]
    ) -> [String: FieldtripPlaceSummary] {
        var grouped: [String: [Sample]] = [:]
        for s in samples {
            guard let fieldtrip = s.fieldtrip, !fieldtrip.isEmpty else { continue }
            grouped[fieldtrip, default: []].append(Sample(
                place: s.placemark.flatMap { placemarks[$0] }?.place,
                mtbSheetNumber: s.mtbSheetNumber, mtbSheetName: s.mtbSheetName
            ))
        }
        return grouped.mapValues(summarize).filter { !$0.value.isEmpty }
    }

    private static func mostFrequent(_ counts: [String: Int]) -> String? {
        counts.max { l, r in l.value != r.value ? l.value < r.value : l.key > r.key }?.key
    }
}

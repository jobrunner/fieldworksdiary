import Foundation

/// Maps an Ortus response onto place, geo values and features. Port of Go
/// `geoplace.FromOrtus`; shared fixtures in `shared/testdata/ortus/`.
public enum OrtusMapper {
    private static let tk25Source = "tk25-blattschnitt-de"

    public static func map(_ r: OrtusResponse, lat: Double, lon: Double,
                           table: AdminLabelTable = .shared) -> OrtusResult {
        var place: Place?
        var geo = SampleGeo()
        if let g = r.gazetteer {
            if let admin = g.admin { place = mapPlace(g, admin, table) }
            mapGeo(g, &geo)
        }
        let results = r.results ?? []
        let features = mapFeatures(results)
        if place?.countryISO == "DE" { mapMTB(results, lat: lat, lon: lon, &geo) }
        return OrtusResult(place: place, geo: geo, features: features)
    }

    private static func mapPlace(_ g: OrtusResponse.Gazetteer, _ a: OrtusResponse.Admin,
                                 _ table: AdminLabelTable) -> Place {
        let iso = a.countryISO ?? ""
        var p = Place(countryISO: iso)
        for u in a.hierarchy ?? [] {
            let (colTier, known) = table.column(country: iso, level: u.level)
            let tier: AdminTier
            if known {
                guard let t = colTier else { continue }
                tier = t
            } else {
                tier = AdminTier(rawValue: "admin_" + (u.equivalent ?? "")) ?? .other
            }
            if let cur = p.admin[tier], !known || cur.level <= u.level { continue }
            p.admin[tier] = AdminValue(name: u.name ?? "", native: u.nameNative ?? "", level: u.level)
        }
        if let first = g.islands?.first { p.island = first.name ?? "" }
        if let m = g.mountains {
            p.mountain = m.mountain?.name ?? ""
            p.mountainRange = m.range?.name ?? ""
        }
        return p
    }

    private static func mapGeo(_ g: OrtusResponse.Gazetteer, _ out: inout SampleGeo) {
        if let e = g.elevation {
            out.elevationDEM = (e.seaLevel ?? false) ? 0 : (e.meters ?? 0)
            out.elevationDEMAccuracy = e.accuracyM ?? 0
        }
        if let x = g.exposure {
            out.slopeDeg = x.slopeDeg ?? 0
            out.aspectDeg = x.aspectDeg
            out.aspectCompass = x.aspectCompass ?? ""
            out.terrainFlat = x.flat ?? false
        }
        if let b = g.bearing {
            out.bearingLabel = b.label ?? ""
            out.bearingReference = b.reference ?? ""
            out.bearingCompass = b.compass ?? ""
            out.bearingDistanceKm = b.distanceKm ?? 0
            out.bearingInside = b.inside ?? false
        }
    }

    private static func mapFeatures(_ results: [OrtusResponse.SourceResult]) -> [OrtusFeature] {
        var out: [OrtusFeature] = []
        for sr in results {
            for f in sr.features ?? [] {
                var license: String?
                if let l = sr.license, l != .null { license = l.jsonString }
                out.append(OrtusFeature(
                    sourceID: sr.sourceID ?? "", sourceName: sr.sourceName ?? "",
                    layer: f.layer ?? "", featureID: idString(f.id),
                    propertiesJSON: JSONValue.object(f.properties ?? [:]).jsonString,
                    licenseJSON: license))
            }
        }
        return out
    }

    private static func idString(_ v: JSONValue?) -> String {
        switch v {
        case .string(let s): return s
        case .number(let n): return JSONValue.numberString(n)
        case .bool(let b): return b ? "true" : "false"
        case .array, .object: return v?.jsonString ?? ""
        case .null, nil: return ""
        }
    }

    /// Sheet number from feature properties (`id`, else `dtknummer`); the
    /// Ortus feature id is only a row index.
    static func sheetNumber(_ props: [String: JSONValue]) -> String {
        for key in ["id", "dtknummer"] {
            switch props[key] {
            case .string(let s):
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { return t }
            case .number(let n): return JSONValue.numberString(n)
            default: break
            }
        }
        return ""
    }

    private static func mapMTB(_ results: [OrtusResponse.SourceResult], lat: Double, lon: Double,
                               _ out: inout SampleGeo) {
        for sr in results where sr.sourceID == tk25Source {
            guard let f = sr.features?.first else { continue }
            let props = f.properties ?? [:]
            out.mtbSheetNumber = sheetNumber(props)
            if case .string(let name)? = props["blattname"] {
                out.mtbSheetName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let cell = TK25.cell(lat: lat, lon: lon) { out.mtbQuadrant = cell.quadrant }
            return
        }
    }
}

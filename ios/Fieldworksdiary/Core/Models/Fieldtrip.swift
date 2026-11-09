import Foundation

/// Legacy enrichment shapes still carried by fieldtrip records (samples
/// use flat Ortus columns since Phase O).
struct AdminUnits: Codable, Equatable {
    let country: String?
    let countryIso: String?
    let adminArea: String?
    let adminArea2: String?
    let adminArea3: String?
    let locality: String?
    let locationDescription: String?
}

struct MTB: Codable, Equatable {
    let sheetNumber: String?
    let sheetName: String?
    let quadrant: Int?
    let found: Bool?

    enum CodingKeys: String, CodingKey {
        case sheetNumber = "sheet_number"
        case sheetName = "sheet_name"
        case quadrant
        case found
    }
}

struct Astro: Codable, Equatable {
    let sunrise: Date?
    let sunset: Date?
    let civilDawn: Date?
    let civilDusk: Date?
    let moonPhase: Double
    let moonPhaseName: String?
    let moonIllumination: Double
    let moonRise: Date?
    let moonSet: Date?
    let moonAboveHorizonDuringFieldtrip: Bool
    let moonAltitudeMaxDuringDeg: Double

    enum CodingKeys: String, CodingKey {
        case sunrise, sunset
        case civilDawn = "civil_dawn"
        case civilDusk = "civil_dusk"
        case moonPhase = "moon_phase"
        case moonPhaseName = "moon_phase_name"
        case moonIllumination = "moon_illumination"
        case moonRise = "moon_rise"
        case moonSet = "moon_set"
        case moonAboveHorizonDuringFieldtrip = "moon_above_horizon_during_fieldtrip"
        case moonAltitudeMaxDuringDeg = "moon_altitude_max_during_deg"
    }
}

/// A Fieldtrip is the bracket around a collecting day. R3 renamed
/// the user-visible columns to align with the Spec:
///
///   - `name` → `title`
///   - `started_at` → `begin_date`
///   - `ended_at`   → `end_date`
///
/// New: `notes` (free text) and `version` (monotone sync counter).
///
/// "Carry-on" columns (centroid, mtb, astro, admin_units, permit,
/// denormalised filter cols) stay where they are — see NEW-2 in the
/// gap analysis.
struct Fieldtrip: Decodable, Identifiable, Equatable {
    let id: String
    /// User-visible title. Defaults to "Sammeltag DD.MM.YYYY" if the
    /// hook hasn't been able to upgrade it from the locality yet.
    let title: String
    let collectingDay: String
    let nightFieldtrip: Bool
    let beginDate: Date?
    let endDate: Date?
    let centroidLat: Double?
    let centroidLon: Double?
    let adminUnits: AdminUnits?
    let mtb: MTB?
    let astro: Astro?
    /// Locality id chosen by the user; empty string ⇒ nil.
    let locality: String?
    /// Locality id proposed by the backend's nearest-match logic.
    let suggestedLocality: String?
    /// Denormalised filter columns, written by the enrichment hook.
    let dayOfYear: Int?
    let country: String?
    let adminArea: String?
    /// Optional research permit on the fieldtrip. Number for labels,
    /// PDF for archive.
    let permitNumber: String?
    let permitPDFFile: String?
    let notes: String?
    let version: Int

    enum CodingKeys: String, CodingKey {
        case id, title, mtb, astro, locality, country
        case collectingDay = "collecting_day"
        case nightFieldtrip = "night_fieldtrip"
        case beginDate = "begin_date"
        case endDate = "end_date"
        case centroidLat = "centroid_lat"
        case centroidLon = "centroid_lon"
        case adminUnits = "admin_units"
        case suggestedLocality = "suggested_locality"
        case dayOfYear = "day_of_year"
        case adminArea = "admin_area"
        case permitNumber = "permit_number"
        case permitPDFFile = "permit_pdf"
        case notes, version
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        collectingDay = try c.decode(String.self, forKey: .collectingDay)
        nightFieldtrip = (try? c.decode(Bool.self, forKey: .nightFieldtrip)) ?? false
        beginDate = try? c.decode(Date.self, forKey: .beginDate)
        endDate = try? c.decode(Date.self, forKey: .endDate)
        let lat = try? c.decode(Double.self, forKey: .centroidLat)
        let lon = try? c.decode(Double.self, forKey: .centroidLon)
        centroidLat = (lat == 0 ? nil : lat)
        centroidLon = (lon == 0 ? nil : lon)
        adminUnits = try? c.decode(AdminUnits.self, forKey: .adminUnits)
        mtb = try? c.decode(MTB.self, forKey: .mtb)
        astro = try? c.decode(Astro.self, forKey: .astro)
        let loc = (try? c.decode(String.self, forKey: .locality)) ?? ""
        locality = loc.isEmpty ? nil : loc
        let sug = (try? c.decode(String.self, forKey: .suggestedLocality)) ?? ""
        suggestedLocality = sug.isEmpty ? nil : sug
        let doy = try? c.decode(Int.self, forKey: .dayOfYear)
        dayOfYear = (doy == 0 ? nil : doy)
        let ctr = (try? c.decode(String.self, forKey: .country)) ?? ""
        country = ctr.isEmpty ? nil : ctr
        let aa = (try? c.decode(String.self, forKey: .adminArea)) ?? ""
        adminArea = aa.isEmpty ? nil : aa
        let pn = (try? c.decode(String.self, forKey: .permitNumber)) ?? ""
        permitNumber = pn.isEmpty ? nil : pn
        let pf = (try? c.decode(String.self, forKey: .permitPDFFile)) ?? ""
        permitPDFFile = pf.isEmpty ? nil : pf
        let nt = (try? c.decode(String.self, forKey: .notes)) ?? ""
        notes = nt.isEmpty ? nil : nt
        version = (try? c.decode(Int.self, forKey: .version)) ?? 1
    }
}

struct FieldtripListResponse: Decodable {
    let items: [Fieldtrip]
    let totalItems: Int?
    let totalPages: Int?
}

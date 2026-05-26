import Foundation

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

struct Fieldtrip: Decodable, Identifiable, Equatable {
    let id: String
    let name: String
    let collectingDay: String
    let nightFieldtrip: Bool
    let startedAt: Date?
    let endedAt: Date?
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

    enum CodingKeys: String, CodingKey {
        case id, name
        case collectingDay = "collecting_day"
        case nightFieldtrip = "night_fieldtrip"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case centroidLat = "centroid_lat"
        case centroidLon = "centroid_lon"
        case adminUnits = "admin_units"
        case mtb, astro
        case locality
        case suggestedLocality = "suggested_locality"
        case dayOfYear = "day_of_year"
        case country
        case adminArea = "admin_area"
        case permitNumber = "permit_number"
        case permitPDFFile = "permit_pdf"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        collectingDay = try c.decode(String.self, forKey: .collectingDay)
        nightFieldtrip = (try? c.decode(Bool.self, forKey: .nightFieldtrip)) ?? false
        startedAt = try? c.decode(Date.self, forKey: .startedAt)
        endedAt = try? c.decode(Date.self, forKey: .endedAt)
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
    }
}

struct FieldtripListResponse: Decodable {
    let items: [Fieldtrip]
    let totalItems: Int?
    let totalPages: Int?
}

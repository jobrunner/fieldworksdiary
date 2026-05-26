import Foundation
import GRDB

/// Local mirror of a `Fieldtrip`. Sub-objects (admin_units, mtb,
/// astro) are kept as JSON blobs so we can round-trip them through
/// the same decoder the network path uses — no need to mirror every
/// nested field in SQL.
struct LocalFieldtrip: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Equatable {
    var id: String
    var title: String
    var collectingDay: String
    var nightFieldtrip: Bool
    var beginDate: Date?
    var endDate: Date?
    var centroidLat: Double?
    var centroidLon: Double?
    var adminUnitsJson: String?
    var mtbJson: String?
    var astroJson: String?
    var locality: String?
    var suggestedLocality: String?
    var dayOfYear: Int?
    var country: String?
    var adminArea: String?
    var permitNumber: String?
    var permitPDFFile: String?
    var notes: String
    var version: Int
    var backendUpdatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, title
        case collectingDay = "collecting_day"
        case nightFieldtrip = "night_fieldtrip"
        case beginDate = "begin_date"
        case endDate = "end_date"
        case centroidLat = "centroid_lat"
        case centroidLon = "centroid_lon"
        case adminUnitsJson = "admin_units_json"
        case mtbJson = "mtb_json"
        case astroJson = "astro_json"
        case locality
        case suggestedLocality = "suggested_locality"
        case dayOfYear = "day_of_year"
        case country
        case adminArea = "admin_area"
        case permitNumber = "permit_number"
        case permitPDFFile = "permit_pdf_file"
        case notes, version
        case backendUpdatedAt = "backend_updated_at"
    }

    static let databaseTableName = "local_fieldtrips"
}

extension LocalFieldtrip {
    /// Decode the stored JSON back into the typed model when needed
    /// for display.
    var adminUnits: AdminUnits? {
        decode(adminUnitsJson)
    }

    var mtb: MTB? {
        decode(mtbJson)
    }

    var astro: Astro? {
        decode(astroJson)
    }

    private func decode<T: Decodable>(_ json: String?) -> T? {
        guard let json, !json.isEmpty,
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder.fieldworks.decode(T.self, from: data)
    }
}

extension LocalFieldtrip {
    /// Build a local row from a network `Fieldtrip`. The current
    /// timestamp is recorded as `backend_updated_at` so the view can
    /// surface "last refreshed at" if we want it later.
    init(from remote: Fieldtrip) {
        id = remote.id
        title = remote.title
        collectingDay = remote.collectingDay
        nightFieldtrip = remote.nightFieldtrip
        beginDate = remote.beginDate
        endDate = remote.endDate
        centroidLat = remote.centroidLat
        centroidLon = remote.centroidLon
        adminUnitsJson = Self.encode(remote.adminUnits)
        mtbJson = Self.encode(remote.mtb)
        astroJson = Self.encode(remote.astro)
        locality = remote.locality
        suggestedLocality = remote.suggestedLocality
        dayOfYear = remote.dayOfYear
        country = remote.country
        adminArea = remote.adminArea
        permitNumber = remote.permitNumber
        permitPDFFile = remote.permitPDFFile
        notes = remote.notes ?? ""
        version = remote.version
        backendUpdatedAt = Date()
    }

    private static func encode<T: Encodable>(_ value: T?) -> String? {
        guard let value else { return nil }
        let encoder = JSONEncoder()
        // The encoded JSON only travels to GRDB and back; no need to
        // match PocketBase's date format.
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

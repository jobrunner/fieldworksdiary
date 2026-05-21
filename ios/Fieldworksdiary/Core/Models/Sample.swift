import Foundation

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

struct Sample: Decodable, Identifiable, Equatable {
    let id: String
    let code: String
    /// Set when the server had to reassign the code on conflict — the
    /// label-on-the-tube code the user originally chose.
    let originalCode: String?
    let excursion: String
    let lat: Double
    let lon: Double
    let accuracyM: Double?
    let altitudeM: Double?
    let collectedFrom: Date?
    /// Free-text notes (substrate, host plant, weather, …) collected
    /// in the add-sample form. PocketBase serialises empty editor
    /// fields as `""` — we decode those to nil for cleaner UI checks.
    let notes: String?
    /// User-facing "star" flag. Defaults to false on the server.
    let marked: Bool
    /// Match key for the offline-first round trip. iOS sets it on
    /// push; the hydrator uses it to merge a server row back into the
    /// existing local row instead of creating a duplicate.
    let clientUuid: String?
    let clientUpdatedAt: Date?
    let adminUnits: AdminUnits?
    let mtb: MTB?

    enum CodingKeys: String, CodingKey {
        case id, code, excursion, lat, lon, notes, marked
        case originalCode = "original_code"
        case accuracyM = "accuracy_m"
        case altitudeM = "altitude_m"
        case collectedFrom = "collected_from"
        case clientUuid = "client_uuid"
        case clientUpdatedAt = "client_updated_at"
        case adminUnits = "admin_units"
        case mtb
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        code = try c.decode(String.self, forKey: .code)
        // PocketBase serialises an empty text field as "" — treat
        // that as nil.
        if let raw = try? c.decode(String.self, forKey: .originalCode), !raw.isEmpty {
            originalCode = raw
        } else {
            originalCode = nil
        }
        excursion = try c.decode(String.self, forKey: .excursion)
        lat = try c.decode(Double.self, forKey: .lat)
        lon = try c.decode(Double.self, forKey: .lon)
        accuracyM = try? c.decode(Double.self, forKey: .accuracyM)
        altitudeM = try? c.decode(Double.self, forKey: .altitudeM)
        collectedFrom = try? c.decode(Date.self, forKey: .collectedFrom)
        if let raw = try? c.decode(String.self, forKey: .notes), !raw.isEmpty {
            notes = raw
        } else {
            notes = nil
        }
        marked = (try? c.decode(Bool.self, forKey: .marked)) ?? false
        if let raw = try? c.decode(String.self, forKey: .clientUuid), !raw.isEmpty {
            clientUuid = raw
        } else {
            clientUuid = nil
        }
        clientUpdatedAt = try? c.decode(Date.self, forKey: .clientUpdatedAt)
        adminUnits = try? c.decode(AdminUnits.self, forKey: .adminUnits)
        mtb = try? c.decode(MTB.self, forKey: .mtb)
    }
}

/// Wire response from PocketBase's `/api/collections/samples/records`
/// listing endpoint. Items have the same shape as a single GET; the
/// envelope only adds pagination metadata, which we ignore.
struct SampleListResponse: Decodable {
    let items: [Sample]
}

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
    /// Sample identifier in the form "YYMMDD/N" — formerly `code`.
    /// Renamed in R3 to align with the cross-platform Spec.
    let sampleID: String
    /// Set when the server had to reassign the sample_id on
    /// conflict — the label-on-the-tube id the user originally chose.
    let originalCode: String?
    let fieldtrip: String
    /// Optional locality this sample belongs to. Empty on the wire
    /// means "not assigned"; we decode "" to nil.
    let locality: String?
    /// Latitude and longitude are now optional (Spec 1.2) — a sample
    /// can exist without a coordinate (nachträglich erfasst, GPS-
    /// gesperrt, …).
    let latitude: Double?
    let longitude: Double?
    let altitude: Double?
    let horizontalAccuracy: Double?
    let verticalAccuracy: Double?
    /// Where the coordinate came from. Drives whether downstream
    /// code may overwrite it.
    let locationSource: LocationSource
    /// Time window for the observation. Both UTC; `isAllDay` only
    /// controls how the UI renders them.
    let beginDate: Date?
    let endDate: Date?
    let isAllDay: Bool
    /// IANA identifier (`Europe/Berlin` etc.). Stored alongside the
    /// UTC instants so the UI can format them in the right zone
    /// without losing DST information across years.
    let timeZone: String
    /// Free-text notes (substrate, host plant, weather, …) collected
    /// in the add-sample form. PocketBase serialises empty editor
    /// fields as `""` — we decode those to nil for cleaner UI checks.
    let notes: String?
    /// User-facing "star" flag. Defaults to false on the server.
    let marked: Bool
    /// Monotone sync counter — server increments on every write,
    /// 409 on stale push.
    let version: Int
    /// Match key for the offline-first round trip. iOS sets it on
    /// push; the hydrator uses it to merge a server row back into the
    /// existing local row instead of creating a duplicate.
    let clientUuid: String?
    let clientUpdatedAt: Date?
    let adminUnits: AdminUnits?
    let mtb: MTB?

    enum CodingKeys: String, CodingKey {
        case id, fieldtrip, locality, notes, marked, mtb, altitude, latitude, longitude, version
        case sampleID = "sample_id"
        case originalCode = "original_code"
        case horizontalAccuracy = "horizontal_accuracy"
        case verticalAccuracy = "vertical_accuracy"
        case beginDate = "begin_date"
        case endDate = "end_date"
        case isAllDay = "is_all_day"
        case timeZone = "time_zone"
        case locationSource = "location_source"
        case clientUuid = "client_uuid"
        case clientUpdatedAt = "client_updated_at"
        case adminUnits = "admin_units"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        sampleID = try c.decode(String.self, forKey: .sampleID)
        // PocketBase serialises an empty text field as "" — treat
        // that as nil.
        originalCode = decodeNonEmpty(c, .originalCode)
        fieldtrip = try c.decode(String.self, forKey: .fieldtrip)
        locality = decodeNonEmpty(c, .locality)
        latitude = decodeNonZeroDouble(c, .latitude)
        longitude = decodeNonZeroDouble(c, .longitude)
        altitude = try? c.decode(Double.self, forKey: .altitude)
        horizontalAccuracy = try? c.decode(Double.self, forKey: .horizontalAccuracy)
        verticalAccuracy = try? c.decode(Double.self, forKey: .verticalAccuracy)
        locationSource = LocationSource(wire: try? c.decode(String.self, forKey: .locationSource))
        beginDate = try? c.decode(Date.self, forKey: .beginDate)
        endDate = try? c.decode(Date.self, forKey: .endDate)
        isAllDay = (try? c.decode(Bool.self, forKey: .isAllDay)) ?? false
        timeZone = (try? c.decode(String.self, forKey: .timeZone))
            .flatMap { $0.isEmpty ? nil : $0 } ?? "Europe/Berlin"
        notes = decodeNonEmpty(c, .notes)
        marked = (try? c.decode(Bool.self, forKey: .marked)) ?? false
        version = (try? c.decode(Int.self, forKey: .version)) ?? 1
        clientUuid = decodeNonEmpty(c, .clientUuid)
        clientUpdatedAt = try? c.decode(Date.self, forKey: .clientUpdatedAt)
        adminUnits = try? c.decode(AdminUnits.self, forKey: .adminUnits)
        mtb = try? c.decode(MTB.self, forKey: .mtb)
    }
}

/// Decode a string field, treating PocketBase's empty-string default
/// as nil. Saves every call-site from re-implementing the same dance.
private func decodeNonEmpty<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) -> String? {
    if let raw = try? c.decode(String.self, forKey: key), !raw.isEmpty {
        return raw
    }
    return nil
}

private func decodeNonZeroDouble<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) -> Double? {
    let v = try? c.decode(Double.self, forKey: key)
    if v == 0 { return nil }
    return v
}

/// Wire response from PocketBase's `/api/collections/samples/records`
/// listing endpoint. Items have the same shape as a single GET; the
/// envelope only adds pagination metadata, which we ignore.
struct SampleListResponse: Decodable {
    let items: [Sample]
}

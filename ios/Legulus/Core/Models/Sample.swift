import Foundation

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
    /// Metres above sea level (wire key `elevation`, was `altitude`
    /// before Phase O). PocketBase stores an unset number as 0, so 0
    /// without an `elevation_source` decodes to nil.
    let elevation: Double?
    let elevationSource: ElevationSource?
    let horizontalAccuracy: Double?
    let verticalAccuracy: Double?
    /// Where the coordinate came from. Drives whether downstream
    /// code may overwrite it.
    let locationSource: LocationSource
    /// Place-data state; nil when the server sent "" (legacy rows).
    let locationStatus: LocationStatus?
    /// Backend placemark ids (never local UUIDs).
    let placemark: String?
    let placemarkSuggestion: String?
    /// Time window for the observation. Both UTC; `isAllDay` only
    /// controls how the UI renders them.
    let beginDate: Date?
    let endDate: Date?
    let isAllDay: Bool
    /// IANA identifier (`Europe/Berlin` etc.). Stored alongside the
    /// UTC instants so the UI can format them in the right zone
    /// without losing DST information across years.
    let timezone: String
    /// Where `timezone` came from; nil for rows from before Phase Z.
    let timezoneSource: TimezoneSource?
    /// Collecting day `YYYY-MM-DD`; nil when the server sent none.
    let collectingDay: String?
    /// Entered afterwards (`samples.is_retrospective`); false when absent.
    let isRetrospective: Bool
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
    /// PocketBase system field `updated` (server write time). Drives the
    /// incremental `SamplesHydrator` cursor; nil when absent.
    let updated: Date?
    /// Ortus geo values (MTB, DEM, terrain, bearing). Nil when the
    /// server row carries no enrichment yet — PocketBase returns 0 /
    /// "" / false for unset columns, which must not be mistaken for
    /// real values (see `SampleGeoValues.init(from:)`).
    let geo: SampleGeoValues?

    enum CodingKeys: String, CodingKey {
        case id, fieldtrip, locality, notes, marked, elevation, latitude, longitude, version, placemark
        case sampleID = "sample_id"
        case originalCode = "original_code"
        case horizontalAccuracy = "horizontal_accuracy"
        case verticalAccuracy = "vertical_accuracy"
        case beginDate = "begin_date"
        case endDate = "end_date"
        case isAllDay = "is_all_day"
        case timezone
        case legacyTimeZone = "time_zone"
        case timezoneSource = "timezone_source"
        case collectingDay = "collecting_day"
        case isRetrospective = "is_retrospective"
        case locationSource = "location_source"
        case clientUuid = "client_uuid"
        case clientUpdatedAt = "client_updated_at"
        case updated
        case elevationSource = "elevation_source"
        case locationStatus = "location_status"
        case placemarkSuggestion = "placemark_suggestion"
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
        elevationSource = decodeNonEmpty(c, .elevationSource).flatMap(ElevationSource.init(rawValue:))
        let rawElevation = try? c.decode(Double.self, forKey: .elevation)
        elevation = (rawElevation == 0 && elevationSource == nil) ? nil : rawElevation
        // 0 is how the app clears the fields on the server.
        let hAcc = try? c.decode(Double.self, forKey: .horizontalAccuracy)
        horizontalAccuracy = hAcc == 0 ? nil : hAcc
        let vAcc = try? c.decode(Double.self, forKey: .verticalAccuracy)
        verticalAccuracy = vAcc == 0 ? nil : vAcc
        locationSource = LocationSource(wire: try? c.decode(String.self, forKey: .locationSource))
        locationStatus = decodeNonEmpty(c, .locationStatus).flatMap(LocationStatus.init(rawValue:))
        placemark = decodeNonEmpty(c, .placemark)
        placemarkSuggestion = decodeNonEmpty(c, .placemarkSuggestion)
        beginDate = try? c.decode(Date.self, forKey: .beginDate)
        endDate = try? c.decode(Date.self, forKey: .endDate)
        isAllDay = (try? c.decode(Bool.self, forKey: .isAllDay)) ?? false
        // `timezone` since Phase Z; older servers sent `time_zone`.
        timezone = decodeNonEmpty(c, .timezone) ?? decodeNonEmpty(c, .legacyTimeZone) ?? "Europe/Berlin"
        timezoneSource = decodeNonEmpty(c, .timezoneSource).flatMap(TimezoneSource.init(rawValue:))
        collectingDay = decodeNonEmpty(c, .collectingDay)
        isRetrospective = (try? c.decode(Bool.self, forKey: .isRetrospective)) ?? false
        notes = decodeNonEmpty(c, .notes)
        marked = (try? c.decode(Bool.self, forKey: .marked)) ?? false
        version = (try? c.decode(Int.self, forKey: .version)) ?? 1
        clientUuid = decodeNonEmpty(c, .clientUuid)
        clientUpdatedAt = try? c.decode(Date.self, forKey: .clientUpdatedAt)
        updated = try? c.decode(Date.self, forKey: .updated)
        let geo = try SampleGeoValues(from: decoder)
        self.geo = geo.isEmpty && locationStatus != .backendService ? nil : geo
    }
}

/// Flat Ortus geo columns of a server sample (migration 1700000024).
/// Text columns decode "" to nil; numbers are only taken as real
/// values when a sibling column proves the enrichment ran (PocketBase
/// writes 0 for an unset number, and `geoplace.ApplyGeo` writes 0 for
/// a nil value).
struct SampleGeoValues: Decodable, Equatable {
    var mtbSheetNumber: String?
    var mtbSheetName: String?
    /// 1–4; 0 on the wire means none and decodes to nil.
    var mtbQuadrant: Int?
    var slopeDeg: Double?
    var aspectDeg: Double?
    var aspectCompass: String?
    var terrainFlat: Bool
    var bearingLabel: String?
    var bearingReference: String?
    var bearingDistanceKm: Double?
    var bearingCompass: String?
    var bearingInside: Bool

    enum CodingKeys: String, CodingKey {
        case mtbSheetNumber = "mtb_sheet_number"
        case mtbSheetName = "mtb_sheet_name"
        case mtbQuadrant = "mtb_quadrant"
        case slopeDeg = "slope_deg"
        case aspectDeg = "aspect_deg"
        case aspectCompass = "aspect_compass"
        case terrainFlat = "terrain_flat"
        case bearingLabel = "bearing_label"
        case bearingReference = "bearing_reference"
        case bearingDistanceKm = "bearing_distance_km"
        case bearingCompass = "bearing_compass"
        case bearingInside = "bearing_inside"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mtbSheetNumber = decodeNonEmpty(c, .mtbSheetNumber)
            ?? (try? c.decode(Int.self, forKey: .mtbSheetNumber)).flatMap { $0 == 0 ? nil : String($0) }
        mtbSheetName = decodeNonEmpty(c, .mtbSheetName)
        let quadrant = (try? c.decode(Double.self, forKey: .mtbQuadrant)).map { Int($0) } ?? 0
        mtbQuadrant = quadrant == 0 ? nil : quadrant
        aspectCompass = decodeNonEmpty(c, .aspectCompass)
        terrainFlat = (try? c.decode(Bool.self, forKey: .terrainFlat)) ?? false
        bearingLabel = decodeNonEmpty(c, .bearingLabel)
        bearingReference = decodeNonEmpty(c, .bearingReference)
        bearingCompass = decodeNonEmpty(c, .bearingCompass)
        bearingInside = (try? c.decode(Bool.self, forKey: .bearingInside)) ?? false

        // A slope is only meaningful when non-zero or next to a
        // terrain flag; an aspect next to its compass label; a distance next
        // to its bearing label.
        let slope = try? c.decode(Double.self, forKey: .slopeDeg)
        slopeDeg = (terrainFlat || (slope ?? 0) != 0) ? slope : nil
        let aspect = try? c.decode(Double.self, forKey: .aspectDeg)
        aspectDeg = aspectCompass != nil ? aspect : nil
        let distance = try? c.decode(Double.self, forKey: .bearingDistanceKm)
        bearingDistanceKm = bearingLabel != nil ? distance : nil
    }

    /// True when no column carries a real value.
    var isEmpty: Bool {
        mtbSheetNumber == nil && mtbSheetName == nil && mtbQuadrant == nil
            && slopeDeg == nil && aspectCompass == nil
            && !terrainFlat && bearingLabel == nil && bearingCompass == nil && !bearingInside
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
/// envelope's pagination metadata is ignored (keyset paging).
struct SampleListResponse: Decodable {
    let items: [Sample]
}

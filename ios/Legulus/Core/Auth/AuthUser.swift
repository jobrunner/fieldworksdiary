import Foundation

/// The PocketBase `users` record shape — only the fields we surface
/// to the UI. PocketBase returns plenty more (created/updated, etc.)
/// but we ignore them at this layer.
struct AuthUser: Codable, Equatable, Identifiable {
    let id: String
    let email: String
    let displayName: String
    let abbreviation: String
    let dayCutoffHour: Int
    let defaultFieldtripSplitKm: Double
    /// Sample-ID settings (Phase Z); nil = not set on the server.
    let sampleIDFormat: String?
    let sampleIDPrefix: String?
    let sampleIDOffset: Int?

    enum CodingKeys: String, CodingKey {
        case id, email
        case displayName = "display_name"
        case abbreviation
        case dayCutoffHour = "day_cutoff_hour"
        case defaultFieldtripSplitKm = "default_fieldtrip_split_km"
        case sampleIDFormat = "sample_id_format"
        case sampleIDPrefix = "sample_id_prefix"
        case sampleIDOffset = "sample_id_offset"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        email = (try? c.decode(String.self, forKey: .email)) ?? ""
        displayName = (try? c.decode(String.self, forKey: .displayName)) ?? ""
        abbreviation = (try? c.decode(String.self, forKey: .abbreviation)) ?? ""
        let h = (try? c.decode(Int.self, forKey: .dayCutoffHour)) ?? 0
        dayCutoffHour = h
        let s = (try? c.decode(Double.self, forKey: .defaultFieldtripSplitKm)) ?? 15
        defaultFieldtripSplitKm = s
        sampleIDFormat = try? c.decode(String.self, forKey: .sampleIDFormat)
        sampleIDPrefix = try? c.decode(String.self, forKey: .sampleIDPrefix)
        sampleIDOffset = (try? c.decode(Int.self, forKey: .sampleIDOffset))
    }
}

struct AuthResponse: Decodable {
    let token: String
    let record: AuthUser
}

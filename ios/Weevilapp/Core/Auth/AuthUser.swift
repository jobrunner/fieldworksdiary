import Foundation

/// The PocketBase `users` record shape — only the fields we surface
/// to the UI. PocketBase returns plenty more (created/updated, etc.)
/// but we ignore them at this layer.
struct AuthUser: Decodable, Equatable, Identifiable {
    let id: String
    let email: String
    let displayName: String
    let abbreviation: String
    let dayCutoffHour: Int
    let defaultExcursionSplitKm: Double

    enum CodingKeys: String, CodingKey {
        case id, email
        case displayName             = "display_name"
        case abbreviation
        case dayCutoffHour           = "day_cutoff_hour"
        case defaultExcursionSplitKm = "default_excursion_split_km"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        email = (try? c.decode(String.self, forKey: .email)) ?? ""
        displayName = (try? c.decode(String.self, forKey: .displayName)) ?? ""
        abbreviation = (try? c.decode(String.self, forKey: .abbreviation)) ?? ""
        let h = (try? c.decode(Int.self, forKey: .dayCutoffHour)) ?? 5
        dayCutoffHour = h
        let s = (try? c.decode(Double.self, forKey: .defaultExcursionSplitKm)) ?? 15
        defaultExcursionSplitKm = s
    }
}

struct AuthResponse: Decodable {
    let token: String
    let record: AuthUser
}

import Foundation

struct Person: Decodable, Identifiable, Equatable {
    let id: String
    let fullName: String
    let abbreviation: String
    let email: String
    let notes: String

    enum CodingKeys: String, CodingKey {
        case id, abbreviation, email, notes
        case fullName = "full_name"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        fullName = (try? c.decode(String.self, forKey: .fullName)) ?? ""
        abbreviation = (try? c.decode(String.self, forKey: .abbreviation)) ?? ""
        email = (try? c.decode(String.self, forKey: .email)) ?? ""
        notes = (try? c.decode(String.self, forKey: .notes)) ?? ""
    }
}

struct PersonListResponse: Decodable {
    let items: [Person]
}

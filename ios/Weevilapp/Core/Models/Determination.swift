import Foundation

/// The three kinds of taxonomic statements allowed on a label.
/// Stored verbatim ("det" / "t" / "vid") in PocketBase — the Select
/// field's option set there is the single source of truth for what's
/// valid.
enum DeterminationKind: String, Codable, CaseIterable, Identifiable {
    case det
    case t
    case vid

    var id: String { rawValue }

    /// Short label as it appears on the printed sample label.
    var labelShort: String {
        switch self {
        case .det: "det."
        case .t:   "t."
        case .vid: "vid."
        }
    }

    /// Long label for the form UI, with the latin gloss.
    var labelLong: String {
        switch self {
        case .det: "Bestimmung (determinavit)"
        case .t:   "Bestätigung (teste)"
        case .vid: "Gesehen (vidit)"
        }
    }
}

struct Determination: Decodable, Identifiable, Equatable {
    let id: String
    let sample: String
    let speciesText: String
    let kind: DeterminationKind
    let person: String?      // person id, empty string ⇒ nil
    let determinedOn: Date?
    let notes: String

    enum CodingKeys: String, CodingKey {
        case id, sample, kind, person, notes
        case speciesText  = "species_text"
        case determinedOn = "determined_on"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        sample = try c.decode(String.self, forKey: .sample)
        speciesText = (try? c.decode(String.self, forKey: .speciesText)) ?? ""
        kind = try c.decode(DeterminationKind.self, forKey: .kind)
        let p = (try? c.decode(String.self, forKey: .person)) ?? ""
        person = p.isEmpty ? nil : p
        determinedOn = try? c.decode(Date.self, forKey: .determinedOn)
        notes = (try? c.decode(String.self, forKey: .notes)) ?? ""
    }
}

struct DeterminationListResponse: Decodable {
    let items: [Determination]
}

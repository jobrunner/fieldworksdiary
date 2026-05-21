import Foundation

struct LabelPDF: Decodable, Identifiable, Equatable {
    let id: String
    let kind: String
    let pdfFile: String
    let template: String
    let collectionId: String
    let samples: [String]
    let created: Date?

    enum CodingKeys: String, CodingKey {
        case id, kind, template, samples, created
        case pdfFile      = "pdf_file"
        case collectionId = "collectionId"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = (try? c.decode(String.self, forKey: .kind)) ?? ""
        pdfFile = (try? c.decode(String.self, forKey: .pdfFile)) ?? ""
        template = (try? c.decode(String.self, forKey: .template)) ?? ""
        collectionId = (try? c.decode(String.self, forKey: .collectionId)) ?? "label_pdfs"
        samples = (try? c.decode([String].self, forKey: .samples)) ?? []
        created = try? c.decode(Date.self, forKey: .created)
    }
}

import Foundation

/// The layout templates the backend understands. Names mirror the
/// `template` query param the Go side resolves via
/// `pdf.LayoutFromTemplate`.
enum LabelTemplate: String, CaseIterable, Identifiable {
    case defaultA6     = "default"
    case multiUpA4     = "multi-up-a4"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .defaultA6:  "A6 (eine pro Seite)"
        case .multiUpA4:  "A4 multi-up (4 × 8)"
        }
    }
}

struct LabelClient {
    let endpoint: String
    let auth: AuthSession?

    init(endpoint: String, auth: AuthSession? = nil) {
        self.endpoint = endpoint
        self.auth = auth
    }

    /// Renders locality labels for `sampleIDs` and returns the record.
    func generateLocality(sampleIDs: [String], template: LabelTemplate = .defaultA6) async throws -> LabelPDF {
        try await postLabels(path: "/api/label-pdfs/locality", sampleIDs: sampleIDs, template: template)
    }

    /// Renders determination labels (one per sample, picking that
    /// sample's most-recent `det.` if any, otherwise the most-recent
    /// of any kind). Samples without a determination are skipped on
    /// the backend; the response contains only the samples that
    /// actually landed on the PDF.
    func generateDetermination(sampleIDs: [String], template: LabelTemplate = .defaultA6) async throws -> LabelPDF {
        try await postLabels(path: "/api/label-pdfs/determination", sampleIDs: sampleIDs, template: template)
    }

    /// Lists previously-generated label_pdfs records that reference
    /// at least one sample from the given excursion. PocketBase
    /// filter syntax supports `?=` (in-list) on relation fields.
    func listForSamples(_ sampleIDs: [String]) async throws -> [LabelPDF] {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SampleClientError.noEndpoint }
        guard !sampleIDs.isEmpty else { return [] }

        // Build an `or`-joined filter: samples ?~ 'sampleA' || ...
        // `?~ 'x'` matches if any item in the relation contains 'x'.
        // We use `?=` for exact-match on each id.
        let clauses = sampleIDs.map { "samples ?= '\($0)'" }.joined(separator: " || ")
        var components = URLComponents(string: trimmed.appending("/api/collections/label_pdfs/records"))
        components?.queryItems = [
            URLQueryItem(name: "filter", value: clauses),
            URLQueryItem(name: "sort", value: "-created"),
            URLQueryItem(name: "perPage", value: "50"),
        ]
        guard let url = components?.url else { throw SampleClientError.invalidEndpoint }
        var req = URLRequest(url: url); req.timeoutInterval = 6
        req.authenticate(with: auth)
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            throw SampleClientError.http(status: status, body: String(data: data, encoding: .utf8) ?? "")
        }
        do {
            return try JSONDecoder.fieldworks.decode(LabelPDFListResponse.self, from: data).items
        } catch {
            throw SampleClientError.decoding(error.localizedDescription)
        }
    }

    /// URL of the rendered PDF on the backend. Suitable for
    /// downloading via URLSession.
    func pdfFileURL(for label: LabelPDF) -> URL? {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmed.appending(
            "/api/files/\(label.collectionId)/\(label.id)/\(label.pdfFile)"
        ))
    }

    /// Downloads the PDF bytes and returns a Caches-directory URL
    /// suitable for `ShareLink` or QuickLook.
    func downloadPDF(_ label: LabelPDF) async throws -> URL {
        guard let url = pdfFileURL(for: label) else {
            throw SampleClientError.invalidEndpoint
        }
        var request = URLRequest(url: url)
        request.authenticate(with: auth)
        let (tempURL, response) = try await URLSession.shared.download(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            try? FileManager.default.removeItem(at: tempURL)
            throw SampleClientError.http(status: status, body: "")
        }
        let caches = try FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        let dest = caches.appendingPathComponent(label.pdfFile)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tempURL, to: dest)
        return dest
    }

    // MARK: - private

    private func postLabels(path: String, sampleIDs: [String], template: LabelTemplate) async throws -> LabelPDF {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SampleClientError.noEndpoint }
        guard let url = URL(string: trimmed.appending(path)) else {
            throw SampleClientError.invalidEndpoint
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "sample_ids": sampleIDs,
            "template":   template.rawValue,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        req.authenticate(with: auth)
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            throw SampleClientError.http(status: status, body: String(data: data, encoding: .utf8) ?? "")
        }
        do {
            return try JSONDecoder.fieldworks.decode(LabelPDF.self, from: data)
        } catch {
            throw SampleClientError.decoding(error.localizedDescription)
        }
    }
}

private struct LabelPDFListResponse: Decodable {
    let items: [LabelPDF]
}

import Foundation

/// Downloads the authenticated user's backup ZIP from the backend.
/// The route streams the archive; we hand it to `URLSession.download`
/// so it lands directly in a temp file without buffering in memory.
struct ExportClient {
    let endpoint: String
    let auth: AuthSession?

    init(endpoint: String, auth: AuthSession? = nil) {
        self.endpoint = endpoint
        self.auth = auth
    }

    /// Returns the local file URL of the downloaded ZIP. The caller
    /// owns the file — the temp directory it lives in is not auto-
    /// cleaned, but iOS purges it when the OS reclaims disk space.
    func downloadExport() async throws -> URL {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SampleClientError.noEndpoint }
        guard let url = URL(string: trimmed.appending("/api/export")) else {
            throw SampleClientError.invalidEndpoint
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 120
        request.authenticate(with: auth)

        let (tempURL, response) = try await URLSession.shared.download(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200 ..< 300).contains(status) else {
            let body = (try? Data(contentsOf: tempURL))
                .flatMap { String(data: $0, encoding: .utf8) } ?? ""
            try? FileManager.default.removeItem(at: tempURL)
            throw SampleClientError.http(status: status, body: body)
        }

        // The download API drops the response into a one-shot temp
        // file with no extension. Move it next door under a stable
        // name so SwiftUI's ShareLink can present a sensible filename.
        let filename = suggestedFilename(from: response) ?? defaultFilename()
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: tempURL, to: destination)
        return destination
    }

    private func suggestedFilename(from response: URLResponse) -> String? {
        guard let http = response as? HTTPURLResponse,
              let header = http.value(forHTTPHeaderField: "Content-Disposition") else { return nil }
        // Parse `attachment; filename="fieldworksdiary-export-….zip"`
        guard let range = header.range(of: #"filename="([^"]+)""#, options: .regularExpression) else { return nil }
        let match = header[range]
        // Strip the prefix `filename="` and trailing `"`.
        let start = match.index(match.startIndex, offsetBy: "filename=\"".count)
        let end = match.index(before: match.endIndex)
        return String(match[start ..< end])
    }

    private func defaultFilename() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withYear, .withMonth, .withDay]
        return "fieldworksdiary-export-\(formatter.string(from: Date())).zip"
    }
}

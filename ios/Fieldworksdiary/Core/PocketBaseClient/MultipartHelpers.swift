import Foundation

/// Shared multipart-form-data helpers for PocketBase uploads. Used by
/// `ExcursionClient.uploadPermitPDF` (Phase 8) and `PhotoClient.upload`
/// (Phase 14). The shape is the standard `--<boundary>` / Content-
/// Disposition framing — nothing PocketBase-specific.
extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) { append(data) }
    }

    mutating func appendField(boundary: String, name: String, value: String) {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        append(value)
        append("\r\n")
    }

    mutating func appendFile(
        boundary: String,
        name: String,
        filename: String,
        mimeType: String,
        data: Data
    ) {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: \(mimeType)\r\n\r\n")
        append(data)
        append("\r\n")
    }
}

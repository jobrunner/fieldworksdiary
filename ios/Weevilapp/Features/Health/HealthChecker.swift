import Foundation
import SwiftUI

@MainActor
final class HealthChecker: ObservableObject {
    enum Status {
        case unknown
        case checking
        case ok
        case failed

        var label: String {
            switch self {
            case .unknown: "Endpoint nicht gesetzt"
            case .checking: "Prüfe …"
            case .ok: "Verbunden"
            case .failed: "Nicht verbunden"
            }
        }

        var color: Color {
            switch self {
            case .unknown: .gray
            case .checking: .yellow
            case .ok: .green
            case .failed: .red
            }
        }
    }

    @Published private(set) var status: Status = .unknown
    @Published private(set) var detail: String = ""

    func check(endpoint raw: String) async {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed.appending("/api/health"))
        else {
            status = .unknown
            detail = "Endpoint in den Einstellungen setzen."
            return
        }

        status = .checking
        detail = url.absoluteString

        var request = URLRequest(url: url)
        request.timeoutInterval = 5

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                status = .ok
                detail = url.absoluteString
            } else {
                status = .failed
                detail = "HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)"
            }
        } catch {
            status = .failed
            detail = error.localizedDescription
        }
    }
}

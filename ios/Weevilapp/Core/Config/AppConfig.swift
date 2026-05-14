import Foundation

@MainActor
final class AppConfig: ObservableObject {
    @Published var endpointURL: String {
        didSet {
            UserDefaults.standard.set(endpointURL, forKey: Keys.endpointURL)
        }
    }

    init() {
        self.endpointURL = UserDefaults.standard.string(forKey: Keys.endpointURL) ?? ""
    }

    private enum Keys {
        static let endpointURL = "AppConfig.endpointURL"
    }
}

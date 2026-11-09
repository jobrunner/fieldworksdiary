import Foundation

/// In welchem Build-Channel die App läuft. Wird beim Bootstrap aus
/// Info.plist (`APP_ENV`, gesetzt aus dem Xcode-Build-Setting) gelesen.
enum AppEnvironment: String {
    case dev
    case staging
    case production
    case unknown

    /// Default-Fallback: wenn der Info.plist-Wert leer oder unbekannt
    /// ist (z. B. Tests laufen ohne unsere Build-Settings), nehmen wir
    /// `dev` an — das ist der sicherste Default (keine Prod-URL).
    static func current() -> Self {
        let raw = Bundle.main.object(forInfoDictionaryKey: "APP_ENV") as? String ?? ""
        return Self(rawValue: raw) ?? .dev
    }

    /// Wenn `true`, sollte die UI ein deutliches Badge tragen, damit
    /// der Tester keine Verwechslung mit Prod hat.
    var isNonProduction: Bool {
        switch self {
        case .production: false
        case .dev, .staging, .unknown: true
        }
    }

    var displayLabel: String {
        switch self {
        case .dev: "DEV"
        case .staging: "STAGING"
        case .production: "PROD"
        case .unknown: "?"
        }
    }
}

@MainActor
final class AppConfig: ObservableObject {
    @Published var endpointURL: String {
        didSet {
            UserDefaults.standard.set(endpointURL, forKey: Self.Keys.endpointURL)
        }
    }

    /// Base URL of the Ortus geo service, queried directly from the
    /// device right after a sample is saved (Phase O2). An empty value
    /// disables the on-device query — samples then behave as offline
    /// and the backend fills the place after sync.
    @Published var ortusEndpointURL: String {
        didSet {
            UserDefaults.standard.set(ortusEndpointURL, forKey: Self.Keys.ortusEndpointURL)
        }
    }

    static let defaultOrtusEndpointURL = "https://ortus.fieldworksdiary.org"

    /// User-chosen provisional sample-id format (R8e). Persisted so
    /// the offline code generator (`SampleCodeTemplate.current`) picks
    /// it up on the next sample.
    @Published var sampleCodeTemplate: String {
        didSet {
            UserDefaults.standard.set(sampleCodeTemplate, forKey: SampleCodeTemplate.userDefaultsKey)
        }
    }

    /// Build-Channel — fix pro Build-Konfiguration (Debug/Staging/Release).
    let environment = AppEnvironment.current()

    /// Öffentliche URL der Datenschutzerklärung. Apple verlangt die
    /// Adresse zusätzlich im App-Store-Connect-Eintrag — der Link hier
    /// ist die In-App-Variante (Settings → Datenschutz). Hosting:
    /// `docs/datenschutz.md` muss auf eine erreichbare Seite gemappt
    /// werden, bevor wir submitten.
    let privacyPolicyURL: URL = .init(string: "https://fieldworksdiary.org/datenschutz")! // swiftlint:disable:this force_unwrapping

    init() {
        let stored = UserDefaults.standard.string(forKey: Self.Keys.endpointURL) ?? ""
        if stored.isEmpty {
            // First-Launch (oder ein Reset): nehmen wir den Build-
            // eingebackenen Default. Debug-Builds haben einen leeren
            // Default, damit der Dev den Endpoint manuell setzen kann.
            let baked = Bundle.main.object(forInfoDictionaryKey: "BACKEND_ENDPOINT_DEFAULT") as? String ?? ""
            endpointURL = baked
            if !baked.isEmpty {
                UserDefaults.standard.set(baked, forKey: Self.Keys.endpointURL)
            }
        } else {
            endpointURL = stored
        }

        // `nil` = never set → default; an explicitly stored "" stays
        // empty (the user switched the on-device query off).
        ortusEndpointURL = UserDefaults.standard.string(forKey: Self.Keys.ortusEndpointURL)
            ?? Self.defaultOrtusEndpointURL

        let storedTemplate = UserDefaults.standard.string(forKey: SampleCodeTemplate.userDefaultsKey)
        sampleCodeTemplate = (storedTemplate?.isEmpty == false)
            ? storedTemplate! // swiftlint:disable:this force_unwrapping
            : SampleCodeTemplate.default.raw
    }

    fileprivate enum Keys {
        static let endpointURL = "AppConfig.endpointURL"
        static let ortusEndpointURL = "ortusEndpointURL"
    }
}

import FieldworksGeo
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

    /// Base URL of the Flipt server for feature flags (Phase E). An
    /// empty value disables flags: every flag then reads `false`.
    let featureFlagsURL = "https://ff.fieldworksdiary.org"

    static let defaultOrtusEndpointURL = "https://ortus.fieldworksdiary.org"

    /// Sample-ID template (Phase Z). Mirrored from the users record
    /// (`sample_id_format`) and cached here so the offline generator
    /// works without a network. Invalid templates (both counters) are
    /// rejected and the previous value stays. Same UserDefaults key as
    /// the old provisional-code template.
    @Published var sampleIDFormat: String {
        didSet {
            guard Self.isValidFormat(sampleIDFormat) else {
                sampleIDFormat = oldValue
                return
            }
            UserDefaults.standard.set(sampleIDFormat, forKey: Keys.sampleIDFormat)
        }
    }

    /// Text for the `<PREFIX>` token.
    @Published var sampleIDPrefix: String {
        didSet { UserDefaults.standard.set(sampleIDPrefix, forKey: Keys.sampleIDPrefix) }
    }

    /// Start offset for the running counter `<n>` (never negative).
    @Published var sampleIDOffset: Int {
        didSet {
            if sampleIDOffset < 0 { sampleIDOffset = 0; return }
            UserDefaults.standard.set(sampleIDOffset, forKey: Keys.sampleIDOffset)
        }
    }

    /// Hour (0...23, local time of the sample) at which a new
    /// collecting day starts.
    @Published var dayCutoffHour: Int {
        didSet {
            let clamped = min(max(dayCutoffHour, 0), 23)
            if clamped != dayCutoffHour { dayCutoffHour = clamped; return }
            UserDefaults.standard.set(dayCutoffHour, forKey: Keys.dayCutoffHour)
        }
    }

    /// Last handed-out number of the running counter. Local only.
    var lastRunningNumber: Int {
        get { UserDefaults.standard.integer(forKey: Keys.lastRunningNumber) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.lastRunningNumber) }
    }

    /// `true` for a non-empty template that does not mix `<seq>` and `<n>`.
    static func isValidFormat(_ raw: String) -> Bool {
        !raw.isEmpty && SampleIDTemplate(raw: raw).isValid
    }

    /// Takes the sample-id settings from the users record. Empty or
    /// missing values fall back to the defaults; an invalid format
    /// keeps the default.
    func apply(user: AuthUser) {
        if let format = user.sampleIDFormat, Self.isValidFormat(format) {
            sampleIDFormat = format
        } else {
            sampleIDFormat = SampleIDTemplate.default.raw
        }
        sampleIDPrefix = user.sampleIDPrefix ?? ""
        sampleIDOffset = max(user.sampleIDOffset ?? 0, 0)
        dayCutoffHour = user.dayCutoffHour
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

        let defaults = UserDefaults.standard
        let storedTemplate = defaults.string(forKey: Keys.sampleIDFormat) ?? ""
        sampleIDFormat = Self.isValidFormat(storedTemplate) ? storedTemplate : SampleIDTemplate.default.raw
        sampleIDPrefix = defaults.string(forKey: Keys.sampleIDPrefix) ?? ""
        sampleIDOffset = max(defaults.integer(forKey: Keys.sampleIDOffset), 0)
        dayCutoffHour = min(max(defaults.integer(forKey: Keys.dayCutoffHour), 0), 23)
    }

    fileprivate enum Keys {
        static let endpointURL = "AppConfig.endpointURL"
        static let ortusEndpointURL = "ortusEndpointURL"
        static let sampleIDFormat = SampleIDSettings.Keys.format
        static let sampleIDPrefix = SampleIDSettings.Keys.prefix
        static let sampleIDOffset = SampleIDSettings.Keys.offset
        static let dayCutoffHour = SampleIDSettings.Keys.cutoffHour
        static let lastRunningNumber = SampleIDSettings.Keys.lastRunning
    }
}

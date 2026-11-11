import FieldworksGeo
import Foundation

/// Thread-safe snapshot of the sample-id and collecting-day settings.
///
/// `AppConfig` (main actor) persists every change to `UserDefaults`
/// right away, so stores that live off the main actor read the same
/// values from there. Reading fresh on every use means a Settings
/// change applies to the next sample without any wiring.
struct SampleIDSettings: Equatable {
    var format: String = SampleIDTemplate.default.raw
    var prefix: String = ""
    var offset: Int = 0
    /// Collecting-day rollover hour, 0...23.
    var cutoffHour: Int = 0
    /// Last handed-out number of the running counter (`<n>`).
    var lastRunning: Int = 0

    var template: SampleIDTemplate { SampleIDTemplate(raw: format) }

    /// UserDefaults keys; shared with `AppConfig`, which writes them.
    enum Keys {
        static let format = "AppConfig.sampleCodeTemplate"
        static let prefix = "AppConfig.sampleIDPrefix"
        static let offset = "AppConfig.sampleIDOffset"
        static let cutoffHour = "AppConfig.dayCutoffHour"
        static let lastRunning = "AppConfig.lastRunningNumber"
    }

    /// Reads the settings; invalid or missing values fall back to defaults.
    static func current(defaults: UserDefaults = .standard) -> SampleIDSettings {
        let raw = defaults.string(forKey: Keys.format) ?? ""
        let valid = !raw.isEmpty && SampleIDTemplate(raw: raw).isValid
        return SampleIDSettings(
            format: valid ? raw : SampleIDTemplate.default.raw,
            prefix: defaults.string(forKey: Keys.prefix) ?? "",
            offset: max(defaults.integer(forKey: Keys.offset), 0),
            cutoffHour: min(max(defaults.integer(forKey: Keys.cutoffHour), 0), 23),
            lastRunning: defaults.integer(forKey: Keys.lastRunning)
        )
    }
}

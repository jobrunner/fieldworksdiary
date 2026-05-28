import Foundation

/// A user-configurable template for the provisional sample id the
/// client hands out offline (R8e). The backend stays the authority —
/// on sync it may relabel — so this only shapes the *local* code.
///
/// Tokens (everything else is copied verbatim):
///
///   - `<YYYY>` four-digit year   `<YY>` two-digit year
///   - `<MM>`   two-digit month   `<DD>` two-digit day
///   - `<seq>`  daily sequence number
///
/// The default `<YY><MM><DD>/<seq>` reproduces the historical
/// "YYMMDD/N" format byte-for-byte, so existing data and the Go
/// server stay in lockstep until the user opts into something else.
struct SampleCodeTemplate: Equatable {
    let raw: String

    static let `default` = SampleCodeTemplate(raw: "<YY><MM><DD>/<seq>")

    /// A handful of presets surfaced in Settings. The first is the
    /// canonical default.
    static let presets: [SampleCodeTemplate] = [
        .default,
        SampleCodeTemplate(raw: "<YYYY><MM><DD>/<seq>"),
        SampleCodeTemplate(raw: "<YY><MM><DD>-<seq>"),
        SampleCodeTemplate(raw: "<seq>/<YY><MM><DD>")
    ]

    /// UserDefaults key the template is persisted under. Owned here so
    /// the store (reader) and AppConfig (writer) can't drift.
    static let userDefaultsKey = "AppConfig.sampleCodeTemplate"

    /// The currently configured template, read fresh from
    /// UserDefaults so a Settings change takes effect on the next
    /// sample without any wiring. Falls back to `.default`.
    static var current: SampleCodeTemplate {
        let raw = UserDefaults.standard.string(forKey: userDefaultsKey)
        guard let raw, !raw.isEmpty else { return .default }
        return SampleCodeTemplate(raw: raw)
    }

    /// Render the code for a given day + sequence.
    func format(day: Date, sequence: Int, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        func part(_ fmt: String) -> String {
            formatter.dateFormat = fmt
            return formatter.string(from: day)
        }
        // Order matters: replace <YYYY> before <YY>.
        var out = raw
        out = out.replacingOccurrences(of: "<YYYY>", with: part("yyyy"))
        out = out.replacingOccurrences(of: "<YY>", with: part("yy"))
        out = out.replacingOccurrences(of: "<MM>", with: part("MM"))
        out = out.replacingOccurrences(of: "<DD>", with: part("dd"))
        out = out.replacingOccurrences(of: "<seq>", with: "\(sequence)")
        return out
    }
}

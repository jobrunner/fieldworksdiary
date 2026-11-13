import Foundation

/// Template for the sample id. Tokens: `<YYYY> <YY> <MM> <DD>` (date),
/// `<PREFIX>`, `<seq>` (daily counter), `<n>` (running counter). The
/// sentinel raw `"-"` means "leave empty".
public struct SampleIDTemplate: Equatable, Sendable {
    public let raw: String

    public init(raw: String) {
        self.raw = raw
    }

    public static let `default` = SampleIDTemplate(raw: "<YY><MM><DD>/<seq>")
    public static let empty = SampleIDTemplate(raw: "-")

    public static let presets: [SampleIDTemplate] = [
        .default,
        SampleIDTemplate(raw: "<YYYY><MM><DD>/<seq>"),
        SampleIDTemplate(raw: "<YY><MM><DD>-<seq>"),
        SampleIDTemplate(raw: "<seq>/<YY><MM><DD>"),
        SampleIDTemplate(raw: "<PREFIX><n>"),
        .empty
    ]

    public enum Counter: Sendable { case none, daily, running }

    public var counter: Counter {
        if raw.contains("<seq>") { return .daily }
        if raw.contains("<n>") { return .running }
        return .none
    }

    /// Invalid when both counters are present.
    public var isValid: Bool {
        !(raw.contains("<seq>") && raw.contains("<n>"))
    }

    /// Renders for `day` (`yyyy-MM-dd`); `number` fills the counter token.
    public func render(day: String, prefix: String, number: Int) -> String {
        render(day: day, prefix: prefix, counterText: "\(number)")
    }

    private func render(day: String, prefix: String, counterText: String,
                        escape: (String) -> String = { $0 }) -> String
    {
        if self == .empty { return "" }
        let parts = day.split(separator: "-").map(String.init)
        let y = parts.count > 0 ? parts[0] : ""
        let m = parts.count > 1 ? parts[1] : ""
        let d = parts.count > 2 ? parts[2] : ""
        let tokens: [(String, String, Bool)] = [
            ("<YYYY>", y, true), ("<YY>", String(y.suffix(2)), true), ("<MM>", m, true),
            ("<DD>", d, true), ("<PREFIX>", prefix, true), ("<seq>", counterText, false),
            ("<n>", counterText, false)
        ]
        var out = ""
        var rest = Substring(raw)
        outer: while !rest.isEmpty {
            for (tok, val, lit) in tokens where rest.hasPrefix(tok) {
                out += lit ? escape(val) : val
                rest = rest.dropFirst(tok.count)
                continue outer
            }
            guard let ch = rest.first else { break }
            out += escape(String(ch))
            rest = rest.dropFirst()
        }
        return out
    }

    /// Next suggested id. Daily: highest matching number for that day + 1.
    /// Running: `max(lastRunning, offset) + 1`. Taken ids are skipped.
    public static func nextSuggestion(template: SampleIDTemplate, prefix: String, day: String,
                                      existingIDs: Set<String>, lastRunning: Int,
                                      offset: Int) -> (id: String, running: Int?)
    {
        if template == .empty { return ("", nil) }
        switch template.counter {
        case .none:
            return (template.render(day: day, prefix: prefix, number: 0), nil)
        case .running:
            var n = max(lastRunning, offset) + 1
            while existingIDs.contains(template.render(day: day, prefix: prefix, number: n)) {
                n += 1
            }
            return (template.render(day: day, prefix: prefix, number: n), n)
        case .daily:
            let pattern = "^" + template.render(
                day: day, prefix: prefix, counterText: "(\\d+)",
                escape: { NSRegularExpression.escapedPattern(for: $0) }
            ) + "$"
            var highest = 0
            if let re = try? NSRegularExpression(pattern: pattern) {
                for id in existingIDs {
                    let range = NSRange(id.startIndex..., in: id)
                    guard let m = re.firstMatch(in: id, range: range), m.numberOfRanges > 1,
                          let r = Range(m.range(at: 1), in: id), let v = Int(id[r]) else { continue }
                    highest = max(highest, v)
                }
            }
            var n = highest + 1
            while existingIDs.contains(template.render(day: day, prefix: prefix, number: n)) {
                n += 1
            }
            return (template.render(day: day, prefix: prefix, number: n), nil)
        }
    }
}

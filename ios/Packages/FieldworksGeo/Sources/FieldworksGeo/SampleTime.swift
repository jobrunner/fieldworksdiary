import Foundation

/// Pure time helpers for sample time windows and collecting days.
public enum SampleTime {
    private static func calendar(_ tz: TimeZone) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = tz
        return c
    }

    /// Rounds down to a multiple of `toMinutes` on the local wall clock of `tz`.
    public static func roundedDown(_ date: Date, toMinutes: Int = 15, in tz: TimeZone) -> Date {
        let cal = calendar(tz)
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        var r = c
        r.minute = (c.minute ?? 0) / toMinutes * toMinutes
        r.second = 0
        r.nanosecond = 0
        return cal.date(from: r) ?? date
    }

    /// Default time window: rounded-down creation time plus 15 minutes.
    public static func defaultWindow(createdAt: Date, in tz: TimeZone) -> (begin: Date, end: Date) {
        let begin = roundedDown(createdAt, in: tz)
        return (begin, begin.addingTimeInterval(15 * 60))
    }

    /// Collecting day as `yyyy-MM-dd`: the local calendar day after shifting
    /// back by `cutoffHour` hours.
    public static func collectingDay(_ date: Date, cutoffHour: Int, in tz: TimeZone) -> String {
        let cal = calendar(tz)
        let shifted = cal.date(byAdding: .hour, value: -cutoffHour, to: date) ?? date
        let c = cal.dateComponents([.year, .month, .day], from: shifted)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// `"Atlantic/Canary (WET)"`; identifier only if no abbreviation exists.
    public static func timezoneLabel(_ tz: TimeZone, at date: Date) -> String {
        // `abbreviation(for:)` follows the system locale ("WEZ" on de); use the
        // en_GB short names so the label is stable, falling back to it.
        let style: TimeZone.NameStyle = tz.isDaylightSavingTime(for: date) ? .shortDaylightSaving : .shortStandard
        let abbr = tz.localizedName(for: style, locale: Locale(identifier: "en_GB"))
            ?? tz.abbreviation(for: date) ?? ""
        guard !abbr.isEmpty else { return tz.identifier }
        return "\(tz.identifier) (\(abbr))"
    }
}

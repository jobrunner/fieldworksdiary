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
        // Subtract the local remainder from the Date itself: DST-safe, since
        // rebuilding from components is ambiguous in a repeated hour.
        let c = calendar(tz).dateComponents([.minute, .second, .nanosecond], from: date)
        let step = max(toMinutes, 1)
        let remainder = TimeInterval(((c.minute ?? 0) % step) * 60 + (c.second ?? 0))
            + TimeInterval(c.nanosecond ?? 0) / 1_000_000_000
        return date.addingTimeInterval(-remainder)
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

    /// 00:00 of `date`'s local calendar day in `tz`.
    public static func startOfDay(_ date: Date, in tz: TimeZone) -> Date {
        calendar(tz).startOfDay(for: date)
    }

    /// 00:00 in zone `to` of the calendar day `date` falls on in zone
    /// `from` — an all-day sample keeps its day when its zone changes.
    public static func startOfSameDay(_ date: Date, from: TimeZone, to: TimeZone) -> Date {
        let day = calendar(from).dateComponents([.year, .month, .day], from: date)
        return calendar(to).date(from: day).map { startOfDay($0, in: to) } ?? date
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

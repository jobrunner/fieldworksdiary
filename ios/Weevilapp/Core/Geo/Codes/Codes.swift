import Foundation

/// Mirrors the pure logic in `backend/internal/codes` so the iOS
/// client can hand out provisional codes while offline. The backend
/// stays the single authority — when a sync round-trip happens, the
/// server may relabel a sample if a conflict is detected.
///
/// Keep this file in lockstep with `backend/internal/codes/codes.go`.
/// CodesTests verifies the same edge cases as the Go test suite.
enum Codes {
    /// Returns the calendar day (in `t`'s timezone) that `t` counts
    /// as, given a per-user rollover hour. With cutoffHour = 5, an
    /// instant at 03:00 belongs to the previous day; 05:00 starts the
    /// new day.
    static func collectingDay(_ t: Date, cutoffHour: Int, timeZone: TimeZone) -> Date {
        let shifted = t.addingTimeInterval(-Double(cutoffHour) * 3600)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let comps = calendar.dateComponents([.year, .month, .day], from: shifted)
        return calendar.date(from: comps) ?? shifted
    }

    /// Returns the canonical sample code "YYMMDD/N".
    static func formatCode(day: Date, sequence: Int, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyMMdd"
        return "\(formatter.string(from: day))/\(sequence)"
    }

    /// Returns the YYYY-MM-DD string used as the key in
    /// sample_sequences (matches the Go server side).
    static func collectingDayKey(_ day: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: day)
    }
}

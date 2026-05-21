import Foundation

/// The shape of the Excursions-list filter. Two independent
/// dimensions:
///
///   - `date`: how to slice on time (off, absolute calendar range,
///     or seasonal cross-year range expressed as month-day pairs)
///   - `country`: optional flat country match
///
/// Filtering happens client-side against the already-hydrated local
/// store, so the same filter works offline.
struct ExcursionsFilter: Equatable {
    enum DateMode: Equatable {
        case off
        case absolute(from: Date, to: Date)
        /// Cross-year day-of-year range. `from` and `to` are days of
        /// year in [1, 366]. If from > to the range wraps around
        /// midnight Jan 1 (e.g. 349..15 for late-Dec → mid-Jan).
        case seasonal(fromDOY: Int, toDOY: Int)
    }

    var date: DateMode = .off
    var country: String? // exact match on Excursion.country

    static let none = Self()

    var isActive: Bool {
        switch date {
        case .off: break
        default: return true
        }
        if country != nil { return true }
        return false
    }

    /// Filter a list of excursions in-place. Used by the list view
    /// model.
    func apply(to items: [LocalExcursion]) -> [LocalExcursion] {
        items.filter { matches($0) }
    }

    func matches(_ excursion: LocalExcursion) -> Bool {
        switch date {
        case .off:
            break
        case let .absolute(from, to):
            guard let day = parseDay(excursion.collectingDay) else { return false }
            if day < startOfDay(from) || day > endOfDay(to) { return false }
        case let .seasonal(fromDOY, toDOY):
            guard let doy = excursion.dayOfYear else { return false }
            if fromDOY <= toDOY {
                if doy < fromDOY || doy > toDOY { return false }
            } else {
                // Wrap range, e.g. fromDOY=349, toDOY=15 ⇒ match
                // either doy >= 349 OR doy <= 15.
                if !(doy >= fromDOY || doy <= toDOY) { return false }
            }
        }
        if let country, !country.isEmpty {
            guard let excursionCountry = excursion.country, excursionCountry == country else { return false }
        }
        return true
    }

    private func parseDay(_ raw: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "Europe/Berlin")
        return formatter.date(from: raw)
    }

    private func startOfDay(_ d: Date) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Berlin") ?? .current
        return cal.startOfDay(for: d)
    }

    private func endOfDay(_ d: Date) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Berlin") ?? .current
        return cal.date(bySettingHour: 23, minute: 59, second: 59, of: d) ?? d
    }
}

/// Compute day-of-year (1..366) for a (month, day) pair in the
/// non-leap reference year 2026. Used by the seasonal-mode form to
/// turn user-picked month/day into the DOY we store.
enum DayOfYear {
    static func from(month: Int, day: Int) -> Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .gmt
        let comps = DateComponents(year: 2026, month: month, day: day)
        guard let date = cal.date(from: comps) else { return 1 }
        return cal.ordinality(of: .day, in: .year, for: date) ?? 1
    }
}

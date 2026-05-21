import SwiftUI

/// Year-style calendar showing which days have samples. Last 12
/// months render as month grids (newest first); tapping a highlighted
/// day pushes a list of that day's samples.
struct CalendarView: View {
    var body: some View {
        NavigationStack {
            CalendarScreen()
        }
    }
}

struct CalendarScreen: View {
    @EnvironmentObject var container: AppContainer

    /// Map "YYYY-MM-DD" → samples collected on that day.
    @State private var byDay: [String: [LocalSample]] = [:]
    /// The list of (year, month) tuples we render, newest first.
    @State private var months: [DateComponents] = []

    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Berlin") ?? .current
        c.locale = Locale(identifier: "de_DE")
        c.firstWeekday = 2 // Monday
        return c
    }()

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                if months.isEmpty {
                    ContentUnavailableView {
                        Label("Noch keine Sammeltage", systemImage: "calendar")
                    } description: {
                        Text("Sobald du Proben anlegst, tauchen die jeweiligen Sammeltage hier auf.")
                    }
                    .padding(.top, 40)
                } else {
                    ForEach(months, id: \.self) { monthComps in
                        MonthGrid(
                            monthComps: monthComps,
                            calendar: calendar,
                            byDay: byDay
                        )
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
        }
        .navigationTitle("Kalender")
        .task { reload() }
    }

    private func reload() {
        let samples = (try? container.store.fetchAll()) ?? []
        byDay = Dictionary(grouping: samples, by: { $0.collectingDay })

        // 12 months, newest first, starting from current month.
        let now = Date()
        let current = calendar.dateComponents([.year, .month], from: now)
        months = (0 ..< 12).compactMap { offset in
            guard let date = calendar.date(byAdding: .month, value: -offset, to: now) else { return nil }
            return calendar.dateComponents([.year, .month], from: date)
        }
        _ = current
    }
}

/// One month rendered as a 7-column grid. Days with samples show a
/// brand-coloured pill behind the number; tapping pushes a list of
/// that day's samples.
private struct MonthGrid: View {
    let monthComps: DateComponents
    let calendar: Calendar
    let byDay: [String: [LocalSample]]

    @ScaledMetric(relativeTo: .body) private var cellSize: CGFloat = 40

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
    }

    private static let dayKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let monthTitleFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "LLLL yyyy"
        return f
    }()

    private var weekdayShortNames: [String] {
        // Mon..Sun (firstWeekday already 2 = Monday).
        ["Mo", "Di", "Mi", "Do", "Fr", "Sa", "So"]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(monthTitle)
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)

            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(weekdayShortNames, id: \.self) { name in
                    Text(name)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
                ForEach(cells.indices, id: \.self) { idx in
                    cell(cells[idx])
                }
            }
        }
    }

    private var monthTitle: String {
        guard let date = calendar.date(from: monthComps) else { return "" }
        return Self.monthTitleFormatter.string(from: date).capitalized
    }

    @ViewBuilder
    private func cell(_ cell: DayCell) -> some View {
        switch cell {
        case .empty:
            Color.clear.frame(height: cellSize)
        case let .day(date, key, count):
            if count > 0 {
                NavigationLink {
                    DaySamplesScreen(dayKey: key, dayLabel: longLabel(for: date))
                } label: {
                    dayLabel(date: date, key: key, count: count, highlighted: true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(longLabel(for: date)), \(count) Probe\(count == 1 ? "" : "n")")
            } else {
                dayLabel(date: date, key: key, count: 0, highlighted: false)
                    .accessibilityLabel(longLabel(for: date))
            }
        }
    }

    private func dayLabel(date: Date, key _: String, count: Int, highlighted: Bool) -> some View {
        let day = calendar.component(.day, from: date)
        return VStack(spacing: 1) {
            Text("\(day)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(highlighted ? AppColor.brandOnPrimary : .primary)
            // Tiny count dot for days with > 1 sample so the user has
            // a hint without needing to tap in.
            if count > 1 {
                Text("\(count)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(highlighted ? AppColor.brandOnPrimary : .secondary)
            }
        }
        .frame(height: cellSize)
        .frame(maxWidth: .infinity)
        .background(
            highlighted
                ? AnyShapeStyle(AppColor.brandPrimary)
                : AnyShapeStyle(Color.clear)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// All cells for the month, padded at the start with `.empty` so
    /// the first real day lines up under its weekday column.
    private var cells: [DayCell] {
        guard let firstOfMonth = calendar.date(from: monthComps),
              let range = calendar.range(of: .day, in: .month, for: firstOfMonth)
        else {
            return []
        }
        let weekdayOfFirst = calendar.component(.weekday, from: firstOfMonth)
        // Mon = 2 in Gregorian; firstWeekday is 2 so leading-empty = (weekday - 2 + 7) % 7
        let leading = (weekdayOfFirst - calendar.firstWeekday + 7) % 7

        var out: [DayCell] = Array(repeating: .empty, count: leading)
        for day in range {
            var comps = monthComps
            comps.day = day
            guard let date = calendar.date(from: comps) else { continue }
            let key = Self.dayKeyFormatter.string(from: date)
            let count = byDay[key]?.count ?? 0
            out.append(.day(date: date, key: key, count: count))
        }
        return out
    }

    private func longLabel(for date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "EEEE, dd.MM.yyyy"
        return f.string(from: date)
    }

    private enum DayCell {
        case empty
        case day(date: Date, key: String, count: Int)
    }
}

/// Drill-down list of samples collected on a specific day.
private struct DaySamplesScreen: View {
    let dayKey: String
    let dayLabel: String

    @EnvironmentObject var container: AppContainer
    @State private var samples: [LocalSample] = []

    var body: some View {
        Group {
            if samples.isEmpty {
                ProgressView()
            } else {
                List(samples) { sample in
                    NavigationLink {
                        SampleDetailView(sampleID: sample.id)
                    } label: {
                        HStack(spacing: 12) {
                            Text(sample.backendCode ?? sample.code)
                                .font(.body.monospaced().weight(.semibold))
                            if let locality = sample.adminUnitsLocality {
                                Text(locality)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(dayLabel)
        .navigationBarTitleDisplayMode(.inline)
        .task { reload() }
    }

    private func reload() {
        let all = (try? container.store.fetchAll()) ?? []
        samples = all.filter { $0.collectingDay == dayKey }
    }
}

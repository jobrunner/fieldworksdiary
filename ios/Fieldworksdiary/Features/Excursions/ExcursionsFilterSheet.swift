import SwiftUI

struct ExcursionsFilterSheet: View {
    @Binding var filter: ExcursionsFilter
    let countries: [String]            // known set from local data
    @Environment(\.dismiss) private var dismiss

    @State private var dateModeTag: DateModeTag = .off
    @State private var absoluteFrom: Date = Date().addingTimeInterval(-30*86400)
    @State private var absoluteTo: Date = Date()
    @State private var seasonalFromMonth = 4
    @State private var seasonalFromDay = 15
    @State private var seasonalToMonth = 5
    @State private var seasonalToDay = 15
    @State private var country: String = ""

    enum DateModeTag: String, CaseIterable, Identifiable {
        case off       = "Aus"
        case absolute  = "Zeitraum"
        case seasonal  = "Saisonal"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Datum") {
                    Picker("Modus", selection: $dateModeTag) {
                        ForEach(DateModeTag.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    switch dateModeTag {
                    case .off:
                        EmptyView()
                    case .absolute:
                        DatePicker("Von", selection: $absoluteFrom, displayedComponents: .date)
                        DatePicker("Bis", selection: $absoluteTo, displayedComponents: .date)
                    case .seasonal:
                        VStack(alignment: .leading, spacing: 8) {
                            monthDayRow("Von", month: $seasonalFromMonth, day: $seasonalFromDay)
                            monthDayRow("Bis", month: $seasonalToMonth, day: $seasonalToDay)
                            Text("Jahresübergreifend: Tag-und-Monat-Bereich wird über alle Jahre angewendet. Bereich darf den Jahreswechsel umfassen.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Section("Region") {
                    if countries.isEmpty {
                        Text("Keine Länder im lokalen Datenbestand.")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Land", selection: $country) {
                            Text("Alle").tag("")
                            ForEach(countries, id: \.self) { c in
                                Text(c).tag(c)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Filter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Zurücksetzen") {
                        filter = .none
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Anwenden") {
                        apply()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear { hydrateFromFilter() }
        }
    }

    @ViewBuilder
    private func monthDayRow(_ label: String, month: Binding<Int>, day: Binding<Int>) -> some View {
        HStack {
            Text(label)
                .frame(width: 40, alignment: .leading)
            Picker("Monat", selection: month) {
                ForEach(1...12, id: \.self) { Text(germanMonth($0)).tag($0) }
            }
            .pickerStyle(.menu)
            Picker("Tag", selection: day) {
                ForEach(1...31, id: \.self) { Text("\($0)").tag($0) }
            }
            .pickerStyle(.menu)
        }
    }

    private func germanMonth(_ m: Int) -> String {
        let s = DateFormatter()
        s.locale = Locale(identifier: "de_DE")
        return s.monthSymbols[m - 1]
    }

    private func hydrateFromFilter() {
        switch filter.date {
        case .off:
            dateModeTag = .off
        case .absolute(let from, let to):
            dateModeTag = .absolute
            absoluteFrom = from
            absoluteTo = to
        case .seasonal(let fromDOY, let toDOY):
            dateModeTag = .seasonal
            let (fm, fd) = monthDay(fromDOY: fromDOY)
            seasonalFromMonth = fm
            seasonalFromDay = fd
            let (tm, td) = monthDay(fromDOY: toDOY)
            seasonalToMonth = tm
            seasonalToDay = td
        }
        country = filter.country ?? ""
    }

    private func apply() {
        switch dateModeTag {
        case .off:
            filter.date = .off
        case .absolute:
            filter.date = .absolute(from: absoluteFrom, to: absoluteTo)
        case .seasonal:
            let fromDOY = DayOfYear.from(month: seasonalFromMonth, day: seasonalFromDay)
            let toDOY = DayOfYear.from(month: seasonalToMonth, day: seasonalToDay)
            filter.date = .seasonal(fromDOY: fromDOY, toDOY: toDOY)
        }
        filter.country = country.isEmpty ? nil : country
    }

    private func monthDay(fromDOY doy: Int) -> (month: Int, day: Int) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .gmt
        // Project against 2026 (non-leap) for stable month/day.
        let jan1 = cal.date(from: DateComponents(year: 2026, month: 1, day: 1))!
        let d = cal.date(byAdding: .day, value: max(0, doy - 1), to: jan1) ?? jan1
        let comps = cal.dateComponents([.month, .day], from: d)
        return (comps.month ?? 1, comps.day ?? 1)
    }
}

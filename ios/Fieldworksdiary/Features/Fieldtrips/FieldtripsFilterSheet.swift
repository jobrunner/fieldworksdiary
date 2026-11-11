import SwiftUI

struct FieldtripsFilterSheet: View {
    @Binding var filter: FieldtripsFilter

    /// ISO codes of the countries the local samples are in.
    let countries: [String]
    @Environment(\.dismiss) private var dismiss

    @State private var dateModeTag: DateModeTag = .off
    @State private var absoluteFrom = Date().addingTimeInterval(-30 * 86400)
    @State private var absoluteTo = Date()
    @State private var seasonalFromMonth = 4
    @State private var seasonalFromDay = 15
    @State private var seasonalToMonth = 5
    @State private var seasonalToDay = 15
    @State private var country: String = ""
    @State private var placeQuery: String = ""
    @State private var requireNotes = false
    @State private var requireCoordinate = false
    @State private var fieldtripID: String = ""
    /// Label column of the seasonal month/day rows.
    @ScaledMetric(relativeTo: .body) private var monthDayLabelWidth: CGFloat = 40

    enum DateModeTag: String, CaseIterable, Identifiable {
        case off = "Aus"
        case absolute = "Zeitraum"
        case seasonal = "Saisonal"
        var id: String {
            rawValue
        }
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
                        VStack(alignment: .leading, spacing: AppSpacing.sm) {
                            monthDayRow("Von", month: $seasonalFromMonth, day: $seasonalFromDay)
                            monthDayRow("Bis", month: $seasonalToMonth, day: $seasonalToDay)
                            Text(
                                """
                                Jahresübergreifend: Tag-und-Monat-Bereich wird über alle Jahre \
                                angewendet. Bereich darf den Jahreswechsel umfassen.
                                """
                            )
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    if countries.isEmpty {
                        Text("Keine Länder in den Ortsangaben der Proben.")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Land", selection: $country) {
                            Text("Alle").tag("")
                            ForEach(countries, id: \.self) { iso in
                                Text(PlaceDisplay.countryName(iso)).tag(iso)
                            }
                        }
                    }
                    TextField("Ort", text: $placeQuery, prompt: Text("Ort enthält …"))
                        .autocorrectionDisabled()
                        .accessibilityLabel("Ort")
                        .accessibilityHint("Sucht in allen Ortsangaben der Proben, z. B. Gemeinde, Kreis oder Insel.")
                } header: {
                    Text("Region")
                } footer: {
                    Text("Eine Exkursion passt, wenn eine ihrer Proben passt.")
                }
                Section("Eigenschaften") {
                    Toggle("Nur mit Notizen", isOn: $requireNotes)
                    Toggle("Nur mit Koordinate", isOn: $requireCoordinate)
                    TextField("Exkursions-ID enthält …", text: $fieldtripID)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
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

    private func monthDayRow(_ label: String, month: Binding<Int>, day: Binding<Int>) -> some View {
        HStack {
            Text(label)
                .frame(minWidth: monthDayLabelWidth, alignment: .leading)
            Picker("Monat", selection: month) {
                ForEach(1 ... 12, id: \.self) { Text(germanMonth($0)).tag($0) }
            }
            .pickerStyle(.menu)
            Picker("Tag", selection: day) {
                ForEach(1 ... 31, id: \.self) { Text("\($0)").tag($0) }
            }
            .pickerStyle(.menu)
        }
    }

    private func germanMonth(_ month: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        return formatter.monthSymbols[month - 1]
    }

    private func hydrateFromFilter() {
        switch filter.date {
        case .off:
            dateModeTag = .off
        case let .absolute(from, to):
            dateModeTag = .absolute
            absoluteFrom = from
            absoluteTo = to
        case let .seasonal(fromDOY, toDOY):
            dateModeTag = .seasonal
            let (fm, fd) = monthDay(fromDOY: fromDOY)
            seasonalFromMonth = fm
            seasonalFromDay = fd
            let (tm, td) = monthDay(fromDOY: toDOY)
            seasonalToMonth = tm
            seasonalToDay = td
        }
        country = filter.country ?? ""
        placeQuery = filter.placeQuery ?? ""
        requireNotes = filter.requireNotes
        requireCoordinate = filter.requireCoordinate
        fieldtripID = filter.fieldtripID ?? ""
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
        let trimmedQuery = placeQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        filter.placeQuery = trimmedQuery.isEmpty ? nil : trimmedQuery
        filter.requireNotes = requireNotes
        filter.requireCoordinate = requireCoordinate
        let trimmedID = fieldtripID.trimmingCharacters(in: .whitespacesAndNewlines)
        filter.fieldtripID = trimmedID.isEmpty ? nil : trimmedID
    }

    private func monthDay(fromDOY doy: Int) -> (month: Int, day: Int) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .gmt
        // Projekt auf 2026 (non-leap) für stabile Month/Day-Berechnung.
        // Fallback `Date()` ist harmlos: `dateComponents` daraus liefert
        // immer noch valide month/day, die der Aufrufer für UI-Strings
        // einsetzt.
        let jan1 = cal.date(from: DateComponents(year: 2026, month: 1, day: 1)) ?? Date()
        let projected = cal.date(byAdding: .day, value: max(0, doy - 1), to: jan1) ?? jan1
        let comps = cal.dateComponents([.month, .day], from: projected)
        return (comps.month ?? 1, comps.day ?? 1)
    }
}

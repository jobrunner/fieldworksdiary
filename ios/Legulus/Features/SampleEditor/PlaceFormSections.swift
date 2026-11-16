import SwiftUI

/// Country picker plus one text field per place field of that
/// country. Shared by the edit form's „Ortsdaten“ group and the
/// locality override sheet; the owner keeps
/// the `PlaceForm` state. `header` titles the first section.
struct PlaceFormSections: View {
    var header = "Land"
    let countries: [(iso: String, name: String)]
    let countryISO: String
    let fields: [PlaceForm.Field]
    let onSelectCountry: (String) -> Void
    let value: (String) -> String
    let setValue: (String, String) -> Void

    /// The table's countries plus the current one if the table doesn't
    /// know it, so the picker always has a tag for its selection.
    private var pickerCountries: [(iso: String, name: String)] {
        guard !countryISO.isEmpty, !countries.contains(where: { $0.iso == countryISO }) else { return countries }
        return [(iso: countryISO, name: PlaceDisplay.countryName(countryISO))] + countries
    }

    var body: some View {
        Section {
            Picker("Land", selection: Binding(get: { countryISO }, set: onSelectCountry)) {
                Text("Bitte wählen").tag("")
                ForEach(pickerCountries, id: \.iso) { country in
                    Text(country.name).tag(country.iso)
                }
            }
        } header: {
            Text(header)
        } footer: {
            if countryISO.isEmpty {
                Text("Wähle zuerst das Land – danach erscheinen dessen Verwaltungsebenen.")
            }
        }
        if !fields.isEmpty {
            Section("Verwaltung") {
                ForEach(fields.filter { $0.tier != nil }) { field in
                    fieldRow(field)
                }
            }
            Section("Landschaft") {
                ForEach(fields.filter { $0.tier == nil }) { field in
                    fieldRow(field)
                }
            }
        }
    }

    private func fieldRow(_ field: PlaceForm.Field) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xxs) {
            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                Text(field.displayTerm)
                    .font(AppFont.subhead)
                if field.term != nil, field.term != field.genericLabel {
                    Text(field.genericLabel)
                        .font(AppFont.caption)
                        .foregroundStyle(AppColor.textSecondary)
                }
            }
            .accessibilityHidden(true)
            TextField(field.displayTerm, text: Binding(
                get: { value(field.id) },
                set: { setValue($0, field.id) }
            ))
            .autocorrectionDisabled()
            .accessibilityLabel(field.displayTerm)
            .accessibilityHint(field.term != nil && field.term != field.genericLabel ? field.genericLabel : "")
        }
    }
}

import SwiftUI

/// Sheet to correct a sample's place by hand (Phase O2): country
/// first, then only that country's levels (labelled with the local
/// term, generic type underneath) plus island / mountain range /
/// mountain, and a manual height.
struct PlaceEditorView: View {
    @StateObject private var viewModel: PlaceEditorViewModel
    @Environment(\.dismiss) private var dismiss
    /// Called after a successful save (the caller refreshes + syncs).
    let onSaved: () -> Void

    init(viewModel: PlaceEditorViewModel, onSaved: @escaping () -> Void) {
        _viewModel = StateObject(wrappedValue: viewModel)
        self.onSaved = onSaved
    }

    var body: some View {
        NavigationStack {
            Form {
                PlaceFormSections(
                    countries: viewModel.countries,
                    countryISO: viewModel.form.countryISO,
                    fields: viewModel.fields,
                    onSelectCountry: viewModel.selectCountry,
                    value: viewModel.value(for:),
                    setValue: { viewModel.setValue($0, for: $1) }
                )
                Section {
                    TextField("Höhe in Metern", text: $viewModel.elevationText)
                        .keyboardType(.decimalPad)
                    TextField("Fehler (m), optional", text: $viewModel.accuracyText)
                        .keyboardType(.decimalPad)
                    if let error = viewModel.accuracyError {
                        Text(error)
                            .font(AppFont.footnote)
                            .foregroundStyle(AppColor.danger)
                    }
                    if let error = viewModel.elevationError {
                        Text(error)
                            .font(AppFont.footnote)
                            .foregroundStyle(AppColor.danger)
                    }
                } header: {
                    Text("Höhe")
                } footer: {
                    Text("Eine eingegebene Höhe gilt als manuell und wird nicht mehr durch GPS oder Geländemodell ersetzt.")
                }
                if let saveError = viewModel.saveError {
                    Section {
                        Text(saveError)
                            .foregroundStyle(AppColor.danger)
                    }
                }
            }
            .navigationTitle("Ortsangaben bearbeiten")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Speichern") {
                        if viewModel.save() {
                            onSaved()
                            dismiss()
                        }
                    }
                    .disabled(!viewModel.canSave)
                    .accessibilityHint("Speichert die Ortsangaben nur für diese Probe als manuell.")
                }
            }
        }
    }
}

/// Country picker plus one text field per place field of that
/// country. Shared by the sample place editor, the edit form's
/// „Ortsdaten“ group and the locality override sheet; the owner keeps
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

import FieldworksGeo
import SwiftUI

/// Manual-override form for a Locality's place. Lets the user correct
/// what the backend produced — or fill a place in by hand when none
/// landed yet. Same form as the sample place editor: country first,
/// then that country's levels (local terms) plus island / mountain
/// range / mountain.
///
/// On save it PATCHes `/api/localities/:id/placemark` with the flat
/// place body, which creates (or reuses) a placemark with
/// `geocoding_source = "manual"` so the backend stops touching it.
/// `onSaved` hands the resulting placemark back so the caller can
/// refresh its cache + relation.
///
/// A "Zurücksetzen" action (only shown for an existing *manual*
/// place) DELETEs the override so the backend takes over again on the
/// next locality update.
struct PlacemarkEditSheet: View {
    let localityID: String
    let existing: LocalPlacemark?
    let onSaved: (Placemark) -> Void
    let onCleared: () -> Void

    @EnvironmentObject var container: AppContainer
    @Environment(\.dismiss) private var dismiss

    @State private var form: PlaceForm
    @State private var isSaving = false
    @State private var saveError: String?

    private let countries: [(iso: String, name: String)] = AdminLabelTable.shared.countries
        .map { (iso: $0.iso, name: PlaceDisplay.countryName($0.iso)) }
        .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }

    init(
        localityID: String,
        existing: LocalPlacemark?,
        onSaved: @escaping (Placemark) -> Void,
        onCleared: @escaping () -> Void
    ) {
        self.localityID = localityID
        self.existing = existing
        self.onSaved = onSaved
        self.onCleared = onCleared
        // Legacy rows (pre-Ortus) have no country_iso; start with their
        // ISO country so the user only fills in the levels.
        let place = existing.map { pm in
            pm.countryISO.isEmpty ? Place(countryISO: pm.country.count == 2 ? pm.country.uppercased() : "") : pm.place
        }
        _form = State(initialValue: PlaceForm(place: place?.countryISO.isEmpty == false ? place : nil))
    }

    private var isManualOverride: Bool {
        existing?.geocodingSource == "manual"
    }

    private var canSave: Bool {
        !isSaving && form.isChanged()
    }

    var body: some View {
        NavigationStack {
            Form {
                PlaceFormSections(
                    countries: countries,
                    countryISO: form.countryISO,
                    fields: form.fields(),
                    onSelectCountry: { form.selectCountry($0) },
                    value: { form.values[$0] ?? "" },
                    setValue: { form.values[$1] = $0 }
                )
                if let saveError {
                    Section {
                        Text(saveError)
                            .foregroundStyle(AppColor.danger)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if isManualOverride {
                    Section {
                        Button(role: .destructive) {
                            Task { await reset() }
                        } label: {
                            Text("Manuelle Ortsangaben zurücksetzen")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .disabled(isSaving)
                    } footer: {
                        Text("Entfernt die manuelle Korrektur; die Ortsangaben werden beim nächsten Abgleich wieder automatisch ermittelt.")
                    }
                }
            }
            .navigationTitle("Ortsangaben bearbeiten")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Abbrechen", role: .cancel) { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Speichern") {
                        Task { await save() }
                    }
                    .disabled(!canSave)
                }
            }
        }
    }

    private func save() async {
        guard let place = form.place() else { return }
        isSaving = true
        defer { isSaving = false }
        let endpoint = container.config.endpointURL
        let client = PlacemarkClient(endpoint: endpoint, auth: container.auth)
        do {
            let result = try await client.setManual(localityID: localityID, place: place)
            onSaved(result)
            dismiss()
        } catch let err as SampleClientError {
            saveError = err.errorDescription
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func reset() async {
        isSaving = true
        defer { isSaving = false }
        let endpoint = container.config.endpointURL
        let client = PlacemarkClient(endpoint: endpoint, auth: container.auth)
        do {
            try await client.clearOverride(localityID: localityID)
            onCleared()
            dismiss()
        } catch let err as SampleClientError {
            saveError = err.errorDescription
        } catch {
            saveError = error.localizedDescription
        }
    }
}

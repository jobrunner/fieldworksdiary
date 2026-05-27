import SwiftUI

/// Manual-override form for a Locality's address (Placemark). Lets the
/// user correct what the backend auto-geocoder produced — or fill an
/// address in by hand when no geocode landed yet.
///
/// On save it PATCHes `/api/localities/:id/placemark`, which creates
/// (or reuses) a placemark with `geocoding_source = "manual"` so the
/// auto-geocode hook stops touching it. `onSaved` hands the resulting
/// placemark back so the caller can refresh its cache + relation.
///
/// A "Zurücksetzen" action (only shown for an existing *manual*
/// placemark) DELETEs the override so the auto-geocoder takes over
/// again on the next locality update.
struct PlacemarkEditSheet: View {
    let localityID: String
    let existing: LocalPlacemark?
    let onSaved: (Placemark) -> Void
    let onCleared: () -> Void

    @EnvironmentObject var container: AppContainer
    @Environment(\.dismiss) private var dismiss

    @State private var fields: PlacemarkOverrideFields
    @State private var isSaving = false
    @State private var saveError: String?

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
        _fields = State(initialValue: existing.map(PlacemarkOverrideFields.init(from:))
            ?? PlacemarkOverrideFields())
    }

    private var isManualOverride: Bool {
        existing?.geocodingSource == "manual"
    }

    private var countryValid: Bool {
        fields.country.trimmingCharacters(in: .whitespaces).count == 2
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Adresse") {
                    TextField("Name (z. B. NSG Schwarze Berge)", text: $fields.name)
                        .autocorrectionDisabled()
                    TextField("Straße", text: $fields.thoroughfare)
                    TextField("PLZ", text: $fields.postalCode)
                        .keyboardType(.numbersAndPunctuation)
                    TextField("Ort", text: $fields.locality)
                    TextField("Ortsteil", text: $fields.subLocality)
                }
                Section {
                    TextField("z. B. DE", text: $fields.country)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    TextField("Bundesland / Region", text: $fields.administrativeArea)
                    TextField("Kreis / Bezirk", text: $fields.subAdministrativeArea)
                } header: {
                    Text("Land & Verwaltung")
                } footer: {
                    Text("Land ist Pflicht: ISO-3166-1 alpha-2, z. B. DE, AT, CH.")
                }
                if let saveError {
                    Section {
                        Text(saveError)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if isManualOverride {
                    Section {
                        Button(role: .destructive) {
                            Task { await reset() }
                        } label: {
                            Text("Manuelle Adresse zurücksetzen")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .disabled(isSaving)
                    } footer: {
                        Text("Entfernt die manuelle Korrektur; die Adresse wird beim nächsten Abgleich wieder automatisch ermittelt.")
                    }
                }
            }
            .navigationTitle("Adresse bearbeiten")
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
                    .disabled(!countryValid || isSaving)
                }
            }
        }
    }

    private func save() async {
        guard countryValid else { return }
        isSaving = true
        defer { isSaving = false }
        let endpoint = container.config.endpointURL
        let client = PlacemarkClient(endpoint: endpoint, auth: container.auth)
        do {
            let result = try await client.setManual(localityID: localityID, fields: fields)
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

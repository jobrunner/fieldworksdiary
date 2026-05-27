import CoreLocation
import SwiftUI

/// Create- and edit-form for localities. The same view is reused for
/// both — pass `editing: nil` to create.
struct LocalityEditView: View {
    let editing: LocalLocality?

    @EnvironmentObject var container: AppContainer
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var notes: String = ""
    @State private var coordinate: CLLocationCoordinate2D?
    @State private var radiusMeters: Double = 100
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var showingPicker = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("z. B. NSG Schwarze Berge", text: $name)
                        .autocorrectionDisabled()
                }
                Section {
                    if let c = coordinate {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(String(format: "%.6f, %.6f", c.latitude, c.longitude))
                                .font(.body.monospacedDigit())
                            Button("Auf Karte ändern") { showingPicker = true }
                        }
                    } else {
                        Button("Koordinate auf Karte setzen") { showingPicker = true }
                    }
                } header: {
                    Text("Centroid")
                } footer: {
                    Text("Tippe auf die Karte, um den Mittelpunkt des Fundorts zu wählen.")
                }
                Section("Radius") {
                    HStack {
                        Slider(value: $radiusMeters, in: 25 ... 5000, step: 25)
                        Text("\(Int(radiusMeters)) m")
                            .font(.body.monospacedDigit())
                            .frame(width: 80, alignment: .trailing)
                    }
                }
                Section("Notizen") {
                    TextField("optional", text: $notes, axis: .vertical)
                        .lineLimit(3 ... 8)
                }
                if let saveError {
                    Section {
                        Text(saveError).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(editing == nil ? "Neuer Fundort" : "Fundort bearbeiten")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Abbrechen", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(editing == nil ? "Anlegen" : "Speichern") {
                        Task { await save() }
                    }
                    .disabled(saveDisabled || isSaving)
                }
            }
            .sheet(isPresented: $showingPicker) {
                CoordinatePickerView(selected: $coordinate)
            }
            .onAppear { applyEditing() }
        }
    }

    private var saveDisabled: Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || coordinate == nil
    }

    private func applyEditing() {
        guard let existing = editing else { return }
        name = existing.name
        notes = existing.notes
        if let lat = existing.centroidLat, let lon = existing.centroidLon {
            coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
        radiusMeters = existing.radiusM ?? 100
    }

    private func save() async {
        guard let coord = coordinate else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        isSaving = true
        defer { isSaving = false }

        let endpoint = container.config.endpointURL
        let client = LocalityClient(endpoint: endpoint, auth: container.auth)
        do {
            let input = LocalityInput(
                name: trimmedName,
                latitude: coord.latitude,
                longitude: coord.longitude,
                radiusM: radiusMeters,
                notes: notes
            )
            let result: Locality
            if let editing {
                result = try await client.update(id: editing.id, input: input)
            } else {
                result = try await client.create(input)
            }
            try container.localitiesStore.upsertOne(result)
            dismiss()
        } catch let err as SampleClientError {
            saveError = err.errorDescription
        } catch {
            saveError = error.localizedDescription
        }
    }
}

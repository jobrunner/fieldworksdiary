import SwiftUI

struct DeterminationEditView: View {
    enum Mode: Equatable {
        case create(sampleID: String)
        case edit(existing: Determination)
    }

    let mode: Mode
    let onSaved: (Determination) -> Void
    let onDeleted: (() -> Void)?

    @EnvironmentObject var container: AppContainer
    @Environment(\.dismiss) private var dismiss

    @State private var speciesText: String = ""
    @State private var kind: DeterminationKind = .det
    @State private var person: Person?
    @State private var determinedOn: Date = .init()
    @State private var notes: String = ""
    @State private var saving = false
    @State private var error: String?
    @State private var presentingPersonPicker = false
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Art") {
                    TextField("z. B. Otiorhynchus ligustici", text: $speciesText)
                        .autocorrectionDisabled()
                }
                Section("Art der Aussage") {
                    Picker("Art der Aussage", selection: $kind) {
                        ForEach(DeterminationKind.allCases) { k in
                            VStack(alignment: .leading) {
                                Text(k.labelShort).font(.body.monospaced())
                                Text(k.labelLong)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            .tag(k)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                Section("Person") {
                    Button {
                        presentingPersonPicker = true
                    } label: {
                        if let person {
                            HStack {
                                Image(systemName: "person.crop.circle")
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading) {
                                    Text(person.fullName).font(.body)
                                    if !person.abbreviation.isEmpty {
                                        Text(person.abbreviation)
                                            .font(.footnote.monospaced())
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .accessibilityHidden(true)
                            }
                        } else {
                            Label("Person wählen oder anlegen", systemImage: "person.crop.circle.badge.questionmark")
                        }
                    }
                    .buttonStyle(.plain)
                }
                Section("Datum") {
                    DatePicker("Bestimmt am", selection: $determinedOn, displayedComponents: .date)
                }
                Section("Notizen") {
                    TextField("optional", text: $notes, axis: .vertical)
                        .lineLimit(2 ... 6)
                }
                if case .edit = mode, onDeleted != nil {
                    Section {
                        Button(role: .destructive) {
                            confirmDelete = true
                        } label: {
                            Label("Bestimmung löschen", systemImage: "trash")
                        }
                    }
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Abbrechen", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(saveLabel) { Task { await save() } }
                        .disabled(speciesText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving)
                        .fontWeight(.semibold)
                }
            }
            .sheet(isPresented: $presentingPersonPicker) {
                PersonPickerView(selected: $person)
            }
            .confirmationDialog(
                "Bestimmung wirklich löschen?",
                isPresented: $confirmDelete,
                titleVisibility: .visible
            ) {
                Button("Löschen", role: .destructive) {
                    Task { await deleteDetermination() }
                }
            }
            .onAppear { applyMode() }
        }
    }

    private var navigationTitle: String {
        switch mode {
        case .create: "Neue Bestimmung"
        case .edit: "Bestimmung bearbeiten"
        }
    }

    private var saveLabel: String {
        switch mode {
        case .create: "Anlegen"
        case .edit: "Speichern"
        }
    }

    private func applyMode() {
        switch mode {
        case .create:
            break
        case let .edit(existing):
            speciesText = existing.speciesText
            kind = existing.kind
            determinedOn = existing.determinedOn ?? Date()
            notes = existing.notes
            if let personID = existing.person {
                Task {
                    if let p = try? await PersonClient(endpoint: container.config.endpointURL, auth: container.auth).listAll()
                        .first(where: { $0.id == personID })
                    {
                        person = p
                    }
                }
            }
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        let client = DeterminationClient(endpoint: container.config.endpointURL, auth: container.auth)
        do {
            let trimmedSpecies = speciesText.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
            let input = DeterminationInput(
                speciesText: trimmedSpecies,
                kind: kind,
                person: person?.id,
                determinedOn: determinedOn,
                notes: trimmedNotes
            )
            let result: Determination
            switch mode {
            case let .create(sampleID):
                result = try await client.create(sample: sampleID, input: input)
            case let .edit(existing):
                result = try await client.update(id: existing.id, input: input)
            }
            onSaved(result)
            dismiss()
        } catch let err as SampleClientError {
            error = err.errorDescription
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func deleteDetermination() async {
        guard case let .edit(existing) = mode else { return }
        saving = true
        defer { saving = false }
        do {
            try await DeterminationClient(endpoint: container.config.endpointURL, auth: container.auth).delete(id: existing.id)
            onDeleted?()
            dismiss()
        } catch let err as SampleClientError {
            error = err.errorDescription
        } catch {
            self.error = error.localizedDescription
        }
    }
}

import SwiftUI

/// Searchable list of people, with a "Neu anlegen" row at the top.
/// Returns the selected person via the binding. Used from
/// DeterminationEditView.
struct PersonPickerView: View {
    @Binding var selected: Person?
    @EnvironmentObject var container: AppContainer
    @Environment(\.dismiss) private var dismiss

    @State private var people: [Person] = []
    @State private var query: String = ""
    @State private var loading = false
    @State private var loadError: String?
    @State private var presentingNew = false

    private var filtered: [Person] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty { return people }
        return people.filter {
            $0.fullName.lowercased().contains(q) ||
            $0.abbreviation.lowercased().contains(q)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        presentingNew = true
                    } label: {
                        Label("Neue Person anlegen", systemImage: "person.crop.circle.badge.plus")
                    }
                }
                if loading {
                    Section { ProgressView() }
                }
                if let loadError {
                    Section { Text(loadError).foregroundStyle(.red) }
                }
                Section("Bekannte Personen") {
                    if filtered.isEmpty {
                        Text(query.isEmpty ? "Keine Personen vorhanden." : "Keine Treffer.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(filtered) { person in
                            Button {
                                selected = person
                                dismiss()
                            } label: {
                                row(for: person)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Name oder Kürzel")
            .navigationTitle("Person wählen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Abbrechen", role: .cancel) { dismiss() }
                }
            }
            .task { await reload() }
            .sheet(isPresented: $presentingNew) {
                NewPersonSheet { created in
                    people.append(created)
                    people.sort { $0.fullName < $1.fullName }
                    selected = created
                    dismiss()
                }
            }
        }
    }

    @ViewBuilder
    private func row(for p: Person) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading) {
                Text(p.fullName.isEmpty ? "(ohne Namen)" : p.fullName)
                if !p.abbreviation.isEmpty {
                    Text(p.abbreviation)
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if selected?.id == p.id {
                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
            }
        }
    }

    private func reload() async {
        loading = true
        defer { loading = false }
        do {
            people = try await PersonClient(endpoint: container.config.endpointURL, auth: container.auth).listAll()
            loadError = nil
        } catch let err as SampleClientError {
            loadError = err.errorDescription
        } catch {
            loadError = error.localizedDescription
        }
    }
}

private struct NewPersonSheet: View {
    let onCreated: (Person) -> Void
    @EnvironmentObject var container: AppContainer
    @Environment(\.dismiss) private var dismiss

    @State private var fullName = ""
    @State private var abbreviation = ""
    @State private var email = ""
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Person") {
                    TextField("Voller Name", text: $fullName)
                        .autocorrectionDisabled()
                    TextField("Kürzel (z. B. M. Müller)", text: $abbreviation)
                        .autocorrectionDisabled()
                    TextField("E-Mail (optional)", text: $email)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Neue Person")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Abbrechen", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Anlegen") { Task { await save() } }
                        .disabled(fullName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving)
                        .fontWeight(.semibold)
                }
            }
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            let p = try await PersonClient(endpoint: container.config.endpointURL, auth: container.auth).create(
                fullName: fullName.trimmingCharacters(in: .whitespacesAndNewlines),
                abbreviation: abbreviation.trimmingCharacters(in: .whitespacesAndNewlines),
                email: email.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            onCreated(p)
            dismiss()
        } catch let err as SampleClientError {
            error = err.errorDescription
        } catch {
            self.error = error.localizedDescription
        }
    }
}

import FieldworksGeo
import SwiftUI

/// Nachtrage-Dialog („Probe nachtragen → Mit Koordinate“): Sample-ID,
/// Koordinatensystem and the fields of that system. „Anlegen“ asks
/// Ortus; on success `onCreated` gets the new sample and the caller
/// closes the sheet. A failure stays in the dialog with its message.
/// „Abbrechen“ (also while Ortus is asked) creates nothing.
struct RetrospectiveCoordinateDialog: View {
    @ObservedObject var viewModel: RetrospectiveCoordinateViewModel
    let onCreated: (InstantSampleCreator.Created) -> Void
    let onCancel: () -> Void

    @State private var submitTask: Task<Void, Never>?
    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case code, first, second }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Sample-ID", text: $viewModel.code)
                        .font(AppFont.code)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .code)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .first }
                } header: {
                    Text("Sample-ID")
                }

                Section {
                    Picker("Koordinatensystem", selection: $viewModel.system) {
                        ForEach(InputCoordinateSystem.allCases) { system in
                            Text(system.title).tag(system)
                        }
                    }
                    .pickerStyle(.navigationLink)

                    coordinateField(
                        label: viewModel.system.firstLabel,
                        text: $viewModel.first,
                        field: .first
                    )
                    if let secondLabel = viewModel.system.secondLabel {
                        coordinateField(label: secondLabel, text: $viewModel.second, field: .second)
                    }
                } header: {
                    Text("Koordinate")
                }

                if let error = viewModel.errorMessage {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(AppColor.danger)
                            .font(AppFont.subhead)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Fehler: \(error)")
                }
            }
            .disabled(viewModel.isSubmitting)
            .navigationTitle("Probe nachtragen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen", action: cancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if viewModel.isSubmitting {
                        ProgressView()
                            .accessibilityLabel("Ortus wird abgefragt")
                    } else {
                        Button("Anlegen", action: submit)
                            .accessibilityHint("Rechnet die Koordinate über Ortus um und legt die Probe an.")
                    }
                }
            }
            .onChange(of: viewModel.errorMessage) { _, message in
                if let message {
                    AccessibilityNotification.Announcement(message).post()
                }
            }
        }
        .interactiveDismissDisabled(viewModel.isSubmitting)
        .onDisappear { submitTask?.cancel() }
    }

    private func coordinateField(label: String, text: Binding<String>, field: Field) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xxs) {
            Text(label)
                .font(AppFont.subhead)
                .foregroundStyle(AppColor.textSecondary)
                .accessibilityHidden(true)
            TextField(viewModel.system.placeholder, text: text)
                .font(AppFont.body.monospacedDigit())
                .keyboardType(viewModel.system == .mgrs ? .asciiCapable : .numbersAndPunctuation)
                .textInputAutocapitalization(viewModel.system == .mgrs ? .characters : .never)
                .autocorrectionDisabled()
                .focused($focusedField, equals: field)
                .submitLabel(field == .first && viewModel.system.secondLabel != nil ? .next : .done)
                .onSubmit {
                    if field == .first, viewModel.system.secondLabel != nil {
                        focusedField = .second
                    } else {
                        submit()
                    }
                }
                .accessibilityLabel(label)
        }
    }

    private func submit() {
        guard submitTask == nil else { return }
        focusedField = nil
        submitTask = Task {
            let id = await viewModel.submit()
            submitTask = nil
            if id != nil, let created = viewModel.created {
                onCreated(created)
            }
        }
    }

    private func cancel() {
        submitTask?.cancel()
        submitTask = nil
        onCancel()
    }
}

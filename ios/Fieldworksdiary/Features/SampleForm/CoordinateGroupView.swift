import CoreLocation
import FieldworksGeo
import SwiftUI

/// Group „Koordinate“ of the edit form: „Koordinatensystem“, the fields
/// of that system, height, horizontal and vertical error, „Auf Karte
/// zeigen“ and „Ortsdaten neu abfragen“. A typed position is taken over
/// only through those two actions; errors stay inline in the group.
struct CoordinateGroupView: View {
    @ObservedObject var viewModel: SampleFormViewModel
    /// Height and vertical error (shared with the „Ortsdaten“ group).
    @ObservedObject var place: PlaceEditorViewModel

    @State private var showingMap = false
    @State private var pickedOnMap: CLLocationCoordinate2D?
    @State private var queryTask: Task<Void, Never>?
    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case first, second, elevation, horizontal, vertical }

    var body: some View {
        Section {
            Picker("Koordinatensystem", selection: $viewModel.system) {
                ForEach(InputCoordinateSystem.allCases) { system in
                    Text(system.title).tag(system)
                }
            }
            .pickerStyle(.navigationLink)

            labeledField(
                viewModel.system.firstLabel,
                placeholder: viewModel.system.placeholder,
                text: $viewModel.first,
                field: .first,
                keyboard: viewModel.system == .mgrs ? .asciiCapable : .numbersAndPunctuation
            )
            if let secondLabel = viewModel.system.secondLabel {
                labeledField(secondLabel, placeholder: "", text: $viewModel.second, field: .second,
                             keyboard: .numbersAndPunctuation)
            }

            labeledField("Höhe (m)", placeholder: "", text: $place.elevationText, field: .elevation,
                         keyboard: .decimalPad)
            inlineError(place.elevationError)
            labeledField("Horizontale Genauigkeit (m)", placeholder: "", text: $viewModel.horizontalAccuracyText,
                         field: .horizontal, keyboard: .decimalPad)
            inlineError(viewModel.horizontalAccuracyError)
            labeledField("Vertikale Genauigkeit (m)", placeholder: "", text: $place.accuracyText,
                         field: .vertical, keyboard: .decimalPad)
            inlineError(place.accuracyError)

            if viewModel.mapCenter != nil {
                Button {
                    focusedField = nil
                    showingMap = true
                } label: {
                    Label("Auf Karte zeigen", systemImage: "map")
                }
                .accessibilityHint("Öffnet die Karte; ein gesetzter Punkt wird als Koordinate übernommen.")
            }
            Button(action: query) {
                HStack(spacing: AppSpacing.sm) {
                    Label("Ortsdaten neu abfragen", systemImage: "arrow.clockwise")
                    if viewModel.isQuerying {
                        Spacer(minLength: AppSpacing.sm)
                        ProgressView()
                            .accessibilityHidden(true)
                    }
                }
            }
            .disabled(viewModel.isQuerying)
            .accessibilityValue(viewModel.isQuerying ? "Ortus wird abgefragt" : "")
            .accessibilityHint("Rechnet die Eingabe über Ortus um, übernimmt sie und aktualisiert Ortsdaten, Zeitzone und Höhe.")

            if let error = viewModel.coordinateError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(AppFont.subhead)
                    .foregroundStyle(AppColor.danger)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Fehler: \(error)")
            }
        } header: {
            Text("Koordinate")
        } footer: {
            Text("Gespeichert wird WGS 84. Eine Eingabe gilt erst nach „Ortsdaten neu abfragen“ oder über die Karte. Eine eingegebene Höhe gilt als manuell.")
        }
        .onChange(of: viewModel.coordinateError) { _, message in
            if let message {
                AccessibilityNotification.Announcement(message).post()
            }
        }
        .onDisappear { queryTask?.cancel() }
        .sheet(isPresented: $showingMap, onDismiss: {
            guard let picked = pickedOnMap else { return }
            pickedOnMap = nil
            viewModel.mapPicked(latitude: picked.latitude, longitude: picked.longitude)
        }) {
            CoordinatePickerView(selected: Binding(
                get: { pickedOnMap ?? viewModel.mapCenter },
                set: { pickedOnMap = $0 }
            ))
        }
    }

    private func query() {
        guard queryTask == nil else { return }
        focusedField = nil
        queryTask = Task {
            await viewModel.queryOrtus()
            queryTask = nil
        }
    }

    /// Label above a text field (the field's placeholder stays free for
    /// a format example); VoiceOver reads the label as the field's name.
    private func labeledField(
        _ label: String, placeholder: String, text: Binding<String>, field: Field, keyboard: UIKeyboardType
    ) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xxs) {
            Text(label)
                .font(AppFont.subhead)
                .foregroundStyle(AppColor.textSecondary)
                .accessibilityHidden(true)
            TextField(placeholder, text: text)
                .font(AppFont.body.monospacedDigit())
                .keyboardType(keyboard)
                .textInputAutocapitalization(viewModel.system == .mgrs && field == .first ? .characters : .never)
                .autocorrectionDisabled()
                .focused($focusedField, equals: field)
                .accessibilityLabel(label)
        }
    }

    @ViewBuilder
    private func inlineError(_ message: String?) -> some View {
        if let message {
            Text(message)
                .font(AppFont.footnote)
                .foregroundStyle(AppColor.danger)
        }
    }
}

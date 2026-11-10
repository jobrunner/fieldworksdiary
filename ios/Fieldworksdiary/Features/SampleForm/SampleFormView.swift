import SwiftUI

/// Edit form („Bearbeiten“) of a saved sample (Phase N), pushed from the
/// sample view: groups „Koordinate“, „Zeit“, „Ortsdaten“.
///
/// Saving like the sample editor (Phase E): no „Fertig“ button. The
/// custom back button saves (`SampleFormViewModel.finishEditing()`);
/// going to the background saves without dialogs; `onDisappear` is the
/// last-resort save. The swipe-back is off (`interactivePopDisabled()`)
/// so leaving with a typed, not taken-over position always reaches the
/// „Koordinate verwerfen?“ question.
struct SampleFormView: View {
    /// Local id of the persisted sample.
    let sampleID: String

    @EnvironmentObject var container: AppContainer

    var body: some View {
        SampleFormContent(viewModel: SampleFormViewModel(
            sampleID: sampleID,
            store: container.store,
            localitiesStore: container.localitiesStore,
            placemarkStore: container.placemarksStore,
            mutationsStore: container.mutations,
            sync: container.sync,
            ortus: OrtusClient.make(endpoint: container.config.ortusEndpointURL),
            resolver: container.makeLocationResolver()
        ))
    }
}

private struct SampleFormContent: View {
    @StateObject private var viewModel: SampleFormViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    init(viewModel: @autoclosure @escaping () -> SampleFormViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel())
    }

    var body: some View {
        Group {
            if viewModel.sampleExists {
                form
            } else {
                ContentUnavailableView("Probe nicht gefunden", systemImage: "questionmark.folder")
            }
        }
        .navigationTitle("Bearbeiten")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .interactivePopDisabled()
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: goBack) {
                    HStack(spacing: AppSpacing.xs) {
                        Image(systemName: "chevron.backward")
                            .accessibilityHidden(true)
                        Text("Zurück")
                    }
                    .contentShape(Rectangle())
                }
                .accessibilityLabel("Zurück")
                .accessibilityHint("Speichert die Änderungen.")
            }
        }
        .task { viewModel.observeRow() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { viewModel.saveEdits() }
        }
        .onDisappear {
            if !viewModel.finished { viewModel.saveEdits() }
        }
        .retakePlaceDialog(
            isPresented: $viewModel.askRetakePlace,
            onAnswer: { viewModel.applyCorrection(keepManualPlace: $0) },
            onCancel: { viewModel.cancelCorrection() }
        )
        .alert("Koordinate verwerfen?", isPresented: $viewModel.askDiscardCoordinate) {
            Button("Verwerfen", role: .destructive) {
                viewModel.discardCoordinateAndFinish()
                dismiss()
            }
            Button("Weiter bearbeiten", role: .cancel) { viewModel.keepEditing() }
        } message: {
            Text("Die eingegebene Koordinate wurde nicht übernommen. Übernehmen kannst du sie mit „Ortsdaten neu abfragen“ oder über die Karte. Zeit und Ortsdaten sind gespeichert.")
        }
    }

    private var form: some View {
        Form {
            if let place = viewModel.place {
                CoordinateGroupView(viewModel: viewModel, place: place)
            }
            if let time = viewModel.time {
                TimeGroupView(
                    begin: time.begin,
                    end: time.end,
                    timezoneID: time.timezoneID,
                    timeZone: time.timeZone,
                    isAllDay: time.isAllDay,
                    onBegin: viewModel.setBeginDate,
                    onEnd: viewModel.setEndDate,
                    onTimezone: viewModel.setTimezone,
                    onAllDay: viewModel.setAllDay
                )
            }
            if let place = viewModel.place {
                PlaceGroupView(place: place)
            }
            if let error = viewModel.saveError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(AppColor.danger)
                }
            }
        }
    }

    private func goBack() {
        if viewModel.finishEditing() { dismiss() }
    }
}

/// Group „Ortsdaten“: the manual place fields of `PlaceEditorView`
/// (country first, then its levels), saved with the form.
private struct PlaceGroupView: View {
    @ObservedObject var place: PlaceEditorViewModel

    var body: some View {
        PlaceFormSections(
            header: "Ortsdaten",
            countries: place.countries,
            countryISO: place.form.countryISO,
            fields: place.fields,
            onSelectCountry: place.selectCountry,
            value: place.value(for:),
            setValue: { place.setValue($0, for: $1) }
        )
    }
}

#Preview {
    NavigationStack {
        SampleFormView(sampleID: "preview")
    }
    .environmentObject(AppContainer())
}

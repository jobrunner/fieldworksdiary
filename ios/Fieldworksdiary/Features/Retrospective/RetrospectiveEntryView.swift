import FieldworksGeo
import PhotosUI
import SwiftUI

extension View {
    /// „Probe nachtragen“: while `isPresented`, a choice between „Mit
    /// Koordinate“ (Nachtrage-Dialog) and „Aus Foto“ (one photo from
    /// the library) is shown. `onCreated` gets the new sample; the
    /// caller pushes `SampleEditorView(sampleID:isNew:true)` like for
    /// the instant creation.
    func retrospectiveEntry(
        isPresented: Binding<Bool>,
        onCreated: @escaping (InstantSampleCreator.Created) -> Void
    ) -> some View {
        modifier(RetrospectiveEntryView(isPresented: isPresented, onCreated: onCreated))
    }
}

/// Auswahl „Mit Koordinate“ · „Aus Foto“ plus everything the two ways
/// present: the coordinate dialog sheet, the photo picker (no photo
/// library permission needed) and a progress overlay while a photo is
/// read and Ortus is asked.
struct RetrospectiveEntryView: ViewModifier {
    @Binding var isPresented: Bool
    let onCreated: (InstantSampleCreator.Created) -> Void

    @EnvironmentObject private var container: AppContainer

    /// Identity wrapper so a new dialog (e.g. the photo fallback after a
    /// plain one) always gets a fresh sheet.
    private struct DialogState: Identifiable {
        let id = UUID()
        let viewModel: RetrospectiveCoordinateViewModel
    }

    @State private var dialog: DialogState?
    /// Sample created in the dialog; handed over once the sheet is gone
    /// so the push doesn't race the dismissal.
    @State private var createdInDialog: InstantSampleCreator.Created?
    @State private var showingPhotoPicker = false
    @State private var pickedItem: PhotosPickerItem?
    @State private var importTask: Task<Void, Never>?
    @State private var importError: String?

    func body(content: Content) -> some View {
        content
            .confirmationDialog("Probe nachtragen", isPresented: $isPresented, titleVisibility: .visible) {
                Button("Mit Koordinate") { openDialog() }
                Button("Aus Foto") { showingPhotoPicker = true }
                Button("Abbrechen", role: .cancel) {}
            }
            .sheet(item: $dialog, onDismiss: {
                if let created = createdInDialog {
                    createdInDialog = nil
                    onCreated(created)
                }
            }) { state in
                RetrospectiveCoordinateDialog(
                    viewModel: state.viewModel,
                    onCreated: { created in
                        createdInDialog = created
                        dialog = nil
                    },
                    onCancel: { dialog = nil }
                )
            }
            .photosPicker(
                isPresented: $showingPhotoPicker,
                selection: $pickedItem,
                matching: .images,
                preferredItemEncoding: .current
            )
            .onChange(of: pickedItem) { _, item in
                guard let item else { return }
                pickedItem = nil
                importPhoto(item)
            }
            .overlay {
                if importTask != nil {
                    importProgress
                }
            }
            .alert(
                "Fehler",
                isPresented: Binding(
                    get: { importError != nil },
                    set: { if !$0 { importError = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importError ?? "")
            }
    }

    private var importProgress: some View {
        ZStack {
            AppColor.surfaceGrouped.opacity(0.6)
                .ignoresSafeArea()
                .accessibilityHidden(true)
            VStack(spacing: AppSpacing.md) {
                ProgressView()
                Text("Foto wird gelesen …")
                    .font(AppFont.subhead)
                Button("Abbrechen", role: .cancel) {
                    importTask?.cancel()
                    importTask = nil
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            .padding(AppSpacing.xl)
            .background(AppColor.surface, in: RoundedRectangle(cornerRadius: AppRadius.md))
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
        }
    }

    // MARK: - actions

    private func openDialog(
        prefill: CoordinateInput? = nil,
        error: String? = nil,
        photo: RetrospectiveCoordinateViewModel.PendingPhoto? = nil
    ) {
        dialog = DialogState(viewModel: RetrospectiveCoordinateViewModel(
            ortus: makeOrtus(),
            creator: makeCreator(),
            displayFormat: container.config.coordinateDisplayFormat,
            prefill: prefill,
            initialError: error,
            photo: photo
        ))
    }

    private func importPhoto(_ item: PhotosPickerItem) {
        importTask?.cancel()
        let importer = RetrospectivePhotoImporter(ortus: makeOrtus(), creator: makeCreator())
        importTask = Task {
            defer { importTask = nil }
            do {
                // The original file keeps GPS and capture time.
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    importError = "Das Foto konnte nicht geladen werden."
                    return
                }
                try Task.checkCancellation()
                switch try await importer.importPhoto(data) {
                case let .created(created):
                    onCreated(created)
                case let .needsDialog(seed):
                    openDialog(prefill: seed.input, error: seed.errorMessage, photo: seed.photo)
                }
            } catch is CancellationError {
                return
            } catch {
                if RetrospectiveCoordinateViewModel.isCancellation(error) { return }
                Log.ui.error("photo import failed: \(error.localizedDescription)")
                importError = "Das Foto konnte nicht übernommen werden."
            }
        }
    }

    private func makeOrtus() -> OrtusQuerying? {
        OrtusClient.make(endpoint: container.config.ortusEndpointURL)
    }

    private func makeCreator() -> RetrospectiveSampleCreator {
        let store = container.store
        return RetrospectiveSampleCreator(
            store: store,
            photoStore: container.photos,
            mutationsStore: container.mutations,
            resolver: container.makeLocationResolver(),
            sync: container.sync,
            deviceZone: { store.timeZone },
            now: Date.init
        )
    }
}

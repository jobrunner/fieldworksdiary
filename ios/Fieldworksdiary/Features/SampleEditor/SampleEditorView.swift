import CoreLocation
import FieldworksGeo
import SwiftUI
import UIKit

/// The sample editor (Phase 14c). Replaces the old `AddSampleView`
/// with a two-section layout inspired by the legacy app:
///
///   ┌─────────────────────────────────────────────┐
///   │  Code (editable)                            │
///   │  Notizen (editable)                         │
///   │  Foto-Strip                                 │
///   ├─────────────────────────────────────────────┤
///   │  STANDORT UND ZEIT                          │
///   │   GPS icon + coords + accuracy + altitude   │
///   │   Ortsangaben (Landesbegriffe, MTB)         │
///   │   Sammeltag / Exkursion                     │
///   │   Sonne / Mond                              │
///   ├─────────────────────────────────────────────┤
///   │  [ static map snippet with pin ]            │
///   └─────────────────────────────────────────────┘
///
/// The top stays editable through the entire flow; the bottom auto-
/// fills as GPS lands + the sync round-trip enriches the row.
struct SampleEditorView: View {
    /// nil ⇒ new sample (GPS starts, fields editable).
    /// non-nil ⇒ existing sample is adopted on init.
    let sampleID: String?

    @EnvironmentObject var container: AppContainer

    var body: some View {
        SampleEditorContent(
            sampleID: sampleID,
            store: container.store,
            photoStore: container.photos,
            fieldtripStore: container.fieldtrips,
            localitiesStore: container.localitiesStore,
            mutationsStore: container.mutations,
            sync: container.sync,
            locationResolver: container.makeLocationResolver(),
            placemarkStore: container.placemarksStore
        )
    }
}

private struct SampleEditorContent: View {
    @StateObject private var viewModel: SampleEditorViewModel
    @EnvironmentObject private var container: AppContainer
    @Environment(\.dismiss) private var dismiss

    @State private var showingCamera = false
    @FocusState private var notesFocused: Bool
    @FocusState private var codeFocused: Bool

    @State private var showingCoordinatePicker = false
    @State private var showingTimeZonePicker = false
    @State private var showingCorrectionPicker = false
    /// Coordinate picked on the correction map. Handed to the view
    /// model only after the sheet is gone (`onDismiss`), so the
    /// „Ortsangaben neu übernehmen?“ dialog isn't requested while the
    /// sheet is still presented (SwiftUI drops it then).
    @State private var pickedCorrection: CLLocationCoordinate2D?
    @State private var showingDiscardConfirm = false
    @State private var placeEditor: PlaceEditorViewModel?

    /// Width of the leading icon column in the location rows; grows
    /// with Dynamic Type so the icons keep their proportion.
    @ScaledMetric(relativeTo: .body) private var iconColumnWidth: CGFloat = 40
    /// Photo thumbnail edge in the editor's strip.
    @ScaledMetric(relativeTo: .body) private var thumbSize: CGFloat = 72

    init(
        sampleID: String?,
        store: LocalSampleStore,
        photoStore: LocalPhotoStore,
        fieldtripStore: LocalFieldtripStore,
        localitiesStore: LocalLocalityStore,
        mutationsStore: PendingMutationsStore,
        sync: SyncRunner,
        locationResolver: SampleLocationResolver,
        placemarkStore: LocalPlacemarkStore
    ) {
        _viewModel = StateObject(wrappedValue: SampleEditorViewModel(
            sampleID: sampleID,
            store: store,
            photoStore: photoStore,
            fieldtripStore: fieldtripStore,
            localitiesStore: localitiesStore,
            mutationsStore: mutationsStore,
            sync: sync,
            locationResolver: locationResolver,
            placemarkStore: placemarkStore
        ))
    }

    /// Linker Außen-Inset für den Editor-Inhalt. Auf iOS 26 schiebt
    /// der NavigationStack-Push die Destination etwas nach links —
    /// SwiftUI rechnet logisch korrekt (frames und safeAreaInsets
    /// melden null), aber die GPU rendert verschoben. Wir kompensieren
    /// mit zusätzlichen 16pt `contentMargins(.leading)` nur unter iOS 26.
    ///
    /// 16pt ist ein iterativer Mittelwert: +32 war zu großzügig (Editor
    /// hatte ~70pt links statt ~20pt wie die Proben-Liste), +0 brachte
    /// das Original-Clipping zurück.
    ///
    /// TODO: nach Apple-Fix oder iOS-26.x-Update entfernen.
    private var leadingMargin: CGFloat {
        if #available(iOS 26.0, *) {
            return AppSpacing.lg + AppSpacing.lg // 32pt total
        }
        return AppSpacing.lg
    }

    private var trailingMargin: CGFloat {
        AppSpacing.lg
    }

    /// `TextEditor` bringt einen eigenen ~5pt Text-Container-Inset mit,
    /// den `TextField` nicht hat — ohne Korrektur steht der Notizen-Text
    /// sichtbar weiter rechts als alle anderen Felder in der Section.
    /// Kein AppSpacing-Wert (System-Quirk, keine Rhythmus-Entscheidung),
    /// deshalb hier als benannte Konstante statt Magic-Number inline.
    private let notesTextContainerCorrection: CGFloat = -5

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                editableSection
                Divider()
                locationTimeSection
                // Karte bewusst edge-to-edge — negiert die
                // contentMargins via gleichgroße negative padding.
                MapSnippetView(coordinate: viewModel.coordinate)
                    .padding(.leading, -leadingMargin)
                    .padding(.trailing, -trailingMargin)
                if viewModel.isExistingSample {
                    SampleDeterminationsSection(
                        localSampleID: viewModel.savedSample?.id ?? "",
                        backendSampleID: viewModel.savedSample?.backendId
                    )
                    .padding(.top, AppSpacing.lg)
                    .padding(.bottom, AppSpacing.xl)
                }
            }
        }
        // contentMargins greift VOR dem iOS-26-CALayer-Shift und ist
        // unsere einzige Stellschraube auf der ScrollView-Ebene.
        .contentMargins(.leading, leadingMargin, for: .scrollContent)
        .contentMargins(.trailing, trailingMargin, for: .scrollContent)
        .background(Color(.systemBackground))
        .navigationTitle(viewModel.isExistingSample ? "Probe" : "Neue Probe")
        .navigationBarTitleDisplayMode(.inline)
        // When there are unsaved edits, swap out the default back
        // chevron for a guarded one so accidental taps don't silently
        // drop the user's work.
        .navigationBarBackButtonHidden(viewModel.isExistingSample && viewModel.hasUnsavedEdits)
        .toolbar {
            if viewModel.isExistingSample, viewModel.hasUnsavedEdits {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingDiscardConfirm = true
                    } label: {
                        HStack(spacing: AppSpacing.xs) {
                            Image(systemName: "chevron.backward")
                            Text("Zurück")
                        }
                        .accessibilityLabel("Zurück mit ungespeicherten Änderungen")
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingCamera = true
                } label: {
                    Image(systemName: "camera.fill")
                        .foregroundStyle(AppColor.brandPrimaryText)
                        .accessibilityLabel("Foto aufnehmen")
                }
            }
            if viewModel.isExistingSample, let sample = viewModel.savedSample {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        viewModel.toggleMarked(
                            endpoint: container.config.endpointURL,
                            auth: container.auth
                        )
                    } label: {
                        Image(systemName: sample.marked ? "star.fill" : "star")
                            .foregroundStyle(sample.marked ? .yellow : .secondary)
                            .accessibilityLabel(sample.marked ? "Markierung entfernen" : "Probe markieren")
                    }
                    .frame(minWidth: 44, minHeight: 44)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") {
                        Task {
                            await viewModel.saveEdits()
                            if viewModel.saveError == nil {
                                notesFocused = false
                                codeFocused = false
                            }
                        }
                    }
                    .disabled(!viewModel.canSave)
                    .accessibilityHint("Sichert die Änderungen lokal und stößt den Sync an.")
                }
            } else {
                ToolbarItem(placement: .bottomBar) {
                    saveButton
                }
            }
        }
        .task {
            viewModel.startGPS()
            viewModel.refreshDerivedFields()
        }
        .refreshable { viewModel.refreshDerivedFields() }
        .onChange(of: viewModel.code) { _, _ in viewModel.recheckCode() }
        .sheet(isPresented: $showingCamera) {
            CameraPicker { image in
                if let image { viewModel.addPhoto(image) }
                showingCamera = false
            }
            .ignoresSafeArea()
        }
        .confirmationDialog(
            "Änderungen verwerfen?",
            isPresented: $showingDiscardConfirm,
            titleVisibility: .visible
        ) {
            Button("Verwerfen", role: .destructive) { dismiss() }
            Button("Weiter bearbeiten", role: .cancel) {}
        } message: {
            Text("Die nicht gespeicherten Änderungen gehen verloren.")
        }
        .confirmationDialog(
            "Ortsangaben neu übernehmen?",
            isPresented: $viewModel.askRetakePlace,
            titleVisibility: .visible
        ) {
            Button("Übernehmen") { viewModel.applyCoordinateCorrection(keepManualPlace: false) }
            Button("Meine Angaben behalten") { viewModel.applyCoordinateCorrection(keepManualPlace: true) }
            Button("Abbrechen", role: .cancel) { viewModel.cancelCoordinateCorrection() }
        } message: {
            Text("Die Ortsangaben dieser Probe hast du von Hand gesetzt. Sollen für die neue Koordinate die ermittelten Ortsangaben übernommen werden?")
        }
        .sheet(isPresented: $showingCorrectionPicker, onDismiss: {
            guard let c = pickedCorrection else { return }
            pickedCorrection = nil
            viewModel.requestCoordinateCorrection(latitude: c.latitude, longitude: c.longitude)
        }) {
            CoordinatePickerView(selected: Binding(
                get: { pickedCorrection ?? viewModel.coordinate },
                set: { pickedCorrection = $0 }
            ))
        }
        .sheet(item: $placeEditor) { editor in
            PlaceEditorView(viewModel: editor) {
                viewModel.placeEdited()
            }
        }
    }

    // MARK: - editable section

    private var editableSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.lg) {
            if !viewModel.isExistingSample {
                modePicker
            }
            TextField("Code", text: $viewModel.code)
                .font(.title2.weight(.semibold).monospaced())
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .submitLabel(.next)
                .focused($codeFocused)
                .accessibilityLabel("Sample-Code")
                .accessibilityHint("Vorschlag nach deinem ID-Format. Anpassbar oder leer lassbar, falls du eine andere Nummer auf dem Röhrchen hast.")

            if let codeError = viewModel.codeValidationError {
                Text(codeError)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .accessibilityLabel("Fehler im Code-Feld: \(codeError)")
            }

            // The server appended a conflict suffix to the sent ID.
            if viewModel.savedSample?.hasIdConflict == true {
                IdConflictHint()
            }

            Divider()

            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text("Notizen")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                TextEditor(text: $viewModel.notes)
                    .padding(.leading, notesTextContainerCorrection)
                    .frame(minHeight: 100, maxHeight: 220)
                    .focused($notesFocused)
                    .accessibilityLabel("Notizen zur Probe")
            }

            if !viewModel.pendingPhotos.isEmpty || !viewModel.savedPhotos.isEmpty {
                photoStrip
            }

            if viewModel.mode == .later {
                manualCoordinateRow
            }

            if let saveError = viewModel.saveError {
                Text(saveError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        // Horizontale Margin sitzt auf der ScrollView (contentMargins).
        // Hier nur vertikale Paddings + frame-Stretching für TextField/
        // TextEditor.
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, AppSpacing.md)
        .padding(.bottom, AppSpacing.lg)
        .sheet(isPresented: $showingCoordinatePicker) {
            CoordinatePickerView(selected: Binding(
                get: { viewModel.coordinate },
                set: { newValue in
                    if let c = newValue {
                        viewModel.setManualCoordinate(latitude: c.latitude, longitude: c.longitude)
                    }
                }
            ))
        }
    }

    /// "Jetzt im Feld" (GPS + Fusion) vs. "Nachträglich" (Koordinate
    /// von Hand). „Geplant" folgt mit R11.
    private var modePicker: some View {
        Picker("Modus", selection: $viewModel.mode) {
            Text("Jetzt im Feld").tag(SampleEditorViewModel.Mode.field)
            Text("Nachträglich").tag(SampleEditorViewModel.Mode.later)
        }
        .pickerStyle(.segmented)
        .accessibilityLabel("Erfassungsmodus")
    }

    private var manualCoordinateRow: some View {
        Button {
            showingCoordinatePicker = true
        } label: {
            HStack(spacing: AppSpacing.sm) {
                Image(systemName: "mappin.and.ellipse")
                    .accessibilityHidden(true)
                Text(viewModel.coordinate == nil ? "Koordinate auf Karte wählen" : "Koordinate ändern")
                Spacer()
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }
        .accessibilityHint("Öffnet eine Karte zum Setzen der Koordinate.")
    }

    private var photoStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: AppSpacing.sm) {
                ForEach(viewModel.pendingPhotos) { photo in
                    photoThumb(image: photo.image) {
                        viewModel.removePendingPhoto(id: photo.id)
                    }
                    .accessibilityLabel("Noch nicht gespeichertes Foto")
                    .accessibilityAction(named: "Entfernen") {
                        viewModel.removePendingPhoto(id: photo.id)
                    }
                }
                ForEach(viewModel.savedPhotos) { photo in
                    SavedPhotoThumbnail(relativePath: photo.localPath, size: thumbSize)
                        .accessibilityLabel("Gespeichertes Foto")
                }
            }
        }
    }

    private func photoThumb(image: UIImage, onRemove: @escaping () -> Void) -> some View {
        Image(uiImage: image)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: thumbSize, height: thumbSize)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
            .overlay(alignment: .topTrailing) {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.white, .black.opacity(0.6))
                        .padding(AppSpacing.xxs)
                }
                .accessibilityHidden(true)
            }
    }

    // MARK: - bottom section

    private var locationTimeSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Text("STANDORT UND ZEIT")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, AppSpacing.lg)
                .accessibilityAddTraits(.isHeader)

            locationRow

            if viewModel.isExistingSample {
                // The leading inset aligns the divider with the right
                // edge of the icon column inside each row.
                Divider().padding(.leading, iconColumnWidth)
                placeSection
            } else if fieldtripName != nil {
                Divider().padding(.leading, iconColumnWidth)
                fieldtripRow
            }

            Divider().padding(.leading, iconColumnWidth)
            timeRow
        }
        // Horizontale Margin sitzt auf der ScrollView. Background
        // soll trotzdem edge-to-edge — Color in der background-Closure
        // wird mit negativer horizontaler Padding über die
        // contentMargins-Grenze hinaus aufgeweitet.
        .padding(.bottom, AppSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            Color(.secondarySystemBackground)
                .padding(.leading, -leadingMargin)
                .padding(.trailing, -trailingMargin)
        }
    }

    private var locationRow: some View {
        HStack(alignment: .top, spacing: AppSpacing.lg) {
            GPSStatusIcon(status: locationIconStatus)
                .frame(width: iconColumnWidth)
                .padding(.top, AppSpacing.xs)

            // Side-by-side at default widths, stacked vertically when
            // either Dynamic Type or a narrower device pushes the
            // right-column off-screen. Truncation is the second-line
            // defense; `ViewThatFits` is the first.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: AppSpacing.md) {
                    coordinateBlock
                    Spacer(minLength: AppSpacing.sm)
                    altitudeBlock(alignment: .trailing)
                }
                VStack(alignment: .leading, spacing: AppSpacing.sm) {
                    coordinateBlock
                    altitudeBlock(alignment: .leading)
                }
            }
        }
        .padding(.vertical, AppSpacing.md)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(locationA11yLabel)
    }

    private var coordinateBlock: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xxs) {
            // No line limit: `ViewThatFits` in `locationRow` stacks the
            // blocks when the coordinate doesn't fit on one line.
            Text(coordinateText)
                .font(.body.monospacedDigit())
            if let acc = viewModel.accuracyM {
                HStack(spacing: AppSpacing.xs) {
                    Text("Genauigkeit").foregroundStyle(.secondary)
                    Text(String(format: "±%.0f m", acc))
                }
                .font(.footnote)
            }
        }
    }

    private func altitudeBlock(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: AppSpacing.xxs) {
            Text("Höhe")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(altitudeText)
                .font(.body.monospacedDigit())
            if let acc = viewModel.savedSample?.verticalAccuracy {
                Text(String(format: "± %.0f m", acc))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Place data of a saved sample: status hints, the place fields
    /// with country-specific terms, MTB, the fieldtrip, and actions
    /// (edit place, correct coordinate, accept/dismiss a suggestion,
    /// resend a failed push).
    private var placeSection: some View {
        HStack(alignment: .top, spacing: AppSpacing.lg) {
            Color.clear
                .frame(width: iconColumnWidth)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                if viewModel.canResend {
                    resendBanner
                }
                if viewModel.hasSuggestion {
                    suggestionBanner
                }
                placeStatusLine
                ForEach(viewModel.placeItems) { item in
                    PlaceFieldRow(item)
                }
                if let mtb = viewModel.mtbText {
                    Text(mtb)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if fieldtripName != nil {
                    fieldtripLine
                }
                placeActions
                if let error = viewModel.placeActionError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(AppColor.danger)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, AppSpacing.sm)
    }

    /// Fieldtrip line for the create path (no place section yet).
    private var fieldtripRow: some View {
        HStack(alignment: .top, spacing: AppSpacing.lg) {
            Color.clear
                .frame(width: iconColumnWidth)
                .accessibilityHidden(true)
            fieldtripLine
            Spacer(minLength: 0)
        }
        .padding(.vertical, AppSpacing.sm)
    }

    // The label "Sammeltag" is rendered exactly once here;
    // `fieldtripName` returns nil when no human-readable title is
    // loaded yet — no "Sammeltag Sammeltag" stutter.
    @ViewBuilder
    private var fieldtripLine: some View {
        if let fieldtripName {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: AppSpacing.xs) {
                    Text("Sammeltag").foregroundStyle(.secondary)
                    Text(fieldtripName)
                }
                VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                    Text("Sammeltag").foregroundStyle(.secondary)
                    Text(fieldtripName)
                }
            }
            .font(.footnote)
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder
    private var placeStatusLine: some View {
        if let sample = viewModel.savedSample {
            if sample.latitude == nil || sample.longitude == nil {
                Label("Ohne Koordinate – setze einen Kartenpunkt, damit Ortsangaben ermittelt werden.",
                      systemImage: "mappin.slash")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if viewModel.placeItems.isEmpty {
                switch sample.locationStatus {
                case .pending:
                    Label("Ortsangaben werden ermittelt – spätestens nach dem nächsten Sync.",
                          systemImage: "clock")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                case .backendService:
                    Label("Keine Ortsangaben für diese Koordinate (z. B. auf dem Meer).",
                          systemImage: "water.waves")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                case .inherited, .manual:
                    EmptyView()
                }
            }
            if sample.locationStatus == .manual {
                Label("Ortsangaben von Hand gesetzt", systemImage: "hand.point.up.left")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if sample.locationStatus == .inherited {
                Label("Ortsangaben von der vorigen Probe des Tages übernommen", systemImage: "arrow.turn.down.right")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var suggestionBanner: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Label("Neue Ortsangaben verfügbar", systemImage: "sparkles")
                .font(.subheadline.weight(.semibold))
            if let name = viewModel.suggestionName {
                Text("Vorschlag: \(name)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: AppSpacing.md) {
                    suggestionButtons
                }
                VStack(alignment: .leading, spacing: AppSpacing.sm) {
                    suggestionButtons
                }
            }
        }
        .padding(AppSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColor.surface, in: RoundedRectangle(cornerRadius: AppRadius.md))
    }

    @ViewBuilder
    private var suggestionButtons: some View {
        // `.large` bordered buttons reach the 44 pt tap target (a frame
        // outside the button style only grows the layout box).
        Button("Übernehmen") { viewModel.acceptSuggestion() }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(AppColor.brandPrimary)
            .accessibilityHint("Ersetzt deine Ortsangaben durch die neu ermittelten.")
        Button("Verwerfen") { viewModel.dismissSuggestion() }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .accessibilityHint("Behält deine Ortsangaben und blendet den Vorschlag aus.")
    }

    private var resendBanner: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Label("Sync fehlgeschlagen", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppColor.syncFailed)
            if let error = viewModel.savedSample?.syncError, !error.isEmpty {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Button {
                viewModel.resendFailed()
            } label: {
                Label("Erneut senden", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .accessibilityHint("Überträgt die lokal gespeicherte Probe erneut an den Server.")
        }
        .padding(AppSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColor.surface, in: RoundedRectangle(cornerRadius: AppRadius.md))
    }

    private var placeActions: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            if viewModel.coordinate != nil {
                Button {
                    placeEditor = viewModel.makePlaceEditor()
                } label: {
                    Label("Ortsangaben bearbeiten", systemImage: "pencil")
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
                .accessibilityHint("Ortsangaben und Höhe dieser Probe von Hand korrigieren.")
            }
            Button {
                showingCorrectionPicker = true
            } label: {
                Label(viewModel.coordinate == nil ? "Kartenpunkt setzen" : "Koordinate korrigieren",
                      systemImage: "mappin.and.ellipse")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            .accessibilityHint("Öffnet eine Karte; danach werden die Ortsangaben neu ermittelt.")
        }
    }

    private var timeRow: some View {
        HStack(alignment: .top, spacing: AppSpacing.lg) {
            Image(systemName: moonSymbol)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: iconColumnWidth)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text(longDateText)
                    .font(.body)
                    .lineLimit(2)
                    .minimumScaleFactor(0.9)
                if let zoneLabel = timezoneLabelText {
                    Text(zoneLabel)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if viewModel.isExistingSample {
                    timeWindowEditor
                }
                if let sunrise = sunriseText, let sunset = sunsetText {
                    // Wrap sunrise/sunset into a second row when the
                    // first one wouldn't fit horizontally (AX5 +
                    // narrow device).
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: AppSpacing.lg) {
                            Label(sunrise, systemImage: "sunrise.fill")
                            Label(sunset, systemImage: "sunset.fill")
                        }
                        VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                            Label(sunrise, systemImage: "sunrise.fill")
                            Label(sunset, systemImage: "sunset.fill")
                        }
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: AppSpacing.sm)
        }
        .padding(.vertical, AppSpacing.md)
        .modifier(TimeRowAccessibility(isEditable: viewModel.isExistingSample, label: timeA11yLabel))
        .sheet(isPresented: $showingTimeZonePicker) {
            TimeZonePickerView(selected: viewModel.timezoneID, date: viewModel.beginDate) { id in
                viewModel.setTimezone(id)
            }
        }
    }

    /// Beginn, Ende und Zeitzone eines bestehenden Samples. Die
    /// DatePicker lesen und schreiben in der Zone des Samples; ein
    /// Zonenwechsel lässt die UTC-Zeitpunkte unverändert.
    private var timeWindowEditor: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            DatePicker(
                "Beginn",
                selection: Binding(get: { viewModel.beginDate }, set: { viewModel.setBeginDate($0) }),
                displayedComponents: [.date, .hourAndMinute]
            )
            .frame(minHeight: 44)
            DatePicker(
                "Ende",
                selection: Binding(get: { viewModel.endDate }, set: { viewModel.setEndDate($0) }),
                in: viewModel.beginDate...,
                displayedComponents: [.date, .hourAndMinute]
            )
            .frame(minHeight: 44)
            Button {
                showingTimeZonePicker = true
            } label: {
                HStack {
                    Text("Zeitzone")
                    Spacer(minLength: AppSpacing.sm)
                    Text(viewModel.timezoneID)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                    Image(systemName: "chevron.right")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Zeitzone")
            .accessibilityValue(viewModel.timezoneID)
            .accessibilityHint("Öffnet die Auswahl der Zeitzone. Die Zeitpunkte bleiben gleich.")
            .accessibilityAddTraits(.isButton)
        }
        .environment(\.timeZone, viewModel.timeZone)
    }

    // MARK: - save bar

    private var saveButton: some View {
        Button {
            Task {
                await viewModel.save()
                if viewModel.saveError == nil {
                    notesFocused = false
                    codeFocused = false
                }
            }
        } label: {
            HStack {
                if viewModel.isSaving { ProgressView().tint(.white) }
                Text(viewModel.isSaving ? "Speichere …" : "Probe anlegen")
                    .font(.headline)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .tint(AppColor.brandPrimary)
        .disabled(!viewModel.canSave)
        .accessibilityHint("Speichert die Probe lokal und stößt den Sync an.")
    }

    // MARK: - derived view state

    /// Once the sample is saved we stop showing the "locating" icon
    /// — the persisted coordinate is authoritative even if the GPS
    /// stream is still chattering in the background.
    private var locationIconStatus: LocationProvider.Status {
        if viewModel.isExistingSample, let coord = viewModel.coordinate {
            return .fixed(CLLocation(latitude: coord.latitude, longitude: coord.longitude))
        }
        return viewModel.locationStatus
    }

    private var coordinateText: String {
        guard let c = viewModel.coordinate else {
            switch viewModel.locationStatus {
            case .denied: return "GPS gesperrt"
            case .failed: return "GPS-Fehler"
            default: return "Suche Position …"
            }
        }
        return String(format: "%.6f, %.6f", c.latitude, c.longitude)
    }

    private var altitudeText: String {
        if let alt = viewModel.altitudeM { return String(format: "%.0f m", alt) }
        return "—"
    }

    /// Human-readable fieldtrip title or nil. The previous code
    /// returned the literal string "Sammeltag" as a fallback when
    /// only the fieldtrip id was known — that produced the
    /// "Sammeltag Sammeltag" stutter in the admin row, because the
    /// label itself is already rendered there. Returning nil now
    /// means the entire row is hidden until the SyncRunner hydrates
    /// a real title.
    private var fieldtripName: String? {
        guard let ft = viewModel.savedFieldtrip, !ft.title.isEmpty else { return nil }
        return ft.title
    }

    private var moonSymbol: String {
        guard let astro = viewModel.savedFieldtrip?.astro else { return "moon.stars" }
        // Crude mapping from phase fraction (0..1) to SF moon symbols.
        switch astro.moonPhase {
        case ..<0.05, 0.95...: return "moon.dust"
        case 0.05 ..< 0.2: return "moon"
        case 0.2 ..< 0.3: return "moon.fill"
        case 0.3 ..< 0.45: return "moon"
        case 0.45 ..< 0.55: return "moon.stars.fill"
        case 0.55 ..< 0.7: return "moon"
        case 0.7 ..< 0.8: return "moon.fill"
        default: return "moon"
        }
    }

    private func dayFormatter(in zone: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.timeZone = zone
        f.dateFormat = "EEEE, dd. MMMM yyyy"
        return f
    }

    private var timeFormatter: DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.timeZone = viewModel.isExistingSample ? viewModel.timeZone : .current
        f.dateFormat = "HH:mm"
        return f
    }

    private var longDateText: String {
        // Existing sample: the sample's zone; a new one reads the
        // device zone (that is the zone it will be created in).
        if viewModel.isExistingSample {
            return dayFormatter(in: viewModel.timeZone).string(from: viewModel.beginDate)
        }
        return dayFormatter(in: .current).string(from: Date())
    }

    /// „Atlantic/Canary (WET)“ — Kürzel gilt zum Beginn-Zeitpunkt.
    private var timezoneLabelText: String? {
        guard viewModel.isExistingSample else { return nil }
        return SampleTime.timezoneLabel(viewModel.timeZone, at: viewModel.beginDate)
    }

    private var sunriseText: String? {
        guard let t = viewModel.savedFieldtrip?.astro?.sunrise else { return nil }
        return timeFormatter.string(from: t)
    }

    private var sunsetText: String? {
        guard let t = viewModel.savedFieldtrip?.astro?.sunset else { return nil }
        return timeFormatter.string(from: t)
    }

    // MARK: - A11y labels

    private var locationA11yLabel: String {
        var parts: [String] = []
        if let c = viewModel.coordinate {
            parts.append(String(format: "Koordinate %.4f Komma %.4f", c.latitude, c.longitude))
        } else {
            parts.append("Position wird gesucht")
        }
        if let acc = viewModel.accuracyM {
            parts.append(String(format: "Genauigkeit etwa %.0f Meter", acc))
        }
        if let alt = viewModel.altitudeM {
            parts.append(String(format: "Höhe %.0f Meter", alt))
            if let acc = viewModel.savedSample?.verticalAccuracy {
                parts.append(String(format: "Fehler etwa %.0f Meter", acc))
            }
        }
        return parts.joined(separator: ", ")
    }

    private var timeA11yLabel: String {
        var parts = [longDateText]
        if let zone = timezoneLabelText { parts.append(zone) }
        if let sunrise = sunriseText { parts.append("Sonnenaufgang " + sunrise) }
        if let sunset = sunsetText { parts.append("Sonnenuntergang " + sunset) }
        return parts.joined(separator: ", ")
    }
}

/// Loads a JPEG file from PhotoStorage and renders it as a square
/// thumbnail of `size` points. Used in the saved-photos strip of the editor.
private struct SavedPhotoThumbnail: View {
    let relativePath: String
    let size: CGFloat

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(Color(.secondarySystemBackground))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
        .task { load() }
    }

    private func load() {
        guard image == nil else { return }
        if let data = try? PhotoStorage.readData(relativePath: relativePath),
           let img = UIImage(data: data)
        {
            image = img
        }
    }
}

#Preview {
    SampleEditorView(sampleID: nil)
        .environmentObject(AppContainer())
}

/// Der Zeitbereich eines bestehenden Samples enthält bedienbare Felder
/// (DatePicker, Zeitzonen-Zeile) und darf deshalb nicht zu einem einzigen
/// Element zusammengezogen werden; bei neuen Samples ist er reiner Text.
private struct TimeRowAccessibility: ViewModifier {
    let isEditable: Bool
    let label: String

    func body(content: Content) -> some View {
        if isEditable {
            content.accessibilityElement(children: .contain)
        } else {
            content
                .accessibilityElement(children: .combine)
                .accessibilityLabel(label)
        }
    }
}

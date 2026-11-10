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
///   │   GPS icon + system / coords + altitude     │
///   │   Gazetteer-Zeile, Peilung, Exposition, MTB │
///   │   Datum, Uhrzeit, Sonne / Mond              │
///   ├─────────────────────────────────────────────┤
///   │  [ static map snippet with pin ]            │
///   └─────────────────────────────────────────────┘
///
/// The top stays editable; the bottom is read-only and follows the row
/// as a background fix lands, the sync round-trip enriches it or the
/// edit form („Bearbeiten“ → `SampleFormView`, Phase N) saves it.
/// Coordinate, time and place data are edited only in that form.
///
/// Saving (Phase E): no save button for a saved sample. The custom
/// back button saves and validates the id; going to the background
/// saves without dialogs. The navigation bar's back button is hidden
/// and `interactivePopDisabled()` switches off the swipe-back gestures
/// (hiding the button alone doesn't reliably do that on iOS 26), so
/// every way out goes through `finishEditing()`. `onDisappear` stays
/// as the last-resort save (pop-to-root, an unknown gesture).
struct SampleEditorView: View {
    /// Local id of the persisted sample, adopted on init.
    let sampleID: String
    /// The sample was just created instantly on the home screen.
    var isNew: Bool = false
    /// Running number of its suggested id (see `InstantSampleCreator`).
    var suggestedRunning: Int?

    @EnvironmentObject var container: AppContainer

    var body: some View {
        SampleEditorContent(
            sampleID: sampleID,
            isNew: isNew,
            suggestedRunning: suggestedRunning,
            store: container.store,
            photoStore: container.photos,
            fieldtripStore: container.fieldtrips,
            mutationsStore: container.mutations,
            sync: container.sync,
            placemarkStore: container.placemarksStore,
            pendingFixes: container.pendingFixes
        )
    }
}

private struct SampleEditorContent: View {
    @StateObject private var viewModel: SampleEditorViewModel
    @EnvironmentObject private var container: AppContainer
    /// Coordinate display format; the view follows a settings change.
    @EnvironmentObject private var config: AppConfig
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var showingCamera = false
    @FocusState private var notesFocused: Bool
    @FocusState private var codeFocused: Bool

    /// The edit form („Bearbeiten“) is pushed.
    @State private var showingForm = false

    /// Width of the leading icon column in the location rows; grows
    /// with Dynamic Type so the icons keep their proportion.
    @ScaledMetric(relativeTo: .body) private var iconColumnWidth: CGFloat = 28
    /// Photo thumbnail edge in the editor's strip.
    @ScaledMetric(relativeTo: .body) private var thumbSize: CGFloat = 72

    init(
        sampleID: String,
        isNew: Bool,
        suggestedRunning: Int?,
        store: LocalSampleStore,
        photoStore: LocalPhotoStore,
        fieldtripStore: LocalFieldtripStore,
        mutationsStore: PendingMutationsStore,
        sync: SyncRunner,
        placemarkStore: LocalPlacemarkStore,
        pendingFixes: PendingFixService
    ) {
        _viewModel = StateObject(wrappedValue: SampleEditorViewModel(
            sampleID: sampleID,
            isNew: isNew,
            suggestedRunning: suggestedRunning,
            store: store,
            photoStore: photoStore,
            fieldtripStore: fieldtripStore,
            mutationsStore: mutationsStore,
            sync: sync,
            placemarkStore: placemarkStore,
            pendingFixes: pendingFixes
        ))
    }

    /// Horizontal content inset, the same on both sides. The former
    /// iOS-26 extra 16 pt on the left (render shift after the push) is
    /// gone: the shift no longer shows, the extra inset did.
    private var leadingMargin: CGFloat {
        AppSpacing.lg
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
        .navigationTitle(viewModel.isExistingSample && !viewModel.isNew ? "Probe" : "Neue Probe")
        .navigationBarTitleDisplayMode(.inline)
        // Our own back button saves first. The swipe-back is switched
        // off explicitly so it can't bypass the id validation.
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
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
                }
                .accessibilityLabel("Zurück")
            }
            if viewModel.isExistingSample {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Bearbeiten", action: openForm)
                        .accessibilityHint("Öffnet Koordinate, Zeit und Ortsdaten zum Bearbeiten.")
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
            }
        }
        .task {
            viewModel.refreshDerivedFields()
            viewModel.observeRow()
        }
        .onChange(of: scenePhase) { _, phase in
            // Save without dialogs; an empty/taken id stays in the
            // field until the user goes back.
            if phase == .background { viewModel.saveEdits() }
        }
        .onDisappear {
            // Last resort: every regular way out went through
            // `finishEditing()` already.
            if !viewModel.finished { viewModel.saveEdits() }
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
        .alert(
            "Die Sample-ID darf nicht leer sein und muss eindeutig sein.",
            isPresented: promptBinding(.emptyID)
        ) {
            TextField("Sample-ID", text: $viewModel.promptedID)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
            Button("Speichern") {
                if viewModel.submitPromptedID() { dismiss() }
            }
            Button("Sample löschen", role: .destructive) {
                if viewModel.deleteNewSample() { dismiss() }
            }
        } message: {
            if let reason = viewModel.promptReason {
                Text(reason)
            }
        }
        .alert(
            "Diese Sample-ID ist bereits vergeben.",
            isPresented: promptBinding(.duplicate)
        ) {
            Button("Korrigieren", role: .cancel) {
                viewModel.correctID()
                codeFocused = true
            }
            Button("Bisherige ID behalten") {
                if viewModel.keepPreviousID() { dismiss() }
            }
        }
        .navigationDestination(isPresented: $showingForm) {
            if let id = viewModel.savedSample?.id {
                SampleFormView(sampleID: id)
            }
        }
    }

    // MARK: - leaving

    /// „Bearbeiten“: saves code and notes first (the form works on the
    /// row), then pushes the form.
    private func openForm() {
        notesFocused = false
        codeFocused = false
        viewModel.saveEdits()
        showingForm = true
    }

    private func goBack() {
        notesFocused = false
        codeFocused = false
        if viewModel.finishEditing() { dismiss() }
    }

    /// Alert binding for one id dialog; closing it clears the state.
    private func promptBinding(_ prompt: SampleEditorViewModel.IDPrompt) -> Binding<Bool> {
        Binding(
            get: { viewModel.idPrompt == prompt },
            set: { presented in
                if !presented, viewModel.idPrompt == prompt { viewModel.idPrompt = nil }
            }
        )
    }

    // MARK: - editable section

    private var editableSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.lg) {
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
        HStack(alignment: .top, spacing: AppSpacing.sm) {
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

    /// System name on top (aligned with „Höhe“), the coordinate, then
    /// the horizontal accuracy. Labels secondary, values primary.
    private var coordinateBlock: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xxs) {
            if let caption = coordinateDisplay?.caption {
                Text(caption)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            // No line limit: `ViewThatFits` in `locationRow` stacks the
            // blocks when the coordinate doesn't fit on one line.
            Text(coordinateText)
                .font(.body.monospacedDigit())
            if let acc = viewModel.accuracyM {
                HStack(alignment: .firstTextBaseline, spacing: AppSpacing.xs) {
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
                Text(String(format: "±%.0f m", acc))
                    .font(.footnote)
            }
        }
    }

    /// Place data of a saved sample: status hints, the gazetteer line,
    /// bearing/aspect/slope, MTB, and the actions that
    /// stay here (accept/dismiss a suggestion, resend a failed push).
    /// Editing goes through „Bearbeiten“.
    private var placeSection: some View {
        HStack(alignment: .top, spacing: AppSpacing.sm) {
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
                placeSummary
                if let mtb = viewModel.mtbText {
                    Text(mtb)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
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

    @ViewBuilder
    private var placeStatusLine: some View {
        if let sample = viewModel.savedSample {
            if sample.latitude == nil || sample.longitude == nil {
                Label("Ohne Koordinate – unter „Bearbeiten“ eine Koordinate setzen, damit Ortsangaben ermittelt werden.",
                      systemImage: "mappin.slash")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if viewModel.gazetteerLine == nil {
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

    /// Gazetteer line, then one line each for bearing, aspect and slope.
    @ViewBuilder
    private var placeSummary: some View {
        if let line = viewModel.gazetteerLine {
            Text(line)
                .font(.body)
        }
        ForEach(viewModel.placeDetailLines) { line in
            placeDetailRow(line)
        }
    }

    /// „Exposition SSW (203°)“; stacks label over value when the pair
    /// doesn't fit on one line (AX sizes). The bearing has no label.
    @ViewBuilder
    private func placeDetailRow(_ line: PlaceDisplay.DetailLine) -> some View {
        if let label = line.label {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: AppSpacing.xs) {
                    Text(label).foregroundStyle(.secondary)
                    Text(line.value)
                }
                VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                    Text(label).foregroundStyle(.secondary)
                    Text(line.value)
                }
            }
            .font(.footnote)
            .accessibilityElement(children: .combine)
        } else {
            Text(line.value)
                .font(.footnote)
        }
    }

    private var timeRow: some View {
        HStack(alignment: .top, spacing: AppSpacing.sm) {
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
                if let window = timeWindowText {
                    Text(window)
                        .font(.body.monospacedDigit())
                }
                if let zoneLabel = timezoneLabelText {
                    Text(zoneLabel)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel(timeA11yLabel)
    }

    // MARK: - derived view state

    /// Once the sample is saved we stop showing the "locating" icon
    /// — the persisted coordinate is authoritative even if the GPS
    /// stream is still chattering in the background.
    private var locationIconStatus: LocationProvider.Status {
        if viewModel.isExistingSample, let coord = viewModel.coordinate {
            return .fixed(CLLocation(latitude: coord.latitude, longitude: coord.longitude))
        }
        if hasNoCoordinate {
            return .failed("Ohne Koordinate")
        }
        return viewModel.locationStatus
    }

    /// A saved sample without coordinate that nobody is locating for
    /// (legacy row, or `PendingFixService` gave up).
    private var hasNoCoordinate: Bool {
        viewModel.isExistingSample && viewModel.coordinate == nil
            && viewModel.locationStatus != .locating
    }

    private var coordinateText: String {
        if hasNoCoordinate { return "Ohne Koordinate" }
        guard let c = viewModel.coordinate else {
            switch viewModel.locationStatus {
            case .denied: return "GPS gesperrt"
            case .failed: return "GPS-Fehler"
            default: return "Suche Position …"
            }
        }
        return coordinateDisplay?.text ?? String(format: "%.6f, %.6f", c.latitude, c.longitude)
    }

    /// The coordinate in the format chosen in the settings, with the
    /// format's name for the caption; nil without coordinate.
    private var coordinateDisplay: (text: String, caption: String)? {
        guard let c = viewModel.coordinate else { return nil }
        return PlaceDisplay.coordinate(latitude: c.latitude, longitude: c.longitude,
                                       format: config.coordinateDisplayFormat)
    }

    private var altitudeText: String {
        if let alt = viewModel.altitudeM { return String(format: "%.0f m", alt) }
        return "—"
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

    /// „10:07 – 10:22“; nil for an all-day or a not yet saved sample.
    private var timeWindowText: String? {
        guard viewModel.isExistingSample else { return nil }
        return SampleEditorViewModel.timeWindowText(
            begin: viewModel.beginDate, end: viewModel.endDate,
            isAllDay: viewModel.isAllDay, zone: viewModel.timeZone
        )
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
        if let display = coordinateDisplay {
            parts.append("Koordinate \(display.text), \(display.caption)")
        } else if hasNoCoordinate {
            parts.append("Ohne Koordinate")
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
        if let window = timeWindowText { parts.append(window) }
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
    let container = AppContainer()
    return NavigationStack {
        SampleEditorView(sampleID: "preview")
    }
    .environmentObject(container)
    .environmentObject(container.config)
}

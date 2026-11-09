import CoreLocation
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
///   │   Admin units (Deutschland, Bayern, …)      │
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
            locationResolver: container.makeLocationResolver()
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
    @State private var showingDiscardConfirm = false

    init(
        sampleID: String?,
        store: LocalSampleStore,
        photoStore: LocalPhotoStore,
        fieldtripStore: LocalFieldtripStore,
        localitiesStore: LocalLocalityStore,
        mutationsStore: PendingMutationsStore,
        sync: SyncRunner,
        locationResolver: SampleLocationResolver
    ) {
        _viewModel = StateObject(wrappedValue: SampleEditorViewModel(
            sampleID: sampleID,
            store: store,
            photoStore: photoStore,
            fieldtripStore: fieldtripStore,
            localitiesStore: localitiesStore,
            mutationsStore: mutationsStore,
            sync: sync,
            locationResolver: locationResolver
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
                        HStack(spacing: 4) {
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
                .accessibilityHint("Standardmäßig YYMMDD/Nr. Anpassbar, falls du eine andere Nummer auf dem Röhrchen hast.")

            if let codeError = viewModel.codeValidationError {
                Text(codeError)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .accessibilityLabel("Fehler im Code-Feld: \(codeError)")
            }

            // Server reassigned the tube label on collision; surface
            // the audit trail (mirrors the old SampleDetailView hint).
            if let sample = viewModel.savedSample,
               let backendCode = sample.backendCode,
               backendCode != sample.sampleID
            {
                Text("Server: \(backendCode) — Original: \(sample.sampleID)")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .accessibilityLabel(
                        "Hinweis: Server hat den Code zu \(backendCode) umbenannt. Original auf dem Röhrchen: \(sample.sampleID)."
                    )
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
            HStack(spacing: 10) {
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
                    SavedPhotoThumbnail(relativePath: photo.localPath)
                        .accessibilityLabel("Gespeichertes Foto")
                }
            }
        }
    }

    private func photoThumb(image: UIImage, onRemove: @escaping () -> Void) -> some View {
        Image(uiImage: image)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: 72, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .topTrailing) {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.white, .black.opacity(0.6))
                        .padding(2)
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

            if hasAdminInfo {
                // Leading-inset of `40` aligns the divider with the
                // right edge of the icon column (40pt) inside each
                // row; the outer container padding adds the remaining
                // 16pt to reach the legacy 56pt indent from the
                // screen edge.
                Divider().padding(.leading, 40)
                adminRow
            }

            Divider().padding(.leading, 40)
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
                .frame(width: 40)
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
            Text(coordinateText)
                .font(.body.monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.85)
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
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
    }

    private var adminRow: some View {
        HStack(alignment: .top, spacing: AppSpacing.lg) {
            Color.clear.frame(width: 40, height: 1)
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                if let admin = adminLines {
                    ForEach(admin, id: \.self) { line in
                        Text(line).font(.body).lineLimit(2)
                    }
                }
                // The label "Sammeltag" is rendered exactly once here;
                // `fieldtripName` (computed) returns nil when no
                // human-readable title is loaded yet — no "Sammeltag
                // Sammeltag" stutter.
                if let fieldtripName {
                    HStack(spacing: AppSpacing.xs) {
                        Text("Sammeltag")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text(fieldtripName)
                            .font(.footnote)
                            .lineLimit(2)
                            .minimumScaleFactor(0.85)
                    }
                }
                if let mtb = viewModel.savedSample?.mtbSheetName {
                    Text("MTB \(mtb)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: AppSpacing.sm)
        }
        .padding(.vertical, AppSpacing.sm)
        .accessibilityElement(children: .combine)
    }

    private var timeRow: some View {
        HStack(alignment: .top, spacing: AppSpacing.lg) {
            Image(systemName: moonSymbol)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 40)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text(longDateText)
                    .font(.body)
                    .lineLimit(2)
                    .minimumScaleFactor(0.9)
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

    private var hasAdminInfo: Bool {
        adminLines != nil || (fieldtripName?.isEmpty == false) || viewModel.savedSample?.mtbSheetNumber != nil
    }

    private var adminLines: [String]? {
        guard let sample = viewModel.savedSample else { return nil }
        var lines: [String] = []
        if let country = sample.adminUnitsCountry { lines.append(country) }
        if let locality = sample.adminUnitsLocality, lines.last != locality {
            lines.append(locality)
        }
        return lines.isEmpty ? nil : lines
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

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "EEEE, dd. MMMM yyyy"
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "HH:mm"
        return f
    }()

    private var longDateText: String {
        let date = viewModel.savedSample?.beginDate ?? Date()
        return Self.dayFormatter.string(from: date)
    }

    private var sunriseText: String? {
        guard let t = viewModel.savedFieldtrip?.astro?.sunrise else { return nil }
        return Self.timeFormatter.string(from: t)
    }

    private var sunsetText: String? {
        guard let t = viewModel.savedFieldtrip?.astro?.sunset else { return nil }
        return Self.timeFormatter.string(from: t)
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
        }
        return parts.joined(separator: ", ")
    }

    private var timeA11yLabel: String {
        var parts = [longDateText]
        if let sunrise = sunriseText { parts.append("Sonnenaufgang " + sunrise) }
        if let sunset = sunsetText { parts.append("Sonnenuntergang " + sunset) }
        return parts.joined(separator: ", ")
    }
}

/// Loads a JPEG file from PhotoStorage and renders it as a 72×72
/// thumbnail. Used in the saved-photos strip of the editor.
private struct SavedPhotoThumbnail: View {
    let relativePath: String

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
        .frame(width: 72, height: 72)
        .clipShape(RoundedRectangle(cornerRadius: 8))
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

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
            excursionStore: container.excursions,
            sync: container.sync
        )
    }
}

private struct SampleEditorContent: View {
    @StateObject private var viewModel: SampleEditorViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var showingCamera = false
    @FocusState private var notesFocused: Bool
    @FocusState private var codeFocused: Bool

    init(
        sampleID: String?,
        store: LocalSampleStore,
        photoStore: LocalPhotoStore,
        excursionStore: LocalExcursionStore,
        sync: SyncRunner
    ) {
        _viewModel = StateObject(wrappedValue: SampleEditorViewModel(
            sampleID: sampleID,
            store: store,
            photoStore: photoStore,
            excursionStore: excursionStore,
            sync: sync
        ))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                editableSection
                Divider()
                locationTimeSection
                MapSnippetView(coordinate: viewModel.coordinate)
            }
        }
        .background(Color(.systemBackground))
        .navigationTitle(viewModel.isExistingSample ? "Probe" : "Neue Probe")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingCamera = true
                } label: {
                    Image(systemName: "camera.fill")
                        .foregroundStyle(AppColor.brandPrimary)
                        .accessibilityLabel("Foto aufnehmen")
                }
            }
            if !viewModel.isExistingSample {
                ToolbarItem(placement: .bottomBar) {
                    saveButton
                }
            }
        }
        .task { viewModel.startGPS() }
        .sheet(isPresented: $showingCamera) {
            CameraPicker { image in
                if let image { viewModel.addPhoto(image) }
                showingCamera = false
            }
            .ignoresSafeArea()
        }
    }

    // MARK: - editable section

    private var editableSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            TextField("Code", text: $viewModel.code)
                .font(.title2.weight(.semibold).monospaced())
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .submitLabel(.next)
                .focused($codeFocused)
                .accessibilityLabel("Sample-Code")
                .accessibilityHint("Standardmäßig YYMMDD/Nr. Anpassbar, falls du eine andere Nummer auf dem Röhrchen hast.")

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Notizen")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                TextEditor(text: $viewModel.notes)
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
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 16)
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
        VStack(alignment: .leading, spacing: 12) {
            Text("STANDORT UND ZEIT")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .accessibilityAddTraits(.isHeader)

            locationRow
                .padding(.horizontal, 16)

            if hasAdminInfo {
                Divider().padding(.leading, 56)
                adminRow.padding(.horizontal, 16)
            }

            Divider().padding(.leading, 56)
            timeRow.padding(.horizontal, 16)
        }
        .background(Color(.secondarySystemBackground))
    }

    private var locationRow: some View {
        HStack(alignment: .top, spacing: 16) {
            GPSStatusIcon(status: locationIconStatus)
                .frame(width: 40)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 2) {
                Text(coordinateText)
                    .font(.body.monospacedDigit())
                if let acc = viewModel.accuracyM {
                    HStack(spacing: 6) {
                        Text("Genauigkeit").foregroundStyle(.secondary)
                        Text(String(format: "±%.0f m", acc))
                    }
                    .font(.footnote)
                }
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 2) {
                Text("Höhe")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(altitudeText)
                    .font(.body.monospacedDigit())
            }
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(locationA11yLabel)
    }

    private var adminRow: some View {
        HStack(alignment: .top, spacing: 16) {
            Color.clear.frame(width: 40, height: 1)
            VStack(alignment: .leading, spacing: 4) {
                if let admin = adminLines {
                    ForEach(admin, id: \.self) { line in
                        Text(line).font(.body)
                    }
                }
                if let excursionName, !excursionName.isEmpty {
                    HStack(spacing: 6) {
                        Text("Sammeltag")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text(excursionName)
                            .font(.footnote)
                    }
                }
                if let mtb = viewModel.savedSample?.mtbSheetName {
                    Text("MTB \(mtb)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    private var timeRow: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: moonSymbol)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 40)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(longDateText)
                    .font(.body)
                if let sunrise = sunriseText, let sunset = sunsetText {
                    HStack(spacing: 16) {
                        Label(sunrise, systemImage: "sunrise.fill")
                        Label(sunset, systemImage: "sunset.fill")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
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
        adminLines != nil || (excursionName?.isEmpty == false) || viewModel.savedSample?.mtbSheetNumber != nil
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

    private var excursionName: String? {
        if let exc = viewModel.savedExcursion, !exc.name.isEmpty { return exc.name }
        if let id = viewModel.savedSample?.excursion, !id.isEmpty { return "Sammeltag" }
        return nil
    }

    private var moonSymbol: String {
        guard let astro = viewModel.savedExcursion?.astro else { return "moon.stars" }
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
        let date = viewModel.savedSample?.collectedFrom ?? Date()
        return Self.dayFormatter.string(from: date)
    }

    private var sunriseText: String? {
        guard let t = viewModel.savedExcursion?.astro?.sunrise else { return nil }
        return Self.timeFormatter.string(from: t)
    }

    private var sunsetText: String? {
        guard let t = viewModel.savedExcursion?.astro?.sunset else { return nil }
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

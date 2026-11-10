import FieldworksGeo
import SwiftUI

struct SampleDetailView: View {
    /// The detail view can be entered with a `LocalSample` (from a
    /// drill-down where the parent already has the row) or with just an
    /// id (e.g. the home dashboard's "Letzte Probe" shortcut). The
    /// `loadedSample` state mirrors whichever route the user took.
    init(sample: LocalSample) {
        sampleID = sample.id
        _loadedSample = State(initialValue: sample)
    }

    init(sampleID: String) {
        self.sampleID = sampleID
        _loadedSample = State(initialValue: nil)
    }

    private let sampleID: String

    @EnvironmentObject var container: AppContainer
    @State private var loadedSample: LocalSample?
    @State private var photos: [LocalPhoto] = []
    @State private var determinations: [Determination] = []
    @State private var loadingDeterminations = false
    @State private var loadError: String?
    @State private var presentingNew = false
    @State private var editing: Determination?
    @State private var people: [String: Person] = [:] // id → person (for label lookup)

    private let berlin = TimeZone(identifier: "Europe/Berlin") ?? TimeZone.current

    private var sample: LocalSample? {
        loadedSample
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let sample {
                    codeCard(sample)
                    metadataCard(sample)
                    if !sample.notes.isEmpty {
                        notesCard(sample.notes)
                    }
                    if !photos.isEmpty {
                        photoSection
                    }
                    determinationsSection(sample)
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .padding()
        }
        .navigationTitle(sample?.sampleID ?? "Probe")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let sample {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        toggleMarked(currentlyMarked: sample.marked)
                    } label: {
                        Image(systemName: sample.marked ? "star.fill" : "star")
                            .foregroundStyle(sample.marked ? .yellow : .secondary)
                            .accessibilityLabel(sample.marked ? "Markierung entfernen" : "Probe markieren")
                    }
                }
            }
        }
        .task {
            reloadSample()
            reloadPhotos()
            await refreshDeterminations()
        }
        .refreshable {
            reloadSample()
            reloadPhotos()
            await refreshDeterminations()
        }
        .sheet(isPresented: $presentingNew) {
            if let sample {
                DeterminationEditView(
                    mode: .create(sampleID: sample.backendId ?? sample.id),
                    onSaved: { _ in Task { await refreshDeterminations() } },
                    onDeleted: nil
                )
            }
        }
        .sheet(item: $editing) { det in
            DeterminationEditView(
                mode: .edit(existing: det),
                onSaved: { _ in Task { await refreshDeterminations() } },
                onDeleted: { Task { await refreshDeterminations() } }
            )
        }
    }

    private func codeCard(_ sample: LocalSample) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Text(sample.sampleID)
                    .font(AppFont.codeLarge)
                if sample.hasIdConflict {
                    IdConflictHint()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func metadataCard(_ sample: LocalSample) -> some View {
        GroupBox("Probe") {
            VStack(alignment: .leading, spacing: 6) {
                if let lat = sample.latitude, let lon = sample.longitude {
                    Label(String(format: "%.6f, %.6f", lat, lon),
                          systemImage: "mappin.and.ellipse")
                        .font(.body.monospacedDigit())
                }
                if let acc = sample.horizontalAccuracy {
                    Text(String(format: "± %.0f m", acc))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                    Label(timeWindowText(for: sample), systemImage: "calendar")
                        .font(.footnote)
                    Text(SampleTime.timezoneLabel(sampleZone(sample), at: sample.beginDate))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                let placemark = sample.placemark.flatMap { try? container.placemarksStore.fetchById($0) }
                ForEach(placemark.map { PlaceDisplay.fields($0.place) } ?? []) { item in
                    PlaceFieldRow(item)
                }
                if let mtb = PlaceDisplay.mtbText(number: sample.mtbSheetNumber, name: sample.mtbSheetName,
                                                  quadrant: sample.mtbQuadrant, countryISO: placemark?.countryISO)
                {
                    Label(mtb, systemImage: "square.grid.2x2")
                        .font(.footnote)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func notesCard(_ notes: String) -> some View {
        GroupBox("Notizen") {
            Text(notes)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var photoSection: some View {
        GroupBox("Fotos") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(Array(photos.enumerated()), id: \.element.id) { idx, photo in
                        SamplePhotoThumbnail(
                            relativePath: photo.localPath,
                            accessibilityLabel: "Foto \(idx + 1) von \(photos.count)"
                        )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func determinationsSection(_ sample: LocalSample) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Bestimmungen")
                        .font(.headline)
                    Spacer()
                    Button {
                        presentingNew = true
                    } label: {
                        Label("Neu", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(sample.backendId == nil)
                }

                if sample.backendId == nil {
                    Text("Bestimmung erst nach erfolgtem Sync möglich.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if loadingDeterminations && determinations.isEmpty {
                    ProgressView()
                } else if determinations.isEmpty {
                    Text("Noch keine Bestimmung.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(determinations) { det in
                        Button { editing = det } label: { determinationRow(det) }
                            .buttonStyle(.plain)
                        if det != determinations.last { Divider() }
                    }
                }

                if let err = loadError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func determinationRow(_ det: Determination) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(det.kind.labelShort)
                .font(.system(.body, design: .monospaced))
                .frame(width: 40, alignment: .leading)
                .foregroundStyle(det.kind == .det ? .primary : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(det.speciesText)
                    .font(.body.italic())
                HStack(spacing: 6) {
                    if let id = det.person, let p = people[id], !p.abbreviation.isEmpty {
                        Text(p.abbreviation)
                    }
                    if let on = det.determinedOn {
                        Text(shortDate(on))
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                if !det.notes.isEmpty {
                    Text(det.notes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    // MARK: - Helpers

    private func sampleZone(_ sample: LocalSample) -> TimeZone {
        TimeZone(identifier: sample.timezone) ?? berlin
    }

    /// „19.05.2026 12:00 – 12:15“ in the sample's zone; the end carries
    /// its date when it falls on another local day.
    private func timeWindowText(for sample: LocalSample) -> String {
        let zone = sampleZone(sample)
        let full = DateFormatter()
        full.timeZone = zone
        full.dateFormat = "dd.MM.yyyy HH:mm"
        let begin = full.string(from: sample.beginDate)
        guard let end = sample.endDate, end != sample.beginDate else { return begin }
        let sameDay = full.string(from: end).prefix(10) == begin.prefix(10)
        if sameDay {
            let timeOnly = DateFormatter()
            timeOnly.timeZone = zone
            timeOnly.dateFormat = "HH:mm"
            return "\(begin) – \(timeOnly.string(from: end))"
        }
        return "\(begin) – \(full.string(from: end))"
    }

    private func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = berlin
        formatter.dateFormat = "dd.MM.yyyy"
        return formatter.string(from: date)
    }

    private func reloadSample() {
        if let fresh = try? container.store.fetchById(sampleID) {
            loadedSample = fresh
        }
    }

    /// Flips the star: writes the new state locally for an instant UI
    /// update, then fire-and-forget PATCHes the backend if the sample
    /// has already been pushed. Failures are logged but not surfaced
    /// — the local state remains the source of truth, and the next
    /// hydrate-pull will reconcile if the server disagrees.
    private func toggleMarked(currentlyMarked: Bool) {
        let next = !currentlyMarked
        try? container.store.setMarked(id: sampleID, marked: next)
        reloadSample()

        guard let backendID = loadedSample?.backendId, !backendID.isEmpty else { return }
        Task {
            let client = SampleClient(
                endpoint: container.config.endpointURL,
                auth: container.auth
            )
            do {
                _ = try await client.setMarked(id: backendID, marked: next)
            } catch {
                Log.sync.error("toggle marked PATCH failed: \(error.localizedDescription)")
            }
        }
    }

    private func reloadPhotos() {
        photos = (try? container.photos.fetchBySample(sampleID)) ?? []
    }

    private func refreshDeterminations() async {
        guard let sample, let backendID = sample.backendId else { return }
        loadingDeterminations = true
        defer { loadingDeterminations = false }
        do {
            let detClient = DeterminationClient(endpoint: container.config.endpointURL, auth: container.auth)
            let list = try await detClient.listBySample(backendID)
            determinations = list
            loadError = nil
            await refreshPeopleCache(forIDs: Set(list.compactMap(\.person)))
        } catch let err as SampleClientError {
            loadError = err.errorDescription
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func refreshPeopleCache(forIDs ids: Set<String>) async {
        let missing = ids.subtracting(people.keys)
        guard !missing.isEmpty else { return }
        if let all = try? await PersonClient(endpoint: container.config.endpointURL, auth: container.auth).listAll() {
            for p in all where ids.contains(p.id) {
                people[p.id] = p
            }
        }
    }
}

/// Decodes a JPEG file from PhotoStorage and renders it as a fixed-size
/// thumbnail. Lazy-loads on `.task` so a long photo strip doesn't block
/// the parent's first frame.
private struct SamplePhotoThumbnail: View {
    let relativePath: String
    let accessibilityLabel: String

    // Foto-Thumbnail-Größe ist domänenspezifisch (Sample-Detail-Strip)
    // — kein globales Token, lokales `@ScaledMetric`.
    @ScaledMetric(relativeTo: .body) private var thumbSize: CGFloat = 84
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle()
                    .fill(AppColor.surfaceSecondary)
            }
        }
        .frame(width: thumbSize, height: thumbSize)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
        .accessibilityLabel(accessibilityLabel)
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

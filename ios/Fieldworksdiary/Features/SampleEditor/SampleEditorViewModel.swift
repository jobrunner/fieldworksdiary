import CoreLocation
import Foundation
import UIKit

/// Holds the in-progress / saved state for one sample in the editor.
/// Replaces the old `AddSampleViewModel` — the editor is now a single
/// view that handles both the create flow (sample id == nil) and an
/// already-saved sample.
///
/// Lifecycle:
///   1. View appears with `sampleID == nil` → constructor seeds `code`
///      from the local sequence preview and starts GPS.
///   2. User edits `code`, `notes`, captures `pendingPhotos`. GPS fix
///      lands on `coordinate` whenever it arrives.
///   3. User taps "Speichern" → `save()` writes the local row +
///      photos, kicks the sync, switches the VM into "savedSample"
///      mode and starts observing enrichment.
///   4. The bottom enrichment fields (admin units, excursion, astro)
///      stream in as the SyncRunner round-trips. The notes field is
///      never overwritten — it's purely user-owned.
@MainActor
final class SampleEditorViewModel: ObservableObject {
    /// Photo not yet persisted to disk. We keep it in memory until
    /// `save()` so a dismissed editor leaves no orphans on disk.
    struct PendingPhoto: Identifiable, Equatable {
        let id: String
        let image: UIImage

        static func == (lhs: PendingPhoto, rhs: PendingPhoto) -> Bool { lhs.id == rhs.id }
    }

    @Published var code: String = ""
    @Published var notes: String = ""
    @Published var pendingPhotos: [PendingPhoto] = []
    @Published private(set) var locationStatus: LocationProvider.Status = .idle
    /// Best-known coordinate for the bottom card. Either the live GPS
    /// fix or — once saved — the persisted sample's coord.
    @Published private(set) var coordinate: CLLocationCoordinate2D?
    @Published private(set) var accuracyM: Double?
    @Published private(set) var altitudeM: Double?
    /// nil while the sample lives only in the editor; populated once
    /// `save()` writes the row.
    @Published private(set) var savedSample: LocalSample?
    @Published private(set) var savedPhotos: [LocalPhoto] = []
    @Published private(set) var savedExcursion: LocalExcursion?
    @Published private(set) var saveError: String?
    @Published private(set) var isSaving = false

    private let store: LocalSampleStore
    private let photoStore: LocalPhotoStore
    private let excursionStore: LocalExcursionStore
    private let sync: SyncRunner
    private let location: LocationProvider

    private var observerTask: Task<Void, Never>?

    init(
        sampleID: String?,
        store: LocalSampleStore,
        photoStore: LocalPhotoStore,
        excursionStore: LocalExcursionStore,
        sync: SyncRunner
    ) {
        self.store = store
        self.photoStore = photoStore
        self.excursionStore = excursionStore
        self.sync = sync
        self.location = LocationProvider()

        if let sampleID, let existing = try? store.fetchById(sampleID) {
            adoptExisting(existing)
        } else {
            // Seed the code field with the would-be sequence so the
            // user starts with a sensible default instead of an empty
            // text field. They can still edit if they want.
            code = store.peekNextCode()
        }
    }

    deinit { observerTask?.cancel() }

    var isExistingSample: Bool { savedSample != nil }

    var canSave: Bool {
        if isExistingSample { return false }
        if isSaving { return false }
        if coordinate == nil { return false }
        if code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        return true
    }

    // MARK: - GPS

    func startGPS() {
        // Only relevant on the create path; for existing samples the
        // coordinate is already in `savedSample`.
        guard savedSample == nil else { return }
        location.requestFix()
        observeLocation()
    }

    private func observeLocation() {
        observerTask?.cancel()
        observerTask = Task { [weak self] in
            guard let self else { return }
            for await status in self.location.$status.values {
                if Task.isCancelled { return }
                self.locationStatus = status
                if case let .fixed(loc) = status {
                    self.coordinate = loc.coordinate
                    self.accuracyM = loc.horizontalAccuracy >= 0 ? loc.horizontalAccuracy : nil
                    self.altitudeM = loc.verticalAccuracy >= 0 ? loc.altitude : nil
                }
            }
        }
    }

    func retryGPS() {
        location.requestFix()
    }

    // MARK: - photos

    func addPhoto(_ image: UIImage) {
        pendingPhotos.append(PendingPhoto(id: UUID().uuidString, image: image))
    }

    func removePendingPhoto(id: String) {
        pendingPhotos.removeAll { $0.id == id }
    }

    // MARK: - save

    func save() async {
        guard let coordinate else { return }
        guard !isSaving else { return }

        isSaving = true
        defer { isSaving = false }
        saveError = nil

        let userCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let sample = try store.createLocal(
                lat: coordinate.latitude,
                lon: coordinate.longitude,
                accuracy: accuracyM,
                altitude: altitudeM,
                notes: trimmedNotes,
                overrideCode: userCode == store.peekNextCode() ? nil : userCode
            )
            try persistPhotos(for: sample)
            adoptExisting(sample)
            sync.kick()
            startObservingSync(sampleID: sample.id)
        } catch {
            saveError = error.localizedDescription
        }
    }

    // MARK: - private

    /// Writes the captured JPEGs to disk + inserts photo rows. Same
    /// best-effort semantics as the old AddSampleViewModel: a failure
    /// on one photo doesn't kill the whole save, since the sample is
    /// already persisted.
    private func persistPhotos(for sample: LocalSample) throws {
        for pending in pendingPhotos {
            do {
                let path = try PhotoStorage.write(
                    image: pending.image,
                    sampleID: sample.id,
                    photoID: pending.id
                )
                let now = Date()
                let photo = LocalPhoto(
                    id: pending.id,
                    sampleId: sample.id,
                    localPath: path,
                    backendId: nil,
                    syncStatus: .pending,
                    syncError: nil,
                    clientUuid: pending.id,
                    clientUpdatedAt: now,
                    createdAt: now
                )
                try photoStore.insert(photo)
            } catch {
                Log.persistence.error("photo persist failed: \(error.localizedDescription)")
            }
        }
    }

    private func adoptExisting(_ sample: LocalSample) {
        savedSample = sample
        code = sample.code
        notes = sample.notes
        coordinate = CLLocationCoordinate2D(latitude: sample.lat, longitude: sample.lon)
        accuracyM = sample.accuracyM
        altitudeM = sample.altitudeM
        savedPhotos = (try? photoStore.fetchBySample(sample.id)) ?? []
        if let excID = sample.excursion, !excID.isEmpty {
            savedExcursion = try? excursionStore.fetchById(excID)
        }
        pendingPhotos = []
    }

    /// Polls the store for the just-created sample so the bottom
    /// section refreshes as the sync round-trip + enrichment land.
    /// Doesn't touch `notes` or `code` — those are user-owned.
    private func startObservingSync(sampleID: String) {
        observerTask?.cancel()
        observerTask = Task { [weak self] in
            for _ in 0 ..< 60 {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                guard let self else { return }
                if let fresh = try? self.store.fetchById(sampleID), fresh != self.savedSample {
                    self.savedSample = fresh
                    self.coordinate = CLLocationCoordinate2D(latitude: fresh.lat, longitude: fresh.lon)
                    self.accuracyM = fresh.accuracyM
                    self.altitudeM = fresh.altitudeM
                    if let excID = fresh.excursion, !excID.isEmpty {
                        self.savedExcursion = try? self.excursionStore.fetchById(excID)
                    }
                    if fresh.syncStatus == .synced,
                       fresh.adminUnitsLocality != nil || fresh.mtbSheetNumber != nil
                    {
                        return
                    }
                }
            }
        }
    }
}

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
///   4. The bottom enrichment fields (admin units, fieldtrip, astro)
///      stream in as the SyncRunner round-trips. The notes field is
///      never overwritten — it's purely user-owned.
@MainActor
final class SampleEditorViewModel: ObservableObject {
    /// Photo not yet persisted to disk. We keep it in memory until
    /// `save()` so a dismissed editor leaves no orphans on disk.
    struct PendingPhoto: Identifiable, Equatable {
        let id: String
        let image: UIImage

        static func == (lhs: PendingPhoto, rhs: PendingPhoto) -> Bool {
            lhs.id == rhs.id
        }
    }

    /// How the sample's location is obtained (Spec §7 / R8d).
    /// `.planned` (a sample pre-staged before going out) is R11 — not
    /// offered yet.
    enum Mode: Equatable {
        /// Live GPS fix → coordinate is `location_service`-sourced and
        /// gets offline-fused against existing localities.
        case field
        /// Coordinate entered by hand on a map → `user`-sourced, no
        /// fusion (the user is curating, not collecting in place).
        case later
    }

    /// Drives GPS start/stop and whether `save()` runs offline fusion.
    @Published var mode: Mode = .field {
        didSet { handleModeChange(from: oldValue) }
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
    @Published private(set) var savedFieldtrip: LocalFieldtrip?
    @Published private(set) var saveError: String?
    @Published private(set) var isSaving = false

    private let store: LocalSampleStore
    private let photoStore: LocalPhotoStore
    private let fieldtripStore: LocalFieldtripStore
    private let localitiesStore: LocalLocalityStore
    private let mutationsStore: PendingMutationsStore
    private let sync: SyncRunner
    private let location: LocationProvider

    private var observerTask: Task<Void, Never>?

    init(
        sampleID: String?,
        store: LocalSampleStore,
        photoStore: LocalPhotoStore,
        fieldtripStore: LocalFieldtripStore,
        localitiesStore: LocalLocalityStore,
        mutationsStore: PendingMutationsStore,
        sync: SyncRunner
    ) {
        self.store = store
        self.photoStore = photoStore
        self.fieldtripStore = fieldtripStore
        self.localitiesStore = localitiesStore
        self.mutationsStore = mutationsStore
        self.sync = sync
        location = LocationProvider()

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

    var isExistingSample: Bool {
        savedSample != nil
    }

    var canSave: Bool {
        if isExistingSample { return false }
        if isSaving { return false }
        if coordinate == nil { return false }
        if code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        return true
    }

    // MARK: - GPS

    func startGPS() {
        // Only relevant on the create path in field mode; for existing
        // samples the coordinate is already in `savedSample`, and in
        // `.later` mode the user picks the coordinate by hand.
        guard savedSample == nil, mode == .field else { return }
        location.requestFix()
        observeLocation()
    }

    /// Manual coordinate for `.later` mode (picked on the map). Clears
    /// the GPS-derived accuracy/altitude — those don't apply to a
    /// hand-placed point.
    func setManualCoordinate(latitude: Double, longitude: Double) {
        coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        accuracyM = nil
        altitudeM = nil
    }

    private func handleModeChange(from previous: Mode) {
        guard previous != mode, savedSample == nil else { return }
        switch mode {
        case .field:
            startGPS()
        case .later:
            // Stop listening to GPS; keep whatever coordinate is shown
            // so a quick toggle doesn't lose the user's pick.
            observerTask?.cancel()
            observerTask = nil
        }
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
                overrideCode: userCode == store.peekNextCode() ? nil : userCode,
                locationSource: mode == .field ? .locationService : .user
            )
            try persistPhotos(for: sample)
            // Offline fusion only for live GPS samples (Spec §5.1):
            // attach to a nearby locality or spin up a fresh one.
            if mode == .field {
                try? attachFusedLocality(
                    to: sample,
                    latitude: coordinate.latitude,
                    longitude: coordinate.longitude
                )
            }
            // Re-read so `adoptExisting` reflects the locality we just set.
            let fresh = (try? store.fetchById(sample.id)) ?? sample
            adoptExisting(fresh)
            sync.kick()
            startObservingSync(sampleID: sample.id)
        } catch {
            saveError = error.localizedDescription
        }
    }

    /// Runs the trivial offline-fusion (R6.3) against the local
    /// localities. A hit re-uses that locality; a miss creates a new
    /// local one and enqueues its `.locality/.create` mutation so the
    /// SyncRunner pushes it (FK-ordered before the sample). Either way
    /// the sample is re-pointed at the resulting locality id.
    private func attachFusedLocality(to sample: LocalSample, latitude: Double, longitude: Double) throws {
        let candidates: [LocalityFusion.Candidate] = ((try? localitiesStore.fetchAll()) ?? [])
            .compactMap { loc in
                guard let lat = loc.latitude ?? loc.centroidLat,
                      let lon = loc.longitude ?? loc.centroidLon else { return nil }
                return LocalityFusion.Candidate(id: loc.id, latitude: lat, longitude: lon)
            }

        let localityID: String
        if let match = LocalityFusion.offlineFuseLocality(
            sampleLatitude: latitude,
            sampleLongitude: longitude,
            candidates: candidates
        ) {
            localityID = match.id
        } else {
            let newLocal = try localitiesStore.createLocal(
                latitude: latitude,
                longitude: longitude,
                locationSource: .locationService
            )
            _ = try mutationsStore.enqueue(
                entityType: .locality,
                entityId: newLocal.id,
                op: .create,
                payload: Data()
            )
            localityID = newLocal.id
        }

        var working = sample
        working.locality = localityID
        try store.update(working)
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
        code = sample.sampleID
        notes = sample.notes
        if let lat = sample.latitude, let lon = sample.longitude {
            coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        } else {
            coordinate = nil
        }
        accuracyM = sample.horizontalAccuracy
        altitudeM = sample.altitude
        savedPhotos = (try? photoStore.fetchBySample(sample.id)) ?? []
        if let ftID = sample.fieldtrip, !ftID.isEmpty {
            savedFieldtrip = try? fieldtripStore.fetchById(ftID)
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
                    if let lat = fresh.latitude, let lon = fresh.longitude {
                        self.coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                    }
                    self.accuracyM = fresh.horizontalAccuracy
                    self.altitudeM = fresh.altitude
                    if let ftID = fresh.fieldtrip, !ftID.isEmpty {
                        self.savedFieldtrip = try? self.fieldtripStore.fetchById(ftID)
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

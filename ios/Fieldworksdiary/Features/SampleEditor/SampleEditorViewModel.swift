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
    /// Vertical accuracy of `altitudeM` from the GPS fix; stored on the
    /// sample as `vertical_accuracy`.
    private var verticalAccuracyM: Double?
    /// nil while the sample lives only in the editor; populated once
    /// `save()` writes the row.
    @Published private(set) var savedSample: LocalSample?
    @Published private(set) var savedPhotos: [LocalPhoto] = []
    @Published private(set) var savedFieldtrip: LocalFieldtrip?
    @Published private(set) var saveError: String?
    @Published private(set) var isSaving = false
    /// Inline validation hint for the code field. Set by `recheckCode`
    /// (called from the view on every keystroke). nil means "looks
    /// fine" — display nothing.
    @Published private(set) var codeValidationError: String?

    /// Snapshot of the persisted values at the moment we adopted an
    /// existing row. Drives dirty-detection so the save button only
    /// lights up after the user actually changes something.
    private var originalCode: String = ""
    private var originalNotes: String = ""

    private let store: LocalSampleStore
    private let photoStore: LocalPhotoStore
    private let fieldtripStore: LocalFieldtripStore
    private let localitiesStore: LocalLocalityStore
    private let mutationsStore: PendingMutationsStore
    private let sync: SyncRunner
    private let location: LocationProvider
    /// On-device place resolution after save (Phase O2). nil skips it
    /// (tests that don't care about place data).
    private let locationResolver: SampleLocationResolver?

    private var observerTask: Task<Void, Never>?

    init(
        sampleID: String?,
        store: LocalSampleStore,
        photoStore: LocalPhotoStore,
        fieldtripStore: LocalFieldtripStore,
        localitiesStore: LocalLocalityStore,
        mutationsStore: PendingMutationsStore,
        sync: SyncRunner,
        locationResolver: SampleLocationResolver? = nil
    ) {
        self.store = store
        self.photoStore = photoStore
        self.fieldtripStore = fieldtripStore
        self.localitiesStore = localitiesStore
        self.mutationsStore = mutationsStore
        self.sync = sync
        self.locationResolver = locationResolver
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

    /// True when at least one user-editable field differs from the
    /// adopted snapshot, or new (unsaved) photos are queued.
    var hasUnsavedEdits: Bool {
        guard isExistingSample else { return false }
        let trimmedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedCode != originalCode { return true }
        if trimmedNotes != originalNotes { return true }
        if !pendingPhotos.isEmpty { return true }
        return false
    }

    var canSave: Bool {
        if isSaving { return false }
        if code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        if codeValidationError != nil { return false }
        if isExistingSample {
            return hasUnsavedEdits
        }
        // Create path: need a coordinate.
        return coordinate != nil
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
        verticalAccuracyM = nil
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
                    let fix = LocationProvider.Fix(loc)
                    self.coordinate = CLLocationCoordinate2D(latitude: fix.latitude, longitude: fix.longitude)
                    self.accuracyM = fix.horizontalAccuracy
                    self.altitudeM = fix.elevation
                    self.verticalAccuracyM = fix.verticalAccuracy
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

    // MARK: - marked toggle

    /// Flips the star on the adopted sample. Writes the local row
    /// instantly so the UI updates without waiting on the network,
    /// then PATCHes the backend if the row has a backend id. After
    /// the response we adopt the server's bumped `version` locally —
    /// otherwise the next `saveEdits` would send a stale counter
    /// (the server bumps via the legacy `incoming == 0` path of
    /// `enforceVersion`) and get 409'd, losing the user's edit.
    func toggleMarked(endpoint: String, auth: AuthSession?) {
        guard var working = savedSample else { return }
        let next = !working.marked
        do {
            try store.setMarked(id: working.id, marked: next)
        } catch {
            Log.persistence.error("toggle marked write failed: \(error.localizedDescription)")
            return
        }
        working.marked = next
        savedSample = working

        guard let backendID = working.backendId, !backendID.isEmpty else { return }
        let client = SampleClient(endpoint: endpoint, auth: auth)
        let localID = working.id
        Task { [weak self] in
            do {
                let updated = try await client.setMarked(id: backendID, marked: next)
                await MainActor.run {
                    guard let self else { return }
                    guard var fresh = try? self.store.fetchById(localID) else { return }
                    fresh.version = updated.version
                    try? self.store.update(fresh)
                    if self.savedSample?.id == localID {
                        self.savedSample = fresh
                    }
                }
            } catch {
                Log.sync.error("toggle marked PATCH failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - code validation

    /// Recomputes `codeValidationError`. Called from the view on
    /// every keystroke (cheap — regex + an indexed `sample_id`
    /// lookup). Empty input is treated as "still typing" → nil so
    /// the field doesn't shout at the user while they edit.
    func recheckCode() {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            codeValidationError = nil
            return
        }
        if trimmed.range(of: #"^\d{6}/\d+$"#, options: .regularExpression) == nil {
            codeValidationError = "Format: YYMMDD/Nr (z. B. 260605/3)."
            return
        }
        if (try? store.findByCode(trimmed, excludingId: savedSample?.id)) != nil {
            codeValidationError = "Code ist bereits an einer anderen Probe vergeben."
            return
        }
        codeValidationError = nil
    }

    // MARK: - save

    /// Persists user edits (code, notes, new photos) on a sample
    /// that's already been adopted via `init(sampleID:…)`. Idempotent:
    /// re-running with no further changes is a no-op (`canSave` blocks
    /// the button in that case anyway).
    func saveEdits() async {
        guard isExistingSample, !isSaving, var working = savedSample else { return }
        recheckCode()
        if codeValidationError != nil { return }

        isSaving = true
        defer { isSaving = false }
        saveError = nil

        working.sampleID = code.trimmingCharacters(in: .whitespacesAndNewlines)
        working.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try store.saveEdits(working, mutationsStore: mutationsStore)
            try persistPhotos(for: working)
            let fresh = (try? store.fetchById(working.id)) ?? working
            adoptExisting(fresh)
            sync.kick()
            // The push round-trip may rewrite the code (collision) or
            // refresh enrichment fields. Re-use the create-path's
            // background poller to surface those updates.
            startObservingSync(sampleID: working.id)
        } catch {
            saveError = error.localizedDescription
        }
    }

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
                verticalAccuracy: verticalAccuracyM,
                elevation: altitudeM,
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
            startObservingSync(sampleID: sample.id)
            resolveLocationThenSync(sampleID: sample.id)
        } catch {
            saveError = error.localizedDescription
        }
    }

    /// Runs after the sample is persisted, so Ortus can never block or
    /// fail the save. Online → Ortus fills place/features/MTB right
    /// away; otherwise the place is inherited from the previous sample
    /// of the collecting day. The sync is kicked afterwards (at most
    /// the 5 s Ortus timeout later) so the create push already carries
    /// the place data. The task deliberately doesn't capture `self`:
    /// it must finish even if the editor is dismissed meanwhile.
    private func resolveLocationThenSync(sampleID: String) {
        guard let resolver = locationResolver else {
            sync.kick()
            return
        }
        let sync = self.sync
        Task { [weak self] in
            let resolved = await resolver.resolveOnline(sampleID: sampleID)
            if !resolved {
                do {
                    try resolver.inheritOffline(sampleID: sampleID)
                } catch {
                    Log.persistence.error("offline place inheritance failed: \(error.localizedDescription)")
                }
            }
            sync.kick()
            self?.refreshDerivedFields()
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

    /// Re-reads the persisted row + photos + fieldtrip without
    /// disturbing the user's in-progress edits (code/notes are
    /// `@Published` and considered user-owned). Used on view appear
    /// and on pull-to-refresh so background sync updates (enrichment,
    /// newly-pulled photos, backend id arriving) become visible
    /// without having to leave the editor.
    func refreshDerivedFields() {
        guard let id = savedSample?.id, let fresh = try? store.fetchById(id) else { return }
        savedSample = fresh
        savedPhotos = (try? photoStore.fetchBySample(id)) ?? []
        if let ftID = fresh.fieldtrip, !ftID.isEmpty {
            savedFieldtrip = try? fieldtripStore.fetchById(ftID)
        } else {
            savedFieldtrip = nil
        }
        if let lat = fresh.latitude, let lon = fresh.longitude {
            coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
        accuracyM = fresh.horizontalAccuracy
        altitudeM = fresh.elevation
    }

    private func adoptExisting(_ sample: LocalSample) {
        savedSample = sample
        // Snapshot the *trimmed* persisted values for dirty-detection —
        // legacy/imported rows with stray whitespace would otherwise
        // open the editor as already-dirty, since `hasUnsavedEdits`
        // compares trimmed user input against these.
        let trimmedCode = sample.sampleID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNotes = sample.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        code = trimmedCode
        notes = trimmedNotes
        originalCode = trimmedCode
        originalNotes = trimmedNotes
        if let lat = sample.latitude, let lon = sample.longitude {
            coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        } else {
            coordinate = nil
        }
        accuracyM = sample.horizontalAccuracy
        altitudeM = sample.elevation
        savedPhotos = (try? photoStore.fetchBySample(sample.id)) ?? []
        if let ftID = sample.fieldtrip, !ftID.isEmpty {
            savedFieldtrip = try? fieldtripStore.fetchById(ftID)
        }
        pendingPhotos = []
        codeValidationError = nil
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
                    self.altitudeM = fresh.elevation
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

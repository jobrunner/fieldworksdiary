import Foundation
import CoreLocation

@MainActor
final class AddSampleViewModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case savingLocal
        case localSaved(LocalSample)
        case error(String)
    }

    @Published var phase: Phase = .idle
    @Published private(set) var lastFix: CLLocation?

    private let store: LocalSampleStore
    private let sync: SyncRunner
    private var observerTask: Task<Void, Never>?

    init(store: LocalSampleStore, sync: SyncRunner) {
        self.store = store
        self.sync = sync
    }

    deinit { observerTask?.cancel() }

    func update(from status: LocationProvider.Status) {
        if case .fixed(let loc) = status {
            lastFix = loc
        }
    }

    /// Submits a new sample. If `overrideCoordinate` is provided it
    /// takes precedence over the latest GPS fix (manual map pin); in
    /// that case we deliberately drop accuracy/altitude — they aren't
    /// known for a user-chosen point.
    func submit(overrideCoordinate: CLLocationCoordinate2D? = nil) async {
        let lat: Double
        let lon: Double
        let accuracy: Double?
        let altitude: Double?

        if let override = overrideCoordinate {
            lat = override.latitude
            lon = override.longitude
            accuracy = nil
            altitude = nil
        } else if let loc = lastFix {
            lat = loc.coordinate.latitude
            lon = loc.coordinate.longitude
            accuracy = loc.horizontalAccuracy >= 0 ? loc.horizontalAccuracy : nil
            altitude = loc.verticalAccuracy >= 0 ? loc.altitude : nil
        } else {
            phase = .error("Weder GPS-Fix noch manuelle Koordinate.")
            return
        }

        phase = .savingLocal
        do {
            let sample = try store.createLocal(
                lat: lat, lon: lon,
                accuracy: accuracy, altitude: altitude
            )
            phase = .localSaved(sample)
            sync.kick()
            startObservingChanges(sampleID: sample.id)
        } catch {
            phase = .error(error.localizedDescription)
        }
    }

    func reset() {
        observerTask?.cancel()
        observerTask = nil
        phase = .idle
    }

    func retrySync() {
        sync.kick()
    }

    /// Polls the store for the just-created sample and lifts updates
    /// to `phase`. Stops automatically when the row is fully synced
    /// and enriched, or after a 60 s budget.
    private func startObservingChanges(sampleID: String) {
        observerTask?.cancel()
        observerTask = Task { [weak self] in
            for _ in 0..<60 {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                guard let self else { return }
                guard case .localSaved(let current) = self.phase else { return }
                if let updated = try? self.store.fetchById(sampleID), updated != current {
                    self.phase = .localSaved(updated)
                    if updated.syncStatus == .synced
                        && (updated.adminUnitsLocality != nil || updated.mtbSheetNumber != nil) {
                        return
                    }
                }
            }
        }
    }
}

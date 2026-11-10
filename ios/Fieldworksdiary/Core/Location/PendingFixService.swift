import CoreLocation
import Foundation

/// Source of GPS fixes for `PendingFixService`. Abstracted so tests can
/// feed fixes without CoreLocation.
@MainActor
protocol PendingFixSource: AnyObject {
    /// Called for every fix the source considers fresh. The service
    /// applies the accuracy threshold itself.
    var onFix: (@MainActor (LocationProvider.Fix) -> Void)? { get set }
    func start()
    func stop()
}

/// Fills the coordinate of samples that were created without one
/// (instant creation, Phase E): keeps locating — also with the app in
/// the background when the user granted „Immer“ — until each registered
/// sample got its first usable fix, then stops. One fix may serve
/// several samples; every sample is written exactly once. Gives up
/// after `timeLimit` per sample.
///
/// Writes through `LocalSampleStore.updateCoordinate` (location source
/// GPS), the existing path that clears derived values and queues the
/// sync. `onCoordinateSet` lets the app run place resolution and kick
/// the sync afterwards. Samples that got a coordinate meanwhile (map
/// pick) are skipped. Coordinates are never logged.
@MainActor
final class PendingFixService {
    /// Per-sample limit for waiting on a fix: 5 minutes.
    static let timeLimit: TimeInterval = 5 * 60

    private let store: LocalSampleStore
    private let mutations: PendingMutationsStore
    private let source: PendingFixSource
    private let now: () -> Date
    private let timerInterval: TimeInterval?
    private let onCoordinateSet: (String) -> Void

    /// Local sample id -> creation instant.
    private var pending: [String: Date] = [:]
    private var timer: Task<Void, Never>?

    /// - Parameter timerInterval: how often the production timer checks
    ///   for overdue samples; nil disables the timer (tests call
    ///   `expireOverdue()` with a fake clock).
    init(
        store: LocalSampleStore,
        mutations: PendingMutationsStore,
        source: PendingFixSource,
        now: @escaping () -> Date = Date.init,
        timerInterval: TimeInterval? = 30,
        onCoordinateSet: @escaping (String) -> Void = { _ in }
    ) {
        self.store = store
        self.mutations = mutations
        self.source = source
        self.now = now
        self.timerInterval = timerInterval
        self.onCoordinateSet = onCoordinateSet
        source.onFix = { [weak self] fix in self?.handle(fix) }
    }

    deinit { timer?.cancel() }

    /// Number of samples still waiting for a fix (tests, diagnostics).
    var pendingCount: Int { pending.count }

    /// Starts waiting for a fix for a sample created at `createdAt`
    /// without coordinate.
    func register(sampleID: String, createdAt: Date) {
        guard now().timeIntervalSince(createdAt) < Self.timeLimit else {
            Log.location.info("pending fix not started, sample \(sampleID, privacy: .public) too old")
            return
        }
        pending[sampleID] = createdAt
        updateLocating()
    }

    /// App became active: re-register samples without coordinate that
    /// are younger than the time limit (the process may have been
    /// killed while waiting).
    func resumePending() {
        let cutoff = now().addingTimeInterval(-Self.timeLimit)
        do {
            for sample in try store.fetchWithoutCoordinate(createdAfter: cutoff)
            where pending[sample.id] == nil {
                pending[sample.id] = sample.createdAt
            }
        } catch {
            Log.persistence.error("pending fix resume failed: \(error.localizedDescription)")
        }
        expireOverdue()
        updateLocating()
    }

    /// Drops samples that waited longer than `timeLimit`.
    func expireOverdue() {
        let current = now()
        for (id, createdAt) in pending where current.timeIntervalSince(createdAt) >= Self.timeLimit {
            pending[id] = nil
            Log.location.warning("gave up waiting for a fix, sample \(id, privacy: .public)")
        }
        updateLocating()
    }

    // MARK: - private

    private func handle(_ fix: LocationProvider.Fix) {
        expireOverdue()
        guard let accuracy = fix.horizontalAccuracy,
              accuracy <= LocationThreshold.horizontalAccuracy
        else { return }
        for id in Array(pending.keys) {
            apply(fix, to: id)
        }
        updateLocating()
    }

    private func apply(_ fix: LocationProvider.Fix, to id: String) {
        do {
            guard let sample = try store.fetchById(id) else {
                pending[id] = nil
                return
            }
            if sample.hasCoordinate {
                pending[id] = nil
                Log.location.info("pending fix skipped, sample \(id, privacy: .public) has a coordinate")
                return
            }
            try store.updateCoordinate(
                id: id,
                latitude: fix.latitude,
                longitude: fix.longitude,
                horizontalAccuracy: fix.horizontalAccuracy,
                verticalAccuracy: fix.verticalAccuracy,
                elevation: fix.elevation,
                locationSource: .locationService,
                mutationsStore: mutations
            )
            pending[id] = nil
            Log.location.info("pending fix applied to sample \(id, privacy: .public)")
            onCoordinateSet(id)
        } catch {
            // Stays pending: the next fix retries.
            Log.persistence.error("pending fix write failed: \(error.localizedDescription)")
        }
    }

    private func updateLocating() {
        if pending.isEmpty {
            source.stop()
            timer?.cancel()
            timer = nil
        } else {
            source.start()
            startTimerIfNeeded()
        }
    }

    private func startTimerIfNeeded() {
        guard timer == nil, let interval = timerInterval else { return }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if Task.isCancelled { return }
                self?.expireOverdue()
            }
        }
    }
}

/// CoreLocation-backed `PendingFixSource`. Runs in the background only
/// with „Immer“ authorization; after the first `whenInUse` grant it
/// asks once for „Immer“.
@MainActor
final class BackgroundFixSource: NSObject, PendingFixSource {
    var onFix: (@MainActor (LocationProvider.Fix) -> Void)?

    private static let askedAlwaysKey = "location.askedAlwaysAuthorization"

    private let manager = CLLocationManager()
    private let defaults: UserDefaults
    private var running = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    func start() {
        guard !running else { return }
        running = true
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            begin()
        default:
            Log.location.info("background fix not started, no location permission")
        }
    }

    func stop() {
        guard running else { return }
        running = false
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
    }

    private func begin() {
        let status = manager.authorizationStatus
        if status == .authorizedAlways {
            manager.pausesLocationUpdatesAutomatically = false
            manager.allowsBackgroundLocationUpdates = true
        } else if status == .authorizedWhenInUse, !defaults.bool(forKey: Self.askedAlwaysKey) {
            defaults.set(true, forKey: Self.askedAlwaysKey)
            manager.requestAlwaysAuthorization()
        }
        manager.startUpdatingLocation()
    }
}

extension BackgroundFixSource: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            guard running else { return }
            switch manager.authorizationStatus {
            case .authorizedAlways, .authorizedWhenInUse:
                begin()
            default:
                break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last,
              abs(loc.timestamp.timeIntervalSinceNow) <= LocationThreshold.staleness
        else { return }
        let fix = LocationProvider.Fix(loc)
        Task { @MainActor in
            onFix?(fix)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // kCLErrorLocationUnknown is transient; the service's time limit
        // ends the attempt otherwise.
        if let clErr = error as? CLError, clErr.code == .locationUnknown { return }
        Task { @MainActor in
            Log.location.error("background fix failed: \(error.localizedDescription)")
        }
    }
}

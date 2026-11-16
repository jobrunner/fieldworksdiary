import CoreLocation
import Foundation

/// Source of GPS fixes for `PendingFixService`. Abstracted so tests can
/// feed fixes without CoreLocation.
@MainActor
protocol PendingFixSource: AnyObject {
    /// Called for every fix the source considers fresh. The service
    /// applies the accuracy part of `LocationThreshold.accepts` itself.
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
/// Only samples registered on *this device* are ever touched: every
/// registration is persisted (sample id, user id, creation instant) in
/// `UserDefaults`, and `resumePending` re-registers exactly those —
/// never a hydrated row of another device that happens to lack a
/// coordinate. A registration is dropped once its sample got a
/// coordinate, was deleted or ran out of time; `reset()` drops all of
/// them on a user switch.
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
    /// UserDefaults key of the persisted registrations.
    static let registrationsKey = "location.pendingFixRegistrations"

    /// One sample waiting for a fix, as persisted.
    struct Registration: Codable, Equatable {
        let sampleID: String
        /// `LocalSampleStore.userId` at registration time.
        let userID: String
        let createdAt: Date
    }

    private let store: LocalSampleStore
    private let mutations: PendingMutationsStore
    private let source: PendingFixSource
    private let defaults: UserDefaults
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
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init,
        timerInterval: TimeInterval? = 30,
        onCoordinateSet: @escaping (String) -> Void = { _ in }
    ) {
        self.store = store
        self.mutations = mutations
        self.source = source
        self.defaults = defaults
        self.now = now
        self.timerInterval = timerInterval
        self.onCoordinateSet = onCoordinateSet
        source.onFix = { [weak self] fix in self?.handle(fix) }
    }

    deinit { timer?.cancel() }

    /// Number of samples still waiting for a fix (tests, diagnostics).
    var pendingCount: Int {
        pending.count
    }

    /// Starts waiting for a fix for a sample created at `createdAt`
    /// without coordinate.
    func register(sampleID: String, createdAt: Date) {
        guard now().timeIntervalSince(createdAt) < Self.timeLimit else {
            Log.location.info("pending fix not started, sample \(sampleID, privacy: .public) too old")
            return
        }
        pending[sampleID] = createdAt
        var stored = loadRegistrations().filter { $0.sampleID != sampleID }
        stored.append(Registration(sampleID: sampleID, userID: store.userId, createdAt: createdAt))
        saveRegistrations(stored)
        updateLocating()
    }

    /// Stops waiting for a sample (e.g. it was deleted).
    func cancel(sampleID: String) {
        drop(sampleID)
        updateLocating()
    }

    /// App became active: re-register the samples registered on this
    /// device that are still without coordinate and younger than the
    /// time limit (the process may have been killed while waiting).
    /// A registration counts only while its sample row belongs to the
    /// user that registered it.
    func resumePending() {
        let current = now()
        var kept: [Registration] = []
        for registration in loadRegistrations() {
            guard current.timeIntervalSince(registration.createdAt) < Self.timeLimit else {
                pending[registration.sampleID] = nil
                continue
            }
            let sample: LocalSample?
            do {
                sample = try store.fetchById(registration.sampleID)
            } catch {
                // Keep it: a read error says nothing about the sample.
                Log.persistence.error("pending fix resume failed: \(error.localizedDescription)")
                kept.append(registration)
                continue
            }
            guard let sample, !sample.hasCoordinate, sample.userId == registration.userID else {
                pending[registration.sampleID] = nil
                continue
            }
            kept.append(registration)
            if pending[sample.id] == nil {
                pending[sample.id] = registration.createdAt
            }
        }
        saveRegistrations(kept)
        expireOverdue()
        updateLocating()
    }

    /// Forgets every registration (user switch / sign-out: the local
    /// rows are wiped, nothing may be resumed for the next user).
    func reset() {
        pending.removeAll()
        defaults.removeObject(forKey: Self.registrationsKey)
        updateLocating()
    }

    /// Drops samples that waited longer than `timeLimit`.
    func expireOverdue() {
        let current = now()
        for (id, createdAt) in pending where current.timeIntervalSince(createdAt) >= Self.timeLimit {
            drop(id)
            Log.location.warning("gave up waiting for a fix, sample \(id, privacy: .public)")
        }
        updateLocating()
    }

    // MARK: - private

    private func handle(_ fix: LocationProvider.Fix) {
        expireOverdue()
        // Same predicate as the editor's GPS (freshness is checked by
        // the source, which still has the timestamp).
        guard LocationThreshold.accepts(fix) else { return }
        for id in Array(pending.keys) {
            apply(fix, to: id)
        }
        updateLocating()
    }

    /// Removes a sample from memory and from the persisted list.
    private func drop(_ id: String) {
        pending[id] = nil
        let stored = loadRegistrations()
        let remaining = stored.filter { $0.sampleID != id }
        if remaining.count != stored.count { saveRegistrations(remaining) }
    }

    private func loadRegistrations() -> [Registration] {
        guard let data = defaults.data(forKey: Self.registrationsKey) else { return [] }
        do {
            return try JSONDecoder().decode([Registration].self, from: data)
        } catch {
            Log.persistence.error("pending fix registrations unreadable: \(error.localizedDescription)")
            return []
        }
    }

    private func saveRegistrations(_ registrations: [Registration]) {
        guard !registrations.isEmpty else {
            defaults.removeObject(forKey: Self.registrationsKey)
            return
        }
        do {
            try defaults.set(JSONEncoder().encode(registrations), forKey: Self.registrationsKey)
        } catch {
            Log.persistence.error("pending fix registrations not saved: \(error.localizedDescription)")
        }
    }

    private func apply(_ fix: LocationProvider.Fix, to id: String) {
        do {
            guard let sample = try store.fetchById(id) else {
                drop(id)
                return
            }
            if sample.hasCoordinate {
                drop(id)
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
            drop(id)
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

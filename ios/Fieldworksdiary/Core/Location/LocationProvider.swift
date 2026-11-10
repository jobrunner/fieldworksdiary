import CoreLocation
import Foundation

/// Matches the old app's filter values: same thresholds for
/// horizontal/vertical accuracy and fix freshness.
///
/// `accepts(_:)` is the one predicate every consumer uses (editor GPS,
/// the instant creation's `recentFix`, `PendingFixService`), so a fix
/// is usable everywhere or nowhere.
enum LocationThreshold {
    static let horizontalAccuracy: CLLocationAccuracy = 100
    static let verticalAccuracy: CLLocationAccuracy = 100
    static let staleness: TimeInterval = 15

    /// Precision check on a fix: a valid horizontal accuracy within
    /// `horizontalAccuracy`, and a vertical accuracy within
    /// `verticalAccuracy` when the fix has a valid altitude (CoreLocation
    /// marks a missing altitude with a negative value, which `Fix` turns
    /// into nil — that never rejected a fix before either).
    static func accepts(_ fix: LocationProvider.Fix) -> Bool {
        guard let horizontal = fix.horizontalAccuracy, horizontal <= horizontalAccuracy else { return false }
        if let vertical = fix.verticalAccuracy, vertical > verticalAccuracy { return false }
        return true
    }

    /// Freshness (`staleness`) plus `accepts(_ fix:)` for a raw
    /// CoreLocation fix.
    static func accepts(_ location: CLLocation, now: Date = Date()) -> Bool {
        abs(location.timestamp.timeIntervalSince(now)) <= staleness
            && accepts(LocationProvider.Fix(location))
    }
}

@MainActor
final class LocationProvider: NSObject, ObservableObject {
    enum Status: Equatable {
        case idle
        case requestingAuthorization
        case denied
        case locating
        case fixed(CLLocation)
        case failed(String)
    }

    /// Values of a GPS fix as the sample stores them. CoreLocation
    /// marks invalid values with a negative accuracy; those become nil.
    /// An altitude of 0 m is a real value and is kept.
    struct Fix: Equatable {
        let latitude: Double
        let longitude: Double
        let horizontalAccuracy: Double?
        /// Vertical accuracy of `elevation`; nil when the fix has no
        /// valid altitude.
        let verticalAccuracy: Double?
        /// Altitude above sea level; nil when `verticalAccuracy` is
        /// invalid.
        let elevation: Double?

        init(latitude: Double, longitude: Double,
             horizontalAccuracy: Double, verticalAccuracy: Double, altitude: Double)
        {
            self.latitude = latitude
            self.longitude = longitude
            self.horizontalAccuracy = horizontalAccuracy >= 0 ? horizontalAccuracy : nil
            let altitudeValid = verticalAccuracy >= 0
            self.verticalAccuracy = altitudeValid ? verticalAccuracy : nil
            elevation = altitudeValid ? altitude : nil
        }

        init(_ location: CLLocation) {
            self.init(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                horizontalAccuracy: location.horizontalAccuracy,
                verticalAccuracy: location.verticalAccuracy,
                altitude: location.altitude
            )
        }
    }

    @Published private(set) var status: Status = .idle

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    /// The fix CoreLocation already holds, if it is fresh and precise
    /// enough by the editor's thresholds; nil otherwise. Starts no
    /// location updates — the instant creation (Phase E) takes a fix
    /// only when one is already there and leaves the rest to
    /// `PendingFixService`.
    static func recentFix(from manager: CLLocationManager = CLLocationManager()) -> Fix? {
        guard let loc = manager.location, LocationThreshold.accepts(loc) else { return nil }
        return Fix(loc)
    }

    func requestFix() {
        switch manager.authorizationStatus {
        case .notDetermined:
            status = .requestingAuthorization
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            status = .denied
        case .authorizedAlways, .authorizedWhenInUse:
            status = .locating
            manager.startUpdatingLocation()
        @unknown default:
            status = .failed("Unbekannter Autorisierungs-Status.")
        }
    }
}

extension LocationProvider: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            switch manager.authorizationStatus {
            case .authorizedAlways, .authorizedWhenInUse:
                if status == .requestingAuthorization {
                    status = .locating
                    manager.startUpdatingLocation()
                }
            case .denied, .restricted:
                status = .denied
            default:
                break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }

        // Reject stale cached locations and imprecise fixes (same
        // thresholds as the old app); keep updating until one is good.
        guard LocationThreshold.accepts(loc) else { return }

        // Good fix: stop the continuous updates.
        manager.stopUpdatingLocation()
        Task { @MainActor in
            status = .fixed(loc)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // kCLErrorLocationUnknown is transient (GPS still acquiring) — keep going.
        if let clErr = error as? CLError, clErr.code == .locationUnknown { return }
        manager.stopUpdatingLocation()
        Task { @MainActor in
            Log.location.error("location fix failed: \(error.localizedDescription)")
            status = .failed(error.localizedDescription)
        }
    }
}

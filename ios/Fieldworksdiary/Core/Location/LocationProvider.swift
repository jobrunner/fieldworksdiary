import Foundation
import CoreLocation
import Combine

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

    @Published private(set) var status: Status = .idle

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
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
            manager.requestLocation()
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
                    manager.requestLocation()
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
        Task { @MainActor in
            status = .fixed(loc)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            status = .failed(error.localizedDescription)
        }
    }
}

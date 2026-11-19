import Foundation
import Network

/// Whether the device is on an unmetered connection, for „Fotos nur im
/// WLAN hochladen“.
protocol NetworkStatusProviding: AnyObject {
    var isOnWiFi: Bool { get }
}

/// `NWPathMonitor`-backed status. Wi-Fi and wired Ethernet count; a
/// personal hotspot is Wi-Fi to the device and counts as well.
final class NetworkStatus: NetworkStatusProviding, @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var onWiFi = false

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let value = path.status == .satisfied
                && (path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet))
            self?.set(value)
        }
        monitor.start(queue: DispatchQueue(label: "app.legulus.network-status"))
    }

    deinit { monitor.cancel() }

    var isOnWiFi: Bool {
        lock.lock()
        defer { lock.unlock() }
        return onWiFi
    }

    private func set(_ value: Bool) {
        lock.lock()
        onWiFi = value
        lock.unlock()
    }
}

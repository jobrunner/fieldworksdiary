import Foundation

/// When a photo is uploaded (again). Pure decisions, no I/O: the
/// `SyncRunner` asks, tests pin the answers.
///
/// Photos are large since they are no longer downscaled, so failed
/// uploads back off instead of retrying on every 30-s tick, and the
/// user can hold them back for Wi-Fi.
enum PhotoUploadPolicy {
    /// Seconds to wait after the n-th failed attempt.
    private static let delays: [TimeInterval] = [0, 60, 300, 900, 3600]

    static func retryDelay(attempts: Int) -> TimeInterval {
        guard attempts > 0 else { return 0 }
        return delays[min(attempts, delays.count - 1)]
    }

    /// A photo is due when it was never tried or its delay has passed.
    static func isDue(_ photo: LocalPhoto, now: Date) -> Bool {
        guard let last = photo.lastAttemptAt else { return true }
        return now.timeIntervalSince(last) >= retryDelay(attempts: photo.attempts)
    }

    /// An error that asking again will not cure (file too large,
    /// rejected record): the photo is not retried in this app run.
    /// 401 (token refresh), 408 and 429 are transient like 5xx and
    /// network errors.
    static func isPermanent(_ error: Error) -> Bool {
        guard case let SampleClientError.http(status, _) = error else { return false }
        return (400 ..< 500).contains(status) && ![401, 408, 429].contains(status)
    }

    static func mayUpload(wifiOnly: Bool, onWiFi: Bool) -> Bool {
        !wifiOnly || onWiFi
    }
}

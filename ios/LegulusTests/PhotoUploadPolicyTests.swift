@testable import Legulus
import XCTest

final class PhotoUploadPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func photo(attempts: Int, lastAttempt: TimeInterval?) -> LocalPhoto {
        var photo = LocalPhoto(
            id: "p", sampleId: "s", localPath: "photos/s/p.jpg", backendId: nil, syncStatus: .failed,
            syncError: nil, clientUuid: "p", clientUpdatedAt: now, createdAt: now
        )
        photo.attempts = attempts
        photo.lastAttemptAt = lastAttempt.map { now.addingTimeInterval(-$0) }
        return photo
    }

    func testRetryDelayGrows() {
        XCTAssertEqual(PhotoUploadPolicy.retryDelay(attempts: 0), 0)
        XCTAssertEqual(PhotoUploadPolicy.retryDelay(attempts: 1), 60)
        XCTAssertEqual(PhotoUploadPolicy.retryDelay(attempts: 2), 300)
        XCTAssertEqual(PhotoUploadPolicy.retryDelay(attempts: 3), 900)
        XCTAssertEqual(PhotoUploadPolicy.retryDelay(attempts: 4), 3600)
        XCTAssertEqual(PhotoUploadPolicy.retryDelay(attempts: 40), 3600)
        XCTAssertEqual(PhotoUploadPolicy.retryDelay(attempts: -1), 0)
    }

    func testIsDue() {
        XCTAssertTrue(PhotoUploadPolicy.isDue(photo(attempts: 0, lastAttempt: nil), now: now), "nie versucht")
        XCTAssertFalse(PhotoUploadPolicy.isDue(photo(attempts: 1, lastAttempt: 30), now: now))
        XCTAssertTrue(PhotoUploadPolicy.isDue(photo(attempts: 1, lastAttempt: 60), now: now))
        XCTAssertFalse(PhotoUploadPolicy.isDue(photo(attempts: 3, lastAttempt: 600), now: now))
        XCTAssertTrue(PhotoUploadPolicy.isDue(photo(attempts: 3, lastAttempt: 901), now: now))
        XCTAssertTrue(PhotoUploadPolicy.isDue(photo(attempts: 2, lastAttempt: nil), now: now), "ohne Zeitpunkt nicht blockieren")
    }

    func testIsPermanent() {
        func http(_ status: Int) -> Error {
            SampleClientError.http(status: status, body: "")
        }
        for status in [400, 403, 404, 413, 422] {
            XCTAssertTrue(PhotoUploadPolicy.isPermanent(http(status)), "\(status)")
        }
        for status in [401, 408, 429, 500, 502, 503] {
            XCTAssertFalse(PhotoUploadPolicy.isPermanent(http(status)), "\(status)")
        }
        XCTAssertFalse(PhotoUploadPolicy.isPermanent(URLError(.timedOut)))
        XCTAssertFalse(PhotoUploadPolicy.isPermanent(URLError(.notConnectedToInternet)))
    }

    func testMayUpload() {
        XCTAssertTrue(PhotoUploadPolicy.mayUpload(wifiOnly: false, onWiFi: false))
        XCTAssertTrue(PhotoUploadPolicy.mayUpload(wifiOnly: false, onWiFi: true))
        XCTAssertTrue(PhotoUploadPolicy.mayUpload(wifiOnly: true, onWiFi: true))
        XCTAssertFalse(PhotoUploadPolicy.mayUpload(wifiOnly: true, onWiFi: false))
    }
}

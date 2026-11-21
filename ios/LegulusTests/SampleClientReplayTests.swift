@testable import Legulus
import XCTest

final class SampleClientReplayTests: XCTestCase {
    private func response(_ headers: [String: String]) throws -> HTTPURLResponse {
        let url = try XCTUnwrap(URL(string: "https://backend.example/api/collections/samples/records"))
        return try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: headers))
    }

    func testReplayHeader_MarksTheAnswer() throws {
        XCTAssertTrue(try SampleClient.isReplay(response(["Idempotent-Replayed": "true"])))
        // Header names are case-insensitive, proxies may rewrite them.
        XCTAssertTrue(try SampleClient.isReplay(response(["idempotent-replayed": "TRUE"])))
    }

    func testNoOrOtherHeaderValue_IsNoReplay() throws {
        XCTAssertFalse(try SampleClient.isReplay(response([:])))
        XCTAssertFalse(try SampleClient.isReplay(response(["Idempotent-Replayed": "false"])))
    }
}

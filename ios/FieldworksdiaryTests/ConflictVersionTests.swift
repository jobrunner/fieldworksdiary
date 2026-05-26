@testable import Fieldworksdiary
import XCTest

final class ParseConflictVersionTests: XCTestCase {
    func testTopLevelFieldShape() {
        let body = #"{"message":"stale write","current_version":42,"incoming_version":3}"#
        XCTAssertEqual(parseConflictVersion(from: body), 42)
    }

    func testNestedDataShape() {
        // PocketBase's `ApiError` JSON wraps the hook's data map
        // under `"data"`. We honor both top-level and nested.
        let body = #"""
        {
          "code":409,
          "message":"stale write: pull and retry",
          "data":{"current_version":7,"incoming_version":7}
        }
        """#
        XCTAssertEqual(parseConflictVersion(from: body), 7)
    }

    func testMalformedBodyFallsBackToZero() {
        XCTAssertEqual(parseConflictVersion(from: "not json"), 0)
        XCTAssertEqual(parseConflictVersion(from: ""), 0)
        XCTAssertEqual(parseConflictVersion(from: #"{"other":"shape"}"#), 0)
    }
}

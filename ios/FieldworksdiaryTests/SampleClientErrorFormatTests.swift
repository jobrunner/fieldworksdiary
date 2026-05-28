@testable import Fieldworksdiary
import XCTest

/// Pins the readable rendering of PocketBase error bodies. The Apple-
/// login 400 used to show up as a raw JSON blob in the WelcomeView
/// footnote — unreadable on device. The formatter turns it into a
/// short sentence callers can actually read.
final class SampleClientErrorFormatTests: XCTestCase {
    func testAppleLoginValidationError() {
        // Real body the live backend returned for the Apple-login probe.
        let body = #"""
        {"code":400,"message":"Something went wrong while processing your request.","data":{"redirectUrl":{"code":"validation_required","message":"Cannot be blank."}}}
        """#
        let out = SampleClientError.formatPocketBaseError(status: 400, body: body)
        XCTAssertEqual(
            out,
            "HTTP 400 — Something went wrong while processing your request. (redirectUrl: Cannot be blank.)"
        )
    }

    func testMultipleFieldErrorsAreSorted() {
        let body = #"""
        {"code":400,"message":"x","data":{"b":{"message":"second"},"a":{"message":"first"}}}
        """#
        let out = SampleClientError.formatPocketBaseError(status: 400, body: body)
        XCTAssertEqual(out, "HTTP 400 — x (a: first · b: second)")
    }

    func testNonJSONBodyFallsBackToRaw() {
        let out = SampleClientError.formatPocketBaseError(status: 502, body: "Bad Gateway")
        XCTAssertEqual(out, "HTTP 502: Bad Gateway")
    }

    func testTopLevelMessageOnly() {
        let body = #"{"code":401,"message":"The request requires valid record authorization token to be set.","data":{}}"#
        let out = SampleClientError.formatPocketBaseError(status: 401, body: body)
        XCTAssertEqual(
            out,
            "HTTP 401 — The request requires valid record authorization token to be set."
        )
    }
}
